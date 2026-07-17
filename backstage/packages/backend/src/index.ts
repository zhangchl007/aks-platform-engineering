import { createBackend } from '@backstage/backend-defaults';
import { createBackendModule } from '@backstage/backend-plugin-api';
import {
  DEFAULT_NAMESPACE,
  stringifyEntityRef,
} from '@backstage/catalog-model';
import { microsoftAuthenticator } from '@backstage/plugin-auth-backend-module-microsoft-provider';
import {
  authProvidersExtensionPoint,
  createOAuthProviderFactory,
} from '@backstage/plugin-auth-node';

const parseList = (value: string | undefined) =>
  value
    ?.split(',')
    .map(item => item.trim().toLowerCase())
    .filter(Boolean) ?? [];

const parseEntityNameList = (value: string | undefined, fallback: string[]) => {
  const configured = parseList(value);
  return configured.length > 0 ? configured : fallback;
};

const parseGroupMappings = (value: string | undefined) => {
  if (!value) {
    return new Map<string, string>();
  }

  const parsed = JSON.parse(value) as Record<string, unknown>;
  return new Map(
    Object.entries(parsed)
      .filter((entry): entry is [string, string] => typeof entry[1] === 'string')
      .map(([groupId, entityName]) => [groupId.toLowerCase(), entityName]),
  );
};

const resolveMicrosoftGraphGroupIds = async (
  objectId: string,
  tokenGroupIds: string[],
) => {
  const tenantId = process.env.AZURE_TENANT_ID;
  const clientId = process.env.AZURE_CLIENT_ID;
  const clientSecret = process.env.AZURE_CLIENT_SECRET;
  if (!tenantId || !clientId || !clientSecret) {
    throw new Error('Microsoft Graph group resolution requires Azure tenant, client ID, and client secret configuration.');
  }

  const tokenResponse = await fetch(
    `https://login.microsoftonline.com/${encodeURIComponent(tenantId)}/oauth2/v2.0/token`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: clientId,
        client_secret: clientSecret,
        grant_type: 'client_credentials',
        scope: 'https://graph.microsoft.com/.default',
      }),
    },
  );
  if (!tokenResponse.ok) {
    throw new Error(`Microsoft Graph token request failed with HTTP ${tokenResponse.status}.`);
  }

  const { access_token: accessToken } = (await tokenResponse.json()) as {
    access_token?: string;
  };
  if (!accessToken) {
    throw new Error('Microsoft Graph token response did not contain an access token.');
  }

  let nextUrl:
    | string
    | undefined = `https://graph.microsoft.com/v1.0/users/${encodeURIComponent(objectId)}/transitiveMemberOf/microsoft.graph.group?$select=id`;
  const resolvedGroupIds = new Set(tokenGroupIds);
  while (nextUrl) {
    const response = await fetch(nextUrl, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    if (!response.ok) {
      throw new Error(`Microsoft Graph group lookup failed with HTTP ${response.status}.`);
    }

    const payload = (await response.json()) as {
      value?: Array<{ id?: string }>;
      '@odata.nextLink'?: string;
    };
    for (const group of payload.value ?? []) {
      if (group.id) {
        resolvedGroupIds.add(group.id.toLowerCase());
      }
    }
    nextUrl = payload['@odata.nextLink'];
  }

  return [...resolvedGroupIds];
};

const parseJwtPayload = (token: string | undefined) => {
  if (!token) {
    return {};
  }

  const [, payload] = token.split('.');
  if (!payload) {
    return {};
  }

  return JSON.parse(Buffer.from(payload, 'base64url').toString('utf8')) as {
    groups?: string[];
    _claim_names?: { groups?: string };
    oid?: string;
  };
};

