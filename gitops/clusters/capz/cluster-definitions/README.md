# CAPZ workload cluster definitions

Each YAML file in this folder defines one AKS workload cluster for the
`aks-workload-clusters` ApplicationSet.

The ApplicationSet renders the repo's `azure-managed-cluster` Helm chart and
creates CAPZ resources in the management cluster. Fleet membership is enabled by
the chart's `controlplane.fleetsMember` block.

## Example

```yaml
workloadClusterName: aks-customer-demo
resourceGroupName: aks-customer-demo
location: westus3
kubernetesVersion: v1.30.6
agentSku: Standard_D2s_v3
agentCount: 1
systemPoolName: sys
fleetMemberName: aks-customer-demo-fleet-member
fleetGroup: customer-demo
sshPublicKey: ''
```

## Demo command

Apply the cluster provisioning entry point to the control-plane AKS cluster:

```powershell
kubectl --context gitops-aks apply -f gitops/clusters/clusters-argo-applicationset.yaml
```

Then watch:

```powershell
kubectl --context gitops-aks -n argocd get applications
kubectl --context gitops-aks -n workload get clusters
az fleet member list -g aks-gitops --fleet-name gitops-fleet -o table
```
