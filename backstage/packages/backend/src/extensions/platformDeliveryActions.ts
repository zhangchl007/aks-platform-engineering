import { createBackendModule } from "@backstage/backend-plugin-api";
import { createTemplateAction } from "@backstage/plugin-scaffolder-node";
import { scaffolderActionsExtensionPoint } from "@backstage/plugin-scaffolder-node/alpha";
import { Dirent, promises as fs } from "fs";
import { relative, resolve, sep } from "path";
import { dump, load } from "js-yaml";

const APPLICATION_NAME_PATTERN = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
const DELIVERY_ROOT = "gitops/apps/backstage-delivery";
const CATALOG_ROOT = "backstage/generated";
const CATALOG_INDEX = "backstage/catalog/catalog-info.yaml";

type ManifestKind = "application" | "applicationset";

interface DeliveryWorkspaceInput {
  workspacePath: string;
  name: string;
}

interface RemovedDelivery {
  removedPaths: string[];
}

interface DeliveredApplicationRemovalReceipt extends RemovedDelivery {
  catalogDescriptorPath: string;
  catalogTarget: string;
  deliveryManifestPaths: string[];
}

interface DeliveredApplicationRemovalContractInput extends DeliveryWorkspaceInput {
  catalogDescriptorPath: string;
  catalogTarget: string;
  deliveryManifestPaths: string[];
}

interface CatalogIndex {
  spec: {
    targets: string[];
  };
}

const toPosixPath = (path: string) => path.split(sep).join("/");

const isErrnoException = (error: unknown): error is NodeJS.ErrnoException =>
  typeof error === "object" && error !== null && "code" in error;

const assertApplicationName = (name: string) => {
  if (!APPLICATION_NAME_PATTERN.test(name)) {
    throw new Error(
      `Application name "${name}" must be a DNS-compatible lowercase name.`
    );
  }
};

const resolveWorkspacePath = (workspacePath: string, ...segments: string[]) => {
  const workspaceRoot = resolve(workspacePath);
  const candidate = resolve(workspaceRoot, ...segments);
  const candidateRelativePath = relative(workspaceRoot, candidate);

  if (
    candidateRelativePath === "" ||
    candidateRelativePath === ".." ||
    candidateRelativePath.startsWith(`..${sep}`)
  ) {
    throw new Error(
      "Resolved path must remain inside the Scaffolder workspace."
    );
  }

  return candidate;
};

const getDeliveryPaths = ({ workspacePath, name }: DeliveryWorkspaceInput) => {
  assertApplicationName(name);

  const repoRoot = resolveWorkspacePath(workspacePath, "gitops-repo");
  const deliveryDirectory = resolveWorkspacePath(repoRoot, DELIVERY_ROOT, name);
  const catalogDirectory = resolveWorkspacePath(repoRoot, CATALOG_ROOT, name);

  return { repoRoot, deliveryDirectory, catalogDirectory };
};

const isDeliveryManifest = (name: string, fileName: string) =>
  fileName.startsWith(`${name}-`) &&
  (fileName.endsWith("-argocd-app.yaml") ||
    fileName.endsWith("-applicationset.yaml"));

export const listDeliveredApplications = async (repoRoot: string) => {
  const deliveryRoot = resolveWorkspacePath(repoRoot, DELIVERY_ROOT);
  let entries: Dirent[];

  try {
    entries = await fs.readdir(deliveryRoot, { withFileTypes: true });
  } catch (error) {
    if (isErrnoException(error) && error.code === "ENOENT") {
      return [];
    }

    throw error;
  }

  const applicationNames = await Promise.all(
    entries
      .filter((entry) => entry.isDirectory())
      .map(async (entry) => {
        const deliveryDirectory = resolve(deliveryRoot, entry.name);
        const manifests = await getDeliveryManifestPaths(
          repoRoot,
          deliveryDirectory,
          entry.name
        );

        return manifests.length > 0 ? entry.name : undefined;
      })
  );

  return applicationNames
    .filter((name): name is string => Boolean(name))
    .sort();
};

