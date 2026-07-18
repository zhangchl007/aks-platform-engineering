# CAPZ workload cluster definitions

Each YAML file in this folder defines one AKS workload cluster for the
`aks-workload-clusters` ApplicationSet.

The ApplicationSet renders the repo's `azure-managed-cluster` Helm chart and
creates CAPZ resources in the management cluster. For the customer demo, join the
created AKS cluster to Fleet Manager after AKS is ready with
`az fleet member create`; the installed CAPZ release uses an older Fleet member
API, so the demo does not rely on `controlplane.fleetsMember`.

## Example

```yaml
workloadClusterName: aks-customer-demo
resourceGroupName: aks-customer-demo
location: eastus2
kubernetesVersion: v1.33.12
agentSku: Standard_D4as_v6
agentCount: 1
systemPoolName: sys
fleetMemberName: aks-customer-demo-fleet-member
fleetGroup: customer-demo
sshPublicKey: ''
```

The ApplicationSet sets the system pool OS disk type to `Managed`. The demo uses
`Standard_D4as_v6`, which is available in `eastus2` for the current
subscription.

## Demo command

Apply the cluster provisioning entry point to the control-plane AKS cluster:

```powershell
kubectl --context gitops-aks apply -f gitops/clusters/clusters-argo-applicationset.yaml
```

Then watch:

```powershell
kubectl --context gitops-aks -n argocd get applications
kubectl --context gitops-aks -n workload get clusters
az fleet member list -g aks-gitops-westus2 --fleet-name gitops-fleet -o table
```
