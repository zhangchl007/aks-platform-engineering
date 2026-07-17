import { createBackendModule } from '@backstage/backend-plugin-api';
import {
  AuthorizeResult,
  isPermission,
  isResourcePermission,
  PolicyDecision,
} from '@backstage/plugin-permission-common';
import {
  PermissionPolicy,
  PolicyQuery,
  PolicyQueryUser,
} from '@backstage/plugin-permission-node';
import { policyExtensionPoint } from '@backstage/plugin-permission-node/alpha';
import {
  catalogEntityReadPermission,
  RESOURCE_TYPE_CATALOG_ENTITY,
} from '@backstage/plugin-catalog-common/alpha';
import {
  catalogConditions,
  createCatalogConditionalDecision,
} from '@backstage/plugin-catalog-backend/alpha';
import {
  templateParameterReadPermission,
  templateStepReadPermission,
} from '@backstage/plugin-scaffolder-common/alpha';
import {
  createScaffolderTemplateConditionalDecision,
  scaffolderTemplateConditions,
} from '@backstage/plugin-scaffolder-backend/alpha';

const K8S_ADMIN_GROUP = 'group:default/k8sadmin';
const AKS_DEPLOYER_GROUP = 'group:default/akspe-aks-cluster-deployers';
const KIND_DEPLOYER_GROUP = 'group:default/akspe-kind-cluster-deployers';

const hasGroup = (user: PolicyQueryUser | undefined, groupRef: string) =>
  user?.info.ownershipEntityRefs?.includes(groupRef) ?? false;

class PlatformAccessPermissionPolicy implements PermissionPolicy {
  async handle(
    request: PolicyQuery,
    user?: PolicyQueryUser,
  ): Promise<PolicyDecision> {
    if (hasGroup(user, K8S_ADMIN_GROUP)) {
      return { result: AuthorizeResult.ALLOW };
    }

    const isAksDeployer = hasGroup(user, AKS_DEPLOYER_GROUP);
    const isKindDeployer = hasGroup(user, KIND_DEPLOYER_GROUP);

    if (
      isPermission(request.permission, catalogEntityReadPermission) &&
      isResourcePermission(
        request.permission,
        RESOURCE_TYPE_CATALOG_ENTITY,
      )
    ) {
      return createCatalogConditionalDecision(request.permission, {
        anyOf: [
          {
            not: catalogConditions.hasAnnotation({
              annotation: 'platform-access.akspe.io/protected',
              value: 'true',
            }),
          },
          ...(isAksDeployer
            ? [
                catalogConditions.hasAnnotation({
                  annotation: 'platform-access.akspe.io/allow-aks-deployers',
                  value: 'true',
                }),
              ]
            : []),
          ...(isKindDeployer
            ? [
                catalogConditions.hasAnnotation({
                  annotation: 'platform-access.akspe.io/allow-kind-deployers',
                  value: 'true',
                }),
              ]
            : []),
        ],
      });
    }

    if (
      isResourcePermission(request.permission, 'scaffolder-template') &&
      (isPermission(request.permission, templateParameterReadPermission) ||
        isPermission(request.permission, templateStepReadPermission))
    ) {
      if (isAksDeployer && isKindDeployer) {
        return { result: AuthorizeResult.ALLOW };
      }

      if (isAksDeployer) {
        return createScaffolderTemplateConditionalDecision(request.permission, {
          not: scaffolderTemplateConditions.hasTag({ tag: 'kind-delivery' }),
        });
      }

      if (isKindDeployer) {
        return createScaffolderTemplateConditionalDecision(request.permission, {
          not: scaffolderTemplateConditions.hasTag({ tag: 'aks-delivery' }),
        });
      }

      return createScaffolderTemplateConditionalDecision(request.permission, {
        not: {
          anyOf: [
            scaffolderTemplateConditions.hasTag({ tag: 'aks-delivery' }),
            scaffolderTemplateConditions.hasTag({ tag: 'kind-delivery' }),
          ],
        },
      });
    }

    return { result: AuthorizeResult.ALLOW };
  }
}

export default createBackendModule({
  pluginId: 'permission',
  moduleId: 'platform-access-policy',
  register(reg) {
    reg.registerInit({
      deps: { policy: policyExtensionPoint },
      async init({ policy }) {
        policy.setPolicy(new PlatformAccessPermissionPolicy());
      },
    });
  },
});