const formatExistingApplications = (applicationNames: string[]) =>
  applicationNames.length > 0 ? applicationNames.join(", ") : "none";

const getDeliveryManifestPaths = async (
  repoRoot: string,
  deliveryDirectory: string,
  name: string
) => {
  let entries: Dirent[];

  try {
    entries = await fs.readdir(deliveryDirectory, { withFileTypes: true });
  } catch (error) {
    if (isErrnoException(error) && error.code === "ENOENT") {
      const applicationNames = await listDeliveredApplications(repoRoot);
      throw new Error(
        `No generated delivery directory exists for application "${name}". Existing Backstage-delivered applications on this branch: ${formatExistingApplications(applicationNames)}.`
      );
    }

    throw error;
  }

  return entries
    .filter((entry) => entry.isFile() && isDeliveryManifest(name, entry.name))
    .map((entry) => resolve(deliveryDirectory, entry.name));
};

const toRepositoryPath = (repoRoot: string, path: string) =>
  toPosixPath(relative(repoRoot, path));

const isCatalogIndex = (value: unknown): value is CatalogIndex => {
  if (typeof value !== "object" || value === null || !("spec" in value)) {
    return false;
  }

  const spec = value.spec;
  if (
    typeof spec !== "object" ||
    spec === null ||
    !("targets" in spec) ||
    !Array.isArray(spec.targets)
  ) {
    return false;
  }

  return spec.targets.every((target) => typeof target === "string");
};

const getCatalogIndex = async (repoRoot: string) => {
  const catalogIndexPath = resolveWorkspacePath(repoRoot, CATALOG_INDEX);
  const contents = await fs.readFile(catalogIndexPath, "utf8");
  const catalogIndex = load(contents);

  if (!isCatalogIndex(catalogIndex)) {
    throw new Error("Backstage Catalog index must contain spec.targets.");
  }

  return { catalogIndexPath, catalogIndex };
};

const getCatalogTarget = (name: string) =>
  `../generated/${name}/catalog-info.yaml`;

const expectedCatalogDescriptorPath = (name: string) =>
  `${CATALOG_ROOT}/${name}/catalog-info.yaml`;

const pathExists = async (path: string) => {
  try {
    await fs.access(path);
    return true;
  } catch (error) {
    if (isErrnoException(error) && error.code === "ENOENT") {
      return false;
    }

    throw error;
  }
};

const writeCatalogIndex = async (
  catalogIndexPath: string,
  catalogIndex: CatalogIndex
) => {
  await fs.writeFile(
    catalogIndexPath,
    dump(catalogIndex, { lineWidth: -1, noRefs: true }),
    "utf8"
  );
};

export async function addDeliveredCatalogTarget(
  input: DeliveryWorkspaceInput
): Promise<{ catalogTarget: string }> {
  const { repoRoot } = getDeliveryPaths(input);
  const { catalogIndexPath, catalogIndex } = await getCatalogIndex(repoRoot);
  const catalogTarget = getCatalogTarget(input.name);

  if (catalogIndex.spec.targets.includes(catalogTarget)) {
    throw new Error(
      `Catalog target for application "${input.name}" already exists.`
    );
  }

  catalogIndex.spec.targets.push(catalogTarget);
  await writeCatalogIndex(catalogIndexPath, catalogIndex);

  return { catalogTarget };
}

const removeDeliveredCatalogTarget = async (
  input: DeliveryWorkspaceInput
): Promise<string> => {
  const { repoRoot } = getDeliveryPaths(input);
  const { catalogIndexPath, catalogIndex } = await getCatalogIndex(repoRoot);
  const catalogTarget = getCatalogTarget(input.name);
  const targetIndex = catalogIndex.spec.targets.indexOf(catalogTarget);

  if (targetIndex === -1) {
    throw new Error(
      `Catalog target for application "${input.name}" does not exist.`
    );
  }

  catalogIndex.spec.targets.splice(targetIndex, 1);
  await writeCatalogIndex(catalogIndexPath, catalogIndex);
  return catalogTarget;
};

export async function removeDeliveredApplication(
  input: DeliveryWorkspaceInput
): Promise<DeliveredApplicationRemovalReceipt> {
  const { repoRoot, deliveryDirectory, catalogDirectory } =
    getDeliveryPaths(input);
  const deliveryManifests = await getDeliveryManifestPaths(
    repoRoot,
    deliveryDirectory,
    input.name
  );

  if (deliveryManifests.length === 0) {
    throw new Error(
      `No generated delivery manifest exists for application "${input.name}".`
    );
  }
  const catalogDescriptorPath = resolve(catalogDirectory, "catalog-info.yaml");
  if (!(await pathExists(catalogDescriptorPath))) {
    throw new Error(
      `Generated Catalog descriptor does not exist for application "${input.name}".`
    );
  }

  const catalogTarget = await removeDeliveredCatalogTarget(input);
  const removedPaths = [
    deliveryDirectory,
    resolve(repoRoot, CATALOG_INDEX),
    catalogDirectory,
  ];
  await fs.rm(deliveryDirectory, { recursive: true, force: false });
  await fs.rm(catalogDirectory, { recursive: true, force: false });

  await verifyDeliveredApplicationRemoval(input);

  return {
    removedPaths: removedPaths.map((path) => toRepositoryPath(repoRoot, path)),
    catalogDescriptorPath: toRepositoryPath(repoRoot, catalogDescriptorPath),
    catalogTarget,
    deliveryManifestPaths: deliveryManifests.map((path) =>
      toRepositoryPath(repoRoot, path)
    ),
  };
}

export async function verifyDeliveredApplicationRemoval(
  input: DeliveryWorkspaceInput
): Promise<void> {
  const { repoRoot, deliveryDirectory, catalogDirectory } =
    getDeliveryPaths(input);
  const catalogTarget = getCatalogTarget(input.name);

  if (await pathExists(deliveryDirectory)) {
    throw new Error(
      `Generated delivery directory still exists for application "${input.name}".`
    );
  }
  if (await pathExists(catalogDirectory)) {
    throw new Error(
      `Generated Catalog directory still exists for application "${input.name}".`
    );
  }

  const { catalogIndex } = await getCatalogIndex(repoRoot);
  if (catalogIndex.spec.targets.includes(catalogTarget)) {
    throw new Error(
      `Catalog target still exists for application "${input.name}".`
    );
  }
}

export async function assertDeliveredApplicationRemovalContract(
  input: DeliveredApplicationRemovalContractInput
): Promise<void> {
  assertApplicationName(input.name);

  if (input.deliveryManifestPaths.length === 0) {
    throw new Error(
      `Delete contract for application "${input.name}" must include at least one removed delivery manifest.`
    );
  }

  const { repoRoot } = getDeliveryPaths(input);
  const expectedManifestPrefix = `${DELIVERY_ROOT}/${input.name}/`;
  const expectedDescriptorPath = expectedCatalogDescriptorPath(input.name);
  const expectedTarget = getCatalogTarget(input.name);

  if (input.catalogDescriptorPath !== expectedDescriptorPath) {
    throw new Error(
      `Delete contract for application "${input.name}" must remove ${expectedDescriptorPath}.`
    );
  }
  if (input.catalogTarget !== expectedTarget) {
    throw new Error(
      `Delete contract for application "${input.name}" must remove Catalog target ${expectedTarget}.`
    );
  }

  for (const manifestPath of input.deliveryManifestPaths) {
    const manifestPathSegments = manifestPath.split("/");
    const manifestFileName =
      manifestPathSegments[manifestPathSegments.length - 1] ?? "";
    if (
      !manifestPath.startsWith(expectedManifestPrefix) ||
      !isDeliveryManifest(input.name, manifestFileName)
    ) {
      throw new Error(
        `Delete contract for application "${input.name}" contains unexpected delivery manifest path ${manifestPath}.`
      );
    }
    if (await pathExists(resolveWorkspacePath(repoRoot, manifestPath))) {
      throw new Error(
        `Delete contract for application "${input.name}" still has delivery manifest ${manifestPath}.`
      );
    }
  }

  if (await pathExists(resolveWorkspacePath(repoRoot, expectedDescriptorPath))) {
    throw new Error(
      `Delete contract for application "${input.name}" still has generated Catalog descriptor ${expectedDescriptorPath}.`
    );
  }

  await verifyDeliveredApplicationRemoval(input);
}

