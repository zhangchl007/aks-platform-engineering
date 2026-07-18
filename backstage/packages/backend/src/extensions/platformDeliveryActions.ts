import { createBackendModule } from "@backstage/backend-plugin-api";
import { createTemplateAction } from "@backstage/plugin-scaffolder-node";
import { scaffolderActionsExtensionPoint } from "@backstage/plugin-scaffolder-node/alpha";
import { Dirent, promises as fs } from "fs";
import { relative, resolve, sep } from "path";
import { dump, load } from "js-yaml";

const APPLICATION_NAME_PATTERN = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
const DELIVERY_ROOT = "gitops/apps/backstage-delivery";
const CATALOG_INDEX = "backstage/catalog/catalog-info.yaml";

type ManifestKind = "application" | "applicationset";

interface DeliveryWorkspaceInput {
  workspacePath: string;
  name: string;
}

interface ReplacedDelivery {
  removedPaths: string[];
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

  return { repoRoot, deliveryDirectory };
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

export async function replaceDeliveredApplicationManifest(
  input: DeliveryWorkspaceInput & {
    sourcePath: string;
    manifestKind: ManifestKind;
  }
): Promise<ReplacedDelivery & { writtenPath: string }> {
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
          createAddDeliveredCatalogTargetAction(),
          createReplaceDeliveredApplicationManifestAction()
        );
      },
    });
  },
});
