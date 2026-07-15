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

              if (allowedGroupIds.length > 0) {
                if (payload._claim_names?.groups) {
                  throw new Error(
                    'Microsoft sign-in failed because the token contains a group overage claim. Limit the app registration group claim to the Backstage demo group or add Microsoft Graph group lookup.',
                  );
                }

                const isAllowedGroupMember = allowedGroupIds.some(group =>
                  tokenGroupIds.includes(group),
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
              const groupEntity = stringifyEntityRef({
                kind: 'Group',
                namespace: DEFAULT_NAMESPACE,
                name: 'guests',
              });

              return ctx.issueToken({
                claims: {
                  sub: userEntity,
                  ent: [userEntity, groupEntity],
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
backend.add(import('@backstage/plugin-kubernetes-backend'));
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
backend.add(import('@backstage/plugin-events-backend'));
backend.add(
  import('@backstage/plugin-catalog-backend-module-scaffolder-entity-model'),
);
backend.start();