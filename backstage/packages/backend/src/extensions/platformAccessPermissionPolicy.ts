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

const AKS_DEPLOYER_GROUP = 'group:default/akspe-aks-cluster-deployers';
const KIND_DEPLOYER_GROUP = 'group:default/akspe-kind-cluster-deployers';

const parseList = (value: string | undefined) =>
  value
    ?.split(',')
    .map(item => item.trim().toLowerCase())
    .filter(Boolean) ?? [];

const toGroupRef = (value: string) =>
  value.startsWith('group:') ? value : `group:default/${value}`;

const ADMIN_GROUPS = (
  parseList(process.env.BACKSTAGE_ADMIN_GROUP_ENTITY_NAMES).length > 0
    ? parseList(process.env.BACKSTAGE_ADMIN_GROUP_ENTITY_NAMES)
    : ['k8sadmin']
).map(toGroupRef);

const hasGroup = (user: PolicyQueryUser | undefined, groupRef: string) =>
  user?.info.ownershipEntityRefs?.includes(groupRef) ?? false;

const hasAnyGroup = (
  user: PolicyQueryUser | undefined,
  groupRefs: string[],
) => groupRefs.some(groupRef => hasGroup(user, groupRef));

class PlatformAccessPermissionPolicy implements PermissionPolicy {
  async handle(
    request: PolicyQuery,
    user?: PolicyQueryUser,
  ): Promise<PolicyDecision> {
    if (hasAnyGroup(user, ADMIN_GROUPS)) {
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
          anyOf: [
            {
              not: scaffolderTemplateConditions.hasTag({
                tag: 'kind-delivery',
              }),
            },
            scaffolderTemplateConditions.hasAnnotation({
              annotation: 'platform-access.akspe.io/allow-aks-deployers',
              value: 'true',
            }),
          ],
        });
      }

      if (isKindDeployer) {
        return createScaffolderTemplateConditionalDecision(request.permission, {
          anyOf: [
            {
              not: scaffolderTemplateConditions.hasTag({
                tag: 'aks-delivery',
              }),
            },
            scaffolderTemplateConditions.hasAnnotation({
              annotation: 'platform-access.akspe.io/allow-kind-deployers',
              value: 'true',
            }),
          ],
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