export async function replaceDeliveredApplicationManifest(
  input: DeliveryWorkspaceInput & {
    sourcePath: string;
    manifestKind: ManifestKind;
  }
): Promise<RemovedDelivery & { writtenPath: string }> {
  const { repoRoot, deliveryDirectory } = getDeliveryPaths(input);
  const currentManifests = await getDeliveryManifestPaths(
    repoRoot,
    deliveryDirectory,
    input.name
  );

  if (currentManifests.length === 0) {
    throw new Error(
      `No generated delivery manifest exists for application "${input.name}". Use a deployment template to create it first.`
    );
  }

  const sourcePath = resolveWorkspacePath(
    input.workspacePath,
    input.sourcePath
  );
  const sourceContents = await fs.readFile(sourcePath, "utf8");
  const suffix =
    input.manifestKind === "applicationset"
      ? "-applicationset.yaml"
      : "-argocd-app.yaml";
  const destinationPath = resolve(deliveryDirectory, `${input.name}${suffix}`);
  const destinationExists = currentManifests.includes(destinationPath);
  const destinationContents = destinationExists
    ? await fs.readFile(destinationPath, "utf8")
    : undefined;

  if (
    currentManifests.length === 1 &&
    destinationExists &&
    destinationContents === sourceContents
  ) {
    throw new Error(
      `Update for application "${input.name}" produces no GitOps manifest change.`
    );
  }

  await Promise.all(currentManifests.map((path) => fs.rm(path)));
  await fs.writeFile(destinationPath, sourceContents, "utf8");

  return {
    removedPaths: currentManifests.map((path) =>
      toRepositoryPath(repoRoot, path)
    ),
    writtenPath: toRepositoryPath(repoRoot, destinationPath),
  };
}

const createRemoveDeliveredApplicationV2Action = () =>
  createTemplateAction<{ name: string }>({
    id: "platform:remove-delivered-application-v2",
    description:
      "Atomically removes generated delivery artifacts and fails when any required artifact is absent.",
    schema: {
      input: {
        name: (z) => z.string().regex(APPLICATION_NAME_PATTERN),
      },
    },
    async handler(ctx) {
      const result = await removeDeliveredApplication({
        workspacePath: ctx.workspacePath,
        name: ctx.input.name,
      });

      ctx.logger.info(
        `Removed ${result.deliveryManifestPaths.join(", ")}, ${result.catalogDescriptorPath}, and Catalog target ${result.catalogTarget}.`
      );
      ctx.output("removedPaths", result.removedPaths);
      ctx.output("catalogDescriptorPath", result.catalogDescriptorPath);
      ctx.output("catalogTarget", result.catalogTarget);
      ctx.output("deliveryManifestPaths", result.deliveryManifestPaths);
    },
  });

const createVerifyDeliveredApplicationRemovalV2Action = () =>
  createTemplateAction<{ name: string }>({
    id: "platform:verify-delivered-application-removal-v2",
    description:
      "Verifies that generated delivery, Catalog descriptor, and Catalog target are absent before publishing a delete PR.",
    schema: {
      input: {
        name: (z) => z.string().regex(APPLICATION_NAME_PATTERN),
      },
    },
    async handler(ctx) {
      await verifyDeliveredApplicationRemoval({
        workspacePath: ctx.workspacePath,
        name: ctx.input.name,
      });
      ctx.logger.info(
        `Verified complete deletion of generated application "${ctx.input.name}".`
      );
    },
  });

