import { AuthorizeResult } from '@backstage/plugin-permission-common';
import {
  templateParameterReadPermission,
  templateStepReadPermission,
} from '@backstage/plugin-scaffolder-common/alpha';
import { PlatformAccessPermissionPolicy } from './platformAccessPermissionPolicy';

const aksUser = {
  info: {
    ownershipEntityRefs: ['group:default/akspe-aks-cluster-deployers'],
  },
};

const kindUser = {
  info: {
    ownershipEntityRefs: ['group:default/akspe-kind-cluster-deployers'],
  },
};

const bothDeliveryGroupsUser = {
  info: {
    ownershipEntityRefs: [
      'group:default/akspe-aks-cluster-deployers',
      'group:default/akspe-kind-cluster-deployers',
    ],
  },
};

const ordinaryUser = {
  info: {
    ownershipEntityRefs: ['user:default/alice'],
  },
};

const policy = new PlatformAccessPermissionPolicy();

describe('PlatformAccessPermissionPolicy', () => {
  it('allows users in both deployer groups to read template parameters and steps', async () => {
    await expect(
      policy.handle(
        { permission: templateParameterReadPermission },
        bothDeliveryGroupsUser,
      ),
    ).resolves.toEqual({ result: AuthorizeResult.ALLOW });

    await expect(
      policy.handle({ permission: templateStepReadPermission }, bothDeliveryGroupsUser),
    ).resolves.toEqual({ result: AuthorizeResult.ALLOW });
  });

  it('uses tag-only Scaffolder conditions for AKS deployer template reads', async () => {
    const decision = await policy.handle(
      { permission: templateParameterReadPermission },
      aksUser,
    );
    const serializedDecision = JSON.stringify(decision);

    expect(decision.result).toBe(AuthorizeResult.CONDITIONAL);
    expect(serializedDecision).toContain('aks-delivery');
    expect(serializedDecision).not.toContain(
      'platform-access.akspe.io/allow-aks-deployers',
    );
    expect(serializedDecision).not.toContain('hasAnnotation');
  });

  it('uses tag-only Scaffolder conditions for kind deployer template reads', async () => {
    const decision = await policy.handle(
      { permission: templateStepReadPermission },
      kindUser,
    );
    const serializedDecision = JSON.stringify(decision);

    expect(decision.result).toBe(AuthorizeResult.CONDITIONAL);
    expect(serializedDecision).toContain('kind-delivery');
    expect(serializedDecision).not.toContain(
      'platform-access.akspe.io/allow-kind-deployers',
    );
    expect(serializedDecision).not.toContain('hasAnnotation');
  });

  it('hides protected delivery fields from users outside delivery groups', async () => {
    const decision = await policy.handle(
      { permission: templateParameterReadPermission },
      ordinaryUser,
    );
    const serializedDecision = JSON.stringify(decision);

    expect(decision.result).toBe(AuthorizeResult.CONDITIONAL);
    expect(serializedDecision).toContain('aks-delivery');
    expect(serializedDecision).toContain('kind-delivery');
    expect(serializedDecision).not.toContain('allow-aks-deployers');
    expect(serializedDecision).not.toContain('allow-kind-deployers');
  });
});
