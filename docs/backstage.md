# Backstage

## Overview

Backstage is an open platform for building developer portals. It was created by Spotify to streamline their development processes and has since been open-sourced. Backstage allows you to manage all your infrastructure, services, and tools in one place, providing a unified developer experience.

## Features

- **Service Catalog**: Organize and manage all your services.
- **Software Templates**: Standardize and automate the creation of new projects.
- **TechDocs**: Centralize your documentation.
- **Plugins**: Extend Backstage with a wide range of plugins.

## Context in This Project

In this project, Backstage is used to provide a unified developer portal that integrates various tools and services. It helps in managing the infrastructure and services more efficiently. The project leverages Backstage to:

- **Centralize Documentation**: Using TechDocs to keep all documentation in one place.
- **Manage Services**: Using the Service Catalog to organize and manage microservices.
- **Automate Workflows**: Using Software Templates to standardize project creation.

For a customer-ready walkthrough that demonstrates Backstage as the self-service
front door for application deployment with ArgoCD, see
[Demo: Backstage application deployment with ArgoCD](./backstage-feature-demo.md).

## Multi-cluster Kubernetes visibility

Backstage must not use an ArgoCD manager token or a human cluster-admin token.
The `platform-target-baseline` ApplicationSet creates a dedicated
`backstage-kubernetes-reader` service account on each registered target. Its
permissions are read-only and cover only the workload inventory rendered by the
Backstage Kubernetes plugin.

The private connection configuration is generated locally and stored only as a
Secret in the `backstage` namespace:

```powershell
.\scripts\configure-backstage-kubernetes-connections.ps1 `
  -AksDeployerGroupObjectId "<private-aks-deployer-group-object-id>"
```

After creating the Secret, set the following **ignored** Terraform input only
when bootstrapping the legacy release:

```hcl
backstage_kubernetes_clusters_secret_name = "backstage-kubernetes-clusters"
```

The ArgoCD-managed `backstage` Application consumes the mounted file and
replaces the legacy single `K8S_CLUSTER_*` configuration. It loads
`gitops-aks`, `arc-demo-vm`, and `arc-demo-vm-2` through the official
multi-tenant Kubernetes service locator. Do not use Terraform to reconcile the
adopted Backstage Helm release. Tokens, CA data, and Entra object IDs must
never be committed.

Human Kubernetes access remains separate from Backstage's technical reader:

| Entra group | Kubernetes access |
| --- | --- |
| `k8sadmin` | Cluster-admin on every registered target through the target baseline |
| `akspe-aks-cluster-deployers` | Read-only `view` on every registered AKS target; deployment remains limited to approved GitOps namespaces |
| `akspe-kind-cluster-deployers` | Kind deployment remains limited to `group1-apps` through the approved GitOps path |

Backstage's common `akspe-backstage-users` group remains only the sign-in gate.
Do not treat a shared server-side reader as a user deployment credential.
The privileged Backstage persona is resolved separately from the Entra group
object ID written to `BACKSTAGE_ADMIN_GROUP_IDS`; by default that object ID maps
to `group:default/k8sadmin`.

Cluster Resource descriptors include non-secret target metadata:

| Annotation | Purpose |
| --- | --- |
| `platform-access.akspe.io/cluster-type` | Classifies the target as `aks` or `kind`. |
| `platform-access.akspe.io/visibility-groups` | Documents the Entra-backed Backstage groups that should see the target. |
| `platform-access.akspe.io/protected` | Marks the entity as subject to the platform access permission policy. |
| `platform-access.akspe.io/allow-aks-deployers` | Allows AKS deployers to see the entity. |
| `platform-access.akspe.io/allow-kind-deployers` | Allows Arc/kind deployers to see the entity. |
| `platform-access.akspe.io/deploy-namespace` | Records the approved demo deployment namespace for templates and runbooks. |

Backstage uses separate Software Templates for the two ordinary-user deployment
paths. The platform access permission policy reads Entra-derived Backstage group
entitlements and protects both Catalog visibility and template parameters/steps:

| Template | Visible to | ArgoCD project | Destination choices |
| --- | --- | --- | --- |
| `deploy-aks-application` | `k8sadmin`, `akspe-aks-cluster-deployers` | `aks-team-delivery` | `gitops-aks/group2-aks-apps` |
| `deploy-kind-application` | `k8sadmin`, `akspe-kind-cluster-deployers` | `kind-team-delivery` | `arc-demo-vm/group1-apps`, `arc-demo-vm-2/group1-apps` |

The hard deployment authorization boundary remains ArgoCD AppProjects and
reviewed Git changes. Backstage must not receive write-capable Kubernetes
credentials for ordinary deployers.

## Catalog and identity authority

Backstage uses two authoritative sources:

| Data | Authority | Storage |
| --- | --- | --- |
| Users and access groups | Microsoft Entra ID, synchronized by the Microsoft Graph Organization Provider | Microsoft Graph |
| Platform Resources and Templates | Git-managed Catalog root | `backstage/catalog/catalog-info.yaml` |
| Cluster connection tokens and CA data | ArgoCD connection registry | Kubernetes Secret only |

`k8sadmin` is the owner of the platform cluster Resource entities and platform
deployment Templates. The Entra groups `k8sadmin`, `akspe-backstage-users`,
`akspe-kind-cluster-deployers`, and `akspe-aks-cluster-deployers` must be
available to the Backstage Entra application. The platform configuration script
directly assigns all of those groups to the shared Enterprise Application,
creates the private mapping, Graph filters, and explicit admin group ID list; it
never writes those object IDs to Git. Direct Enterprise Application assignment
matters for ArgoCD because ArgoCD only evaluates the `groups` claim in the login
token and does not call Microsoft Graph to expand transitive group membership.

If a user can sign in but sees no protected cluster Resources or delivery
Templates, first confirm the user is a member of `k8sadmin` rather than only the
common `akspe-backstage-users` sign-in group. Recent Backstage access logs show
the effective `relations.ownedBy` filters, for example
`group:default/akspe-backstage-users` and deployer groups. The admin view
requires `group:default/k8sadmin` to appear in the user's Backstage
entitlements.

The Backstage Entra application requires administrator-consented Microsoft
Graph **application** permissions:

- `User.Read.All`
- `GroupMember.Read.All`

The sign-in resolver uses the approved mapping and Microsoft Graph transitive
membership lookup, so nested Entra groups and group-claim overage do not cause
users to be downgraded to a fixed `guests` group.

Validate Catalog descriptors before publishing an image:

```powershell
Set-Location backstage
yarn catalog:validate
```

The validation gate rejects invalid descriptors, duplicate entity references,
and unresolved owners. Do not add production owners to image-local example
files.

### Verified Graph synchronization and owner resolution

The Microsoft Graph Organization Provider is the only source for production
Backstage `User` and `Group` entities. A successful refresh imports the
approved Entra groups, including `group:default/k8sadmin`. Git-managed Catalog
Resources then resolve their ownership through the normal `ownedBy` relation:

| Resource | Resolved owner |
| --- | --- |
| `resource:default/gitops-aks` | `group:default/k8sadmin` |
| `resource:default/arc-demo-vm` | `group:default/k8sadmin` |
| `resource:default/arc-demo-vm-2` | `group:default/k8sadmin` |

The provider runs on an hourly persisted scheduler. Its `initialDelay` applies
only when Backstage first creates the task record; restarting a Pod does not
reset an already persisted next-run time. This is expected scheduler behavior,
not a reason to add static shadow Groups to Git.

Safe live checks that do not print secret values:

```powershell
kubectl --context gitops-aks-admin -n backstage get secret platform-backstage-sso `
  -o jsonpath="{.data}" | Out-Null
kubectl --context gitops-aks-admin -n backstage get deploy backstage-backstagechart `
  -o jsonpath="{range .spec.template.spec.containers[0].env[*]}{.name}{' '}{end}{'\n'}"
kubectl --context gitops-aks-admin -n backstage logs deploy/backstage-backstagechart --since=30m |
  Select-String -Pattern "relations.ownedBy|k8sadmin|Microsoft sign-in|Graph group"
```

Expected Backstage identity environment variables include
`BACKSTAGE_ALLOWED_GROUP_IDS`, `BACKSTAGE_ENTRA_GROUP_MAPPINGS`,
`BACKSTAGE_ADMIN_GROUP_IDS`, and `BACKSTAGE_ADMIN_GROUP_ENTITY_NAMES`.

Use the following signals to verify a refresh:

```powershell
kubectl --context gitops-aks-admin -n backstage logs deploy/backstage-backstagechart `
  | Select-String 'Reading msgraph users and groups|Committed .*msgraph groups'
```

Expected logs include `Committed ... msgraph groups`. If an Entra group or
membership changed, allow the scheduled refresh to complete, then have the user
sign out and sign back in so the browser obtains a fresh Backstage identity
token. Do not expose Catalog APIs without authentication; an unauthenticated
Catalog API request correctly returns HTTP 401.

## ArgoCD workload ownership

ArgoCD is the only continuous controller for Backstage Kubernetes resources,
reader RBAC, and runtime configuration. Terraform provides Azure infrastructure
and secret bootstrap inputs only; it must not compete with ArgoCD for the
Backstage Helm release.

The ArgoCD Application is declared at
`gitops/apps/platform-access/manifests/backstage-app.yaml`. Before its first
sync, create the one-time runtime Secret without displaying its credential
values:

```powershell
.\scripts\prepare-backstage-argocd-runtime-secret.ps1
```

After ArgoCD has adopted a healthy `backstage` Application, remove only the
Terraform Helm resource from state in a reviewed migration. Never run
`terraform destroy` for the existing Backstage release.



## Getting Started

  To get started with Backstage in this project, follow these steps:

1. **Fork & Clone the Repository**:
    - First, fork the repository to your own GitHub account by clicking the "Fork" button on the repository page.
    - Then, clone your forked repository:
    ```sh
    git clone https://github.com/<your_fork>/aks-platform-engineering.git
    cd aks-platform-engineering/terraform
    ```

    NEED TO ADD SELF CERT GENERATION FROM OPENSSL.CNF FILE

2. **Deploy Terraform with Backstage**:
    To deploy Backstage, you can use the provided Terraform scripts. Navigate to the `terraform` directory and apply the configuration:
    ```sh
    cd terraform
    terraform apply -var build_backstage=true -var gitops_addons_org=https://github.com/owainow -var github_token=<your github token> -var backstage_github_client_id=<your GitHub OAuth client ID> -var backstage_github_client_secret=<your GitHub OAuth client secret> -var backstage_image_repository=<your ACR login server>/backstage -var backstage_image_tag=<your image tag> --auto-approve
    ```

    > **Note:** The customer demo uses Microsoft Entra sign-in through a shared app registration instead of a separate GitHub OAuth app. Add `https://<BACKSTAGE_IP>/api/auth/microsoft/handler/frame` as a web redirect URI, provide `backstage_azure_client_id` and `backstage_azure_client_secret`, and keep `manage_backstage_entra_credentials=false` when reusing the shared app. Use one common Backstage SSO entry group, `akspe-backstage-users`, and put only that group object ID in `backstage_allowed_group_object_ids` in an ignored tfvars file. The shared Enterprise Application should have assignment required enabled and be assigned to `akspe-backstage-users`; add future Backstage users or groups to that common group instead of editing Backstage config one group at a time. The Microsoft Graph Organization Provider is the authority for Catalog users and groups; do not pre-create production users in `backstage/packages/examples/org.yaml`. Build and push a custom Backstage image, then let the ArgoCD-managed Backstage Application deploy the immutable tag.

    > **Note:** GitHub PAT's can be created under your GitHub account under "Developer Settings". The required GitHub token permissions for Backstage in this case are related to the repository creation. The tempalte provided will create a new file in your forked repo. For classic GH PAT's this will be full repo access to create PR's and commit changes. For fine grained tokens this will be contents Read and Write and Pull Requests Read and Write permissions at the repository level. 

    ![pat permissions](image.png)

    Example of required GitHub Permissions
 
 
    > **Note:** There is an alert generated in the terraform output that informs you to go to your newly created backstage SP and "Grant Admin" to the SP. This is because onboarding all users from your entra tenant requires admin privileges. If you don't do this prior to Backstage deploying you will have to wait for the scheduled task to run again (Once an hour) or manually populate the users in the backstage user table. This can be done through the Azure portal at the following location: Entra - App registrations - Backstage - API Permissions - <click> Grant admin consent. This can also be done using the CLI with the following command: az ad app permission admin-consent --id <ApplicationId>.
 
 
 
3.  **OpenSSL Config File for self signed Backstage cert**:
    > **Note:** This step will be removed in the future and this part will be automated. For more information on the steps required to automate this self signed certificate request please refer to PR 102. 

    At the moment our tls secret on the cluster has been created with a dummy key and crt file. As we require a self signed certificate against the Public IP assigned to the Backstage service upon creation we will need to generate a new set of keys and recreate the kubernetes secret. We can do this with the following steps:

    1. Update the terraform/openssl.cnf file with your Backstage Public IP in the two places specified in the file
    2. Run the following command to recreate the tls key & crt: openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout tls.key -out tls.crt -config openssl.cnf
    3. Once created connect to your AKS cluster (Either through the CloudShell, CLI or Invoke Command) and run the following commands:
        ``` 
        kubectl delete secret my-tls-secret -n backstage
        kubectl create secret tls my-tls-secret --key=tls.key --cert=tls.crt -n backstage
        kubectl rollout restart deployment backstage-backstagechart -n backstage
        ```

 
  
 