const createAssertDeliveredApplicationRemovalContractV1Action = () =>
  createTemplateAction<{
    name: string;
    catalogDescriptorPath: string;
    catalogTarget: string;
    deliveryManifestPaths: string[];
  }>({
    id: "platform:assert-delivered-application-removal-contract-v1",
    description:
      "Fails before publishing a delete PR unless the complete generated delivery removal contract is present.",
    schema: {
      input: {
        name: (z) => z.string().regex(APPLICATION_NAME_PATTERN),
        catalogDescriptorPath: (z) => z.string().min(1),
        catalogTarget: (z) => z.string().min(1),
        deliveryManifestPaths: (z) => z.array(z.string().min(1)).min(1),
      },
    },
    async handler(ctx) {
      await assertDeliveredApplicationRemovalContract({
        workspacePath: ctx.workspacePath,
        name: ctx.input.name,
        catalogDescriptorPath: ctx.input.catalogDescriptorPath,
        catalogTarget: ctx.input.catalogTarget,
        deliveryManifestPaths: ctx.input.deliveryManifestPaths,
      });

      const branchName = `backstage/delete/${ctx.input.name}-${Date.now()}`;
      ctx.logger.info(
        `Verified complete delete contract for "${ctx.input.name}" and selected unique branch ${branchName}.`
      );
      ctx.output("branchName", branchName);
    },
  });

const createAddDeliveredCatalogTargetAction = () =>
  createTemplateAction<{ name: string }>({
    id: "platform:add-delivered-catalog-target",
    description:
      "Adds a generated application catalog descriptor to the Git-managed Catalog index.",
    schema: {
      input: {
        name: (z) => z.string().regex(APPLICATION_NAME_PATTERN),
      },
    },
    async handler(ctx) {
      const result = await addDeliveredCatalogTarget({
        workspacePath: ctx.workspacePath,
        name: ctx.input.name,
      });

      ctx.logger.info(`Added Git-managed Catalog target: ${result.catalogTarget}`);
      ctx.output("catalogTarget", result.catalogTarget);
    },
  });

const createReplaceDeliveredApplicationManifestAction = () =>
  createTemplateAction<{
    name: string;
    sourcePath: string;
    manifestKind: ManifestKind;
  }>({
    id: "platform:replace-delivered-application-manifest",
    description:
      "Replaces a generated delivery manifest and fails when the application is absent or unchanged.",
    schema: {
      input: {
        name: (z) => z.string().regex(APPLICATION_NAME_PATTERN),
        sourcePath: (z) => z.string().min(1),
        manifestKind: (z) => z.enum(["application", "applicationset"]),
      },
    },
    async handler(ctx) {
      const result = await replaceDeliveredApplicationManifest({
        workspacePath: ctx.workspacePath,
        name: ctx.input.name,
        sourcePath: ctx.input.sourcePath,
        manifestKind: ctx.input.manifestKind,
      });

      ctx.logger.info(
        `Replaced ${result.removedPaths.join(", ")} with ${result.writtenPath}.`
      );
      ctx.output("removedPaths", result.removedPaths);
      ctx.output("writtenPath", result.writtenPath);
    },
  });

export default createBackendModule({
  pluginId: "scaffolder",
  moduleId: "platform-delivery-actions",
  register(reg) {
    reg.registerInit({
      deps: { scaffolder: scaffolderActionsExtensionPoint },
      async init({ scaffolder }) {
        scaffolder.addActions(
          createRemoveDeliveredApplicationV2Action(),
          createVerifyDeliveredApplicationRemovalV2Action(),
          createAssertDeliveredApplicationRemovalContractV1Action(),
          createAddDeliveredCatalogTargetAction(),
          createReplaceDeliveredApplicationManifestAction()
        );
      },
    });
  },
});
