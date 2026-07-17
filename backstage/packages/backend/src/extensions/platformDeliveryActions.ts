import { createBackendModule } from "@backstage/backend-plugin-api";
import { createTemplateAction } from "@backstage/plugin-scaffolder-node";
import { scaffolderActionsExtensionPoint } from "@backstage/plugin-scaffolder-node/alpha";
import { Dirent, promises as fs } from "fs";
import { relative, resolve, sep } from "path";

const APPLICATION_NAME_PATTERN = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
const DELIVERY_ROOT = "gitops/apps/backstage-delivery";
const CATALOG_ROOT = "backstage/generated";

type ManifestKind = "application" | "applicationset";

interface DeliveryWorkspaceInput {
  workspacePath: string;
  name: string;
}

interface RemovedDelivery {
  removedPaths: string[];
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

const getDeliveryManifestPaths = async (
  deliveryDirectory: string,
  name: string
) => {
  let entries: Dirent[];

  try {
    entries = await fs.readdir(deliveryDirectory, { withFileTypes: true });
  } catch (error) {
    if (isErrnoException(error) && error.code === "ENOENT") {
      throw new Error(
        `No generated delivery directory exists for application "${name}".`
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

export async function removeDeliveredApplication(
  input: DeliveryWorkspaceInput
): Promise<RemovedDelivery> {
  const { repoRoot, deliveryDirectory, catalogDirectory } =
    getDeliveryPaths(input);
  const deliveryManifests = await getDeliveryManifestPaths(
    deliveryDirectory,
    input.name
  );

  if (deliveryManifests.length === 0) {
    throw new Error(
      `No generated delivery manifest exists for application "${input.name}".`
    );
  }

  const removedPaths = [deliveryDirectory];
  await fs.rm(deliveryDirectory, { recursive: true, force: false });

  try {
    await fs.rm(catalogDirectory, { recursive: true, force: false });
    removedPaths.push(catalogDirectory);
  } catch (error) {
    if (!isErrnoException(error) || error.code !== "ENOENT") {
      throw error;
    }
  }

  return {
    removedPaths: removedPaths.map((path) => toRepositoryPath(repoRoot, path)),
  };
}

export async function replaceDeliveredApplicationManifest(
  input: DeliveryWorkspaceInput & {
    sourcePath: string;
    manifestKind: ManifestKind;
  }
): Promise<RemovedDelivery & { writtenPath: string }> {
  const { repoRoot, deliveryDirectory } = getDeliveryPaths(input);
  const currentManifests = await getDeliveryManifestPaths(
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

const createRemoveDeliveredApplicationAction = () =>
  createTemplateAction<{ name: string }>({
    id: "platform:remove-delivered-application",
    description:
      "Removes a generated delivery application directory and fails when no delivery manifest exists.",
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
        `Removed generated paths: ${result.removedPaths.join(", ")}`
      );
      ctx.output("removedPaths", result.removedPaths);
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
          createRemoveDeliveredApplicationAction(),
          createReplaceDeliveredApplicationManifestAction()
        );
      },
    });
  },
});
