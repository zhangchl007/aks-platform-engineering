#!/usr/bin/env bash
#
# arc-onboard.sh — Onboard an external (non-AKS) Kubernetes cluster to Azure Arc
# and register it into the control-plane ArgoCD as a GitOps-managed cluster.
#
# Idempotent. Steps:
#   1. Preflight (az, kubectl, connectedk8s extension, login, providers).
#   2. az connectedk8s connect (onboard the target cluster to Azure Arc).
#   3. Enable the cluster-connect feature.
#   4. Create a cluster-admin ServiceAccount in the target cluster and mint a token.
#   5. Build an ArgoCD cluster Secret and apply it to the control-plane argocd ns.
#   6. Verify ArgoCD sees the cluster.
#
# Boundary: Azure Arc is for NON-AKS / external clusters only. Do not run this
# against the AKS hub (it is governed by Fleet Manager).
#
# Usage:
#   ./arc-onboard.sh --cluster-name arc-demo --kube-context kind-arc-demo \
#       --control-plane-context aks-gitops [--location eastus2] \
#       [--terraform-dir ../terraform]
set -euo pipefail

CLUSTER_NAME=""
KUBE_CONTEXT=""
CONTROL_PLANE_CONTEXT=""
LOCATION=""
TERRAFORM_DIR=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name)           CLUSTER_NAME="$2"; shift 2 ;;
    --kube-context)           KUBE_CONTEXT="$2"; shift 2 ;;
    --control-plane-context)  CONTROL_PLANE_CONTEXT="$2"; shift 2 ;;
    --location)               LOCATION="$2"; shift 2 ;;
    --terraform-dir)          TERRAFORM_DIR="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$CLUSTER_NAME" ]] || { echo "--cluster-name is required" >&2; exit 1; }
[[ -n "$KUBE_CONTEXT" ]] || { echo "--kube-context is required" >&2; exit 1; }
[[ -n "$TERRAFORM_DIR" ]] || TERRAFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/terraform"

step() { printf '\033[36m==> %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m    %s\033[0m\n' "$1"; }
warn() { printf '\033[33m    %s\033[0m\n' "$1"; }

# --- Preflight ----------------------------------------------------------------
step "Preflight checks"
for tool in az kubectl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Required tool '$tool' not found on PATH." >&2; exit 1; }
done
az account show >/dev/null 2>&1 || { echo "Not logged in. Run 'az login' first." >&2; exit 1; }
ok "Azure login OK"

if ! az extension show --name connectedk8s >/dev/null 2>&1; then
  step "Installing az connectedk8s extension"
  az extension add --name connectedk8s --only-show-errors >/dev/null
fi

# --- Load Terraform onboarding context ----------------------------------------
step "Reading onboarding context from $TERRAFORM_DIR"
CTX="$(cd "$TERRAFORM_DIR" && terraform output -json arc_onboarding)"
[[ -n "$CTX" ]] || { echo "Could not read 'arc_onboarding' output. Did you 'terraform apply'?" >&2; exit 1; }

RG="$(jq -r '.resource_group' <<<"$CTX")"
ARGONS="$(jq -r '.argocd_namespace' <<<"$CTX")"
if [[ -n "$LOCATION" ]]; then
  LOC="$LOCATION"
else
  LOC="$(jq -r --arg n "$CLUSTER_NAME" '.external_clusters[$n] // empty' <<<"$CTX")"
  [[ -n "$LOC" ]] || LOC="$(jq -r '.location' <<<"$CTX")"
fi
ok "Resource group: $RG | Location: $LOC | ArgoCD ns: $ARGONS"

# --- Register providers (best-effort) -----------------------------------------
step "Ensuring Arc resource providers are registered"
for p in Microsoft.Kubernetes Microsoft.KubernetesConfiguration Microsoft.ExtendedLocation; do
  state="$(az provider show --namespace "$p" --query registrationState -o tsv 2>/dev/null || echo NotRegistered)"
  if [[ "$state" != "Registered" ]]; then
    warn "$p is '$state' — registering (this can take minutes)"
    az provider register --namespace "$p" --only-show-errors >/dev/null
  else
    ok "$p registered"
  fi
done

# --- Arc connect --------------------------------------------------------------
step "Connecting '$CLUSTER_NAME' to Azure Arc"
if az connectedk8s show --name "$CLUSTER_NAME" --resource-group "$RG" >/dev/null 2>&1; then
  ok "connectedCluster '$CLUSTER_NAME' already exists — skipping connect"
else
  az connectedk8s connect \
    --name "$CLUSTER_NAME" \
    --resource-group "$RG" \
    --location "$LOC" \
    --kube-context "$KUBE_CONTEXT" \
    --only-show-errors
  ok "Arc connect complete"
fi

step "Enabling cluster-connect feature"
az connectedk8s enable-features \
  --name "$CLUSTER_NAME" \
  --resource-group "$RG" \
  --kube-context "$KUBE_CONTEXT" \
  --features cluster-connect \
  --only-show-errors >/dev/null
ok "cluster-connect enabled"

# --- Create cluster-admin ServiceAccount + token in the target cluster --------
step "Creating ArgoCD service account in target cluster"
SA_NS="argocd-managed"
SA_NAME="argocd-manager"
kubectl --context "$KUBE_CONTEXT" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $SA_NS
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SA_NAME
  namespace: $SA_NS
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: $SA_NAME
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: $SA_NAME
    namespace: $SA_NS
EOF

TOKEN="$(kubectl --context "$KUBE_CONTEXT" -n "$SA_NS" create token "$SA_NAME" --duration=8760h 2>/dev/null || true)"
if [[ -z "$TOKEN" ]]; then
  warn "TokenRequest API unavailable — falling back to a token Secret"
  kubectl --context "$KUBE_CONTEXT" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SA_NAME}-token
  namespace: $SA_NS
  annotations:
    kubernetes.io/service-account.name: $SA_NAME
type: kubernetes.io/service-account-token
EOF
  sleep 3
  TOKEN="$(kubectl --context "$KUBE_CONTEXT" -n "$SA_NS" get secret "${SA_NAME}-token" -o jsonpath='{.data.token}' | base64 -d)"
fi
ok "Service account token minted"

SERVER="$(kubectl --context "$KUBE_CONTEXT" config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}')"
CA_B64="$(kubectl --context "$KUBE_CONTEXT" config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
ok "Target API server: $SERVER"

# --- Render the ArgoCD cluster Secret -----------------------------------------
step "Rendering ArgoCD cluster Secret"
OUT_DIR="$SCRIPT_DIR/.arc-out"
mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/cluster-secret-$CLUSTER_NAME.yaml"

CONFIG_JSON="$(jq -nc --arg t "$TOKEN" --arg ca "$CA_B64" \
  '{bearerToken:$t, tlsClientConfig:{insecure:false, caData:$ca}}')"

jq -n \
  --arg name "$CLUSTER_NAME" \
  --arg ns "$ARGONS" \
  --arg server "$SERVER" \
  --arg config "$CONFIG_JSON" \
  --arg rg "$RG" \
  --argjson ctx "$CTX" \
  '{
    apiVersion: "v1",
    kind: "Secret",
    metadata: {
      name: $name,
      namespace: $ns,
      labels: {
        "argocd.argoproj.io/secret-type": "cluster",
        "environment": "arc",
        "enable_arc_onboarding": "true",
        "provider": "arc"
      },
      annotations: {
        addons_repo_url: $ctx.addons_repo_url,
        addons_repo_basepath: $ctx.addons_repo_basepath,
        addons_repo_path: $ctx.addons_repo_path,
        addons_repo_revision: $ctx.addons_repo_revision,
        subscription_id: $ctx.subscription_id,
        tenant_id: $ctx.tenant_id,
        akspe_identity_id: $ctx.akspe_client_id,
        arc_resource_group: $rg
      }
    },
    type: "Opaque",
    stringData: { name: $name, server: $server, config: $config }
  }' > "$OUT_FILE"
ok "Wrote $OUT_FILE (contains a token — do NOT commit)"

# --- Apply to the control plane -----------------------------------------------
if [[ -n "$CONTROL_PLANE_CONTEXT" ]]; then
  step "Registering cluster into ArgoCD (context: $CONTROL_PLANE_CONTEXT)"
  kubectl --context "$CONTROL_PLANE_CONTEXT" apply -f "$OUT_FILE" >/dev/null
  ok "ArgoCD cluster Secret applied to '$ARGONS'"
  kubectl --context "$CONTROL_PLANE_CONTEXT" -n "$ARGONS" get secret "$CLUSTER_NAME" \
    -o "jsonpath={.metadata.labels}{'\n'}"
  ok "Done. The addons-arc-onboarding ApplicationSet will deploy the baseline."
else
  warn "No --control-plane-context given. Apply the rendered Secret yourself:"
  warn "  kubectl --context <control-plane> apply -f $OUT_FILE"
fi