4. **Access Backstage and Login**:
    To access Backstage navigate to the Azure Portal and view the external IP of your Backstage Service. You should be able to click on this link and access the IP address in the portal using Https. You can copy the IP address into your portal as follows "https://<BACKSTAGE_IP>"

    > **Security note:** The public IP is intended for demo access after GitHub authentication has been configured. Do not leave an unauthenticated Backstage instance exposed at `https://<BACKSTAGE_IP>`. For shared or production environments, front Backstage with an authenticated ingress or application gateway, restrict allowed source networks on the load balancer or ingress, and use a trusted certificate and DNS name instead of direct public-IP access.

    ![backstage portal](image-1.png)

    Once presented with the Backstage login, choose **Microsoft Entra ID**. The Entra account must be allowed through the common `akspe-backstage-users` group. ArgoCD reconciles the live Backstage `BACKSTAGE_ALLOWED_GROUP_IDS` value from `backstage/platform-backstage-sso`, so the application checks only that common group ID. Backstage then maps the email local part to a dynamic Backstage identity, for example `demouser1@contoso.com` becomes `User/default/demouser1`.

 
 
## Optional - Building Backstage Image
This repo uses a hosted Backstage image with Entra auth enabled, automatically onboarding users into your Backstage user list. It also has an example software catalog template to demo creating a GitOps pull request for an application deployment managed by ArgoCD. If you want to test Backstage please continue to getting started.

If you want to make changes to this image such as adding a different domain or new software catalogs you will need to make your changes, build your own image and change the deployment manifest to reference the image you have created. The source code for Backstage is found in the root Backstage folder. To build the image follow the steps below:

1. **Fork & Clone the Repository**:
    - First, fork the repository to your own GitHub account by clicking the "Fork" button on the repository page.
    - Then, clone your forked repository:
    ```sh
    git clone https://github.com/<your_fork>/aks-platform-engineering.git
    cd aks-platform-engineering/backstage

2. **Install Dependencies**: Ensure all dependencies are installed by running:

    ```sh
    yarn install
    ```
3. **Optional - Making Changes - New Software Template**
    The provided image exposes separate software templates for AKS and Arc/kind application delivery. The templates live under `backstage/packages/templates/deploy-aks-application` and `backstage/packages/templates/deploy-kind-application`, and each renders a catalog entity plus an ArgoCD `Application` manifest into the GitOps repository.

    This template can run in your own image or serve as an example for building additional golden paths, such as adding policy labels, namespace defaults, secrets integration, or environment promotion.


4. **Build the Project**: Run the build script defined in your `package.json`. Based on your previous commands, it looks like you need to build the backend:

    ```sh
    yarn build:backend --config ../../app-config-local.yaml
    ```

5. **Optional - Run the Application Locally**: After building the project, you can run it locally. Ensure that all necessary environment variables are set:

    ```sh
    export POSTGRES_HOST=your-local-postgres-host
    export POSTGRES_PORT=your-local-postgres-port
    export POSTGRES_USER=your-local-postgres-user
    export POSTGRES_PASSWORD=your-local-postgres-password
    export POSTGRES_DB=your-local-postgres-db

    yarn start --config ../../app-config-local.yaml
    ```

6. **Ensure Azure CLI is Installed**: Make sure you have the Azure CLI installed and logged in. If not, install it from [here](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) and log in using:

    ```sh
    az login
    ```

7. **Set Environment Variables**: Set the `ACR_NAME` and `RESOURCE_GROUP` environment variables:

    ```sh
    export ACR_NAME=your_acr_name
    export RESOURCE_GROUP=your_resource_group
    ```

8. **Build the Docker Image Locally**: Use the `docker build` command to build your Docker image:

    ```sh
    docker build -t $ACR_NAME.azurecr.io/my-backend-app:latest .
    ```

9. **Login to Azure Container Registry**: Use the Azure CLI to log in to your ACR:

    ```sh
    az acr login --name $ACR_NAME --resource-group $RESOURCE_GROUP
    ```

10. **Push the Docker Image to ACR**: Push the built image to your ACR:

    ```sh
    docker push $ACR_NAME.azurecr.io/my-backend-app:latest
    ```

    Deploy this custom image with Terraform by setting:

    ```sh
    terraform apply -var build_backstage=true -var backstage_image_repository=$ACR_NAME.azurecr.io/my-backend-app -var backstage_image_tag=latest
    ```

11. **Verify the Image in ACR**: You can verify that the image has been pushed to ACR by listing the repositories:

    ```sh
    az acr repository list --name $ACR_NAME --output table
    ```


## FAQ & Troubleshooting

1. 403 Odata error:

If this error occurs on terraform apply:
│ ApplicationsClient.BaseClient.Post(): unexpected status 403 with OData error: Authorization_RequestDenied: Insufficient privileges to complete the operation.
Give Application.ReadWrite.All permissions.

## Additional Resources

- [Backstage Documentation](https://backstage.io/docs)
- [Spotify's Backstage Blog](https://backstage.io/blog)
- [Project README](../README.md)