const customMicrosoftAuth = createBackendModule({
  pluginId: 'auth',
  moduleId: 'custom-microsoft-provider',
  register(reg) {
    reg.registerInit({
      deps: { providers: authProvidersExtensionPoint },
      async init({ providers }) {
        providers.registerProvider({
          providerId: 'microsoft',
          factory: createOAuthProviderFactory({
            authenticator: microsoftAuthenticator,
            async signInResolver(info, ctx) {
              const email = info.profile.email?.toLowerCase();
              if (!email) {
                throw new Error('Microsoft sign-in failed because the user profile has no email address.');
              }

              const allowedGroupIds = parseList(process.env.BACKSTAGE_ALLOWED_GROUP_IDS);
              const allowedDomains = parseList(process.env.BACKSTAGE_ALLOWED_EMAIL_DOMAINS);
              const domain = email.split('@')[1];
              const payload = parseJwtPayload(info.result.session.idToken);
              const tokenGroupIds = payload.groups?.map(group => group.toLowerCase()) ?? [];
              const effectiveGroupIds = payload.oid
                ? await resolveMicrosoftGraphGroupIds(payload.oid, tokenGroupIds)
                : tokenGroupIds;
              const groupMappings = parseGroupMappings(
                process.env.BACKSTAGE_ENTRA_GROUP_MAPPINGS,
              );
              const adminGroupIds = new Set(
                parseList(process.env.BACKSTAGE_ADMIN_GROUP_IDS),
              );
              const adminGroupNames = parseEntityNameList(
                process.env.BACKSTAGE_ADMIN_GROUP_ENTITY_NAMES,
                ['k8sadmin'],
              );

              if (allowedGroupIds.length > 0) {
                const isAllowedGroupMember = allowedGroupIds.some(group =>
                  effectiveGroupIds.includes(group),
                );

                if (!isAllowedGroupMember) {
                  throw new Error('Microsoft sign-in failed because the user is not in an allowed Backstage Entra group.');
                }
              } else if (!domain || !allowedDomains.includes(domain)) {
                throw new Error('Microsoft sign-in failed because no matching Backstage Entra group or email domain is configured.');
              }

              const [localPart] = email.split('@');
              const userEntity = stringifyEntityRef({
                kind: 'User',
                namespace: DEFAULT_NAMESPACE,
                name: localPart,
              });
              const groupNames = new Set(
                effectiveGroupIds
                  .map(groupId => groupMappings.get(groupId))
                  .filter((groupName): groupName is string => Boolean(groupName))
                  .map(groupName => groupName.toLowerCase()),
              );
              if (
                adminGroupIds.size > 0 &&
                effectiveGroupIds.some(groupId => adminGroupIds.has(groupId))
              ) {
                for (const adminGroupName of adminGroupNames) {
                  groupNames.add(adminGroupName);
                }
              }

              const groupEntities = [...groupNames].map(groupName =>
                stringifyEntityRef({
                  kind: 'Group',
                  namespace: DEFAULT_NAMESPACE,
                  name: groupName,
                }),
              );

              return ctx.issueToken({
                claims: {
                  sub: userEntity,
                  ent: [userEntity, ...new Set(groupEntities)],
                },
              });
            },
          }),
        });
      },
    });
  },
});


const backend = createBackend();
backend.add(import('@backstage/plugin-techdocs-backend'));
backend.add(import('@backstage/plugin-catalog-backend-module-github'));
backend.add(import('@backstage/plugin-catalog-backend-module-msgraph'));
backend.add(import('@backstage/plugin-kubernetes-backend'));
backend.add(import('@backstage/plugin-permission-backend'));
backend.add(import('@backstage/plugin-auth-backend'));
backend.add(import('@backstage/plugin-auth-backend-module-github-provider'));
backend.add(customMicrosoftAuth);
backend.add(import('@backstage/plugin-search-backend'));
backend.add(import('@backstage/plugin-search-backend-module-techdocs'));
backend.add(import('@backstage/plugin-search-backend-module-pg'));
backend.add(import('@backstage/plugin-app-backend'));
backend.add(import('@backstage/plugin-catalog-backend'));
backend.add(import('@backstage/plugin-scaffolder-backend'));
backend.add(import('@backstage/plugin-scaffolder-backend-module-github'));
backend.add(import('./extensions/platformDeliveryActions'));
backend.add(import('./extensions/platformAccessPermissionPolicy'));
backend.add(import('@backstage/plugin-events-backend'));
backend.add(
  import('@backstage/plugin-catalog-backend-module-scaffolder-entity-model'),
);
backend.start();