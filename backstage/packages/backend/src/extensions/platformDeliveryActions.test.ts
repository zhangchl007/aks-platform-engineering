import { promises as fs } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import {
  addDeliveredCatalogTarget,
  removeDeliveredApplication,
  replaceDeliveredApplicationManifest,
  verifyDeliveredApplicationRemoval,
} from "./platformDeliveryActions";

const createWorkspace = async () => {
  const workspacePath = await fs.mkdtemp(join(tmpdir(), "backstage-delivery-"));
  const repoPath = join(workspacePath, "gitops-repo");

  await fs.mkdir(
    join(repoPath, "gitops", "apps", "backstage-delivery", "kind-store-demo"),
    { recursive: true }
  );
  await fs.mkdir(join(repoPath, "backstage", "generated", "kind-store-demo"), {
    recursive: true,
  });
  await fs.mkdir(join(repoPath, "backstage", "catalog"), { recursive: true });
  await fs.writeFile(
    join(repoPath, "backstage", "catalog", "catalog-info.yaml"),
    [
      "apiVersion: backstage.io/v1alpha1",
      "kind: Location",
      "metadata:",
      "  name: platform-catalog",
      "spec:",
      "  type: url",
      "  targets: []",
      "",
    ].join("\n")
  );

  return { workspacePath, repoPath };
};

describe("platform delivery actions", () => {
  it("removes the complete ApplicationSet and generated catalog directories", async () => {
    const { workspacePath, repoPath } = await createWorkspace();

    await fs.writeFile(
      join(
        repoPath,
        "gitops",
        "apps",
        "backstage-delivery",
        "kind-store-demo",
        "kind-store-demo-applicationset.yaml"
      ),
      "kind: ApplicationSet\n"
    );
    await fs.writeFile(
      join(
        repoPath,
        "gitops",
        "apps",
        "backstage-delivery",
        "kind-store-demo",
        ".keep"
      ),
      ""
    );
    await fs.writeFile(
      join(
        repoPath,
        "backstage",
        "generated",
        "kind-store-demo",
        "catalog-info.yaml"
      ),
      "kind: Component\n"
    );
    await addDeliveredCatalogTarget({
      workspacePath,
      name: "kind-store-demo",
    });

    const result = await removeDeliveredApplication({
      workspacePath,
      name: "kind-store-demo",
    });

    await expect(
      fs.access(
        join(
          repoPath,
          "gitops",
          "apps",
          "backstage-delivery",
          "kind-store-demo"
        )
      )
    ).rejects.toThrow();
    await expect(
      fs.access(join(repoPath, "backstage", "generated", "kind-store-demo"))
    ).rejects.toThrow();
    expect(result.removedPaths).toEqual([
      "gitops/apps/backstage-delivery/kind-store-demo",
      "backstage/catalog/catalog-info.yaml",
      "backstage/generated/kind-store-demo",
    ]);

    await fs.rm(workspacePath, { recursive: true, force: true });
  });

  it("adds a generated component target to the Git-managed Catalog index", async () => {
    const { workspacePath, repoPath } = await createWorkspace();

    const result = await addDeliveredCatalogTarget({
      workspacePath,
      name: "kind-store-demo",
    });
    const catalogIndex = await fs.readFile(
      join(repoPath, "backstage", "catalog", "catalog-info.yaml"),
      "utf8"
    );

    expect(result.catalogTarget).toBe(
      "../generated/kind-store-demo/catalog-info.yaml"
    );
    expect(catalogIndex).toContain(
      "../generated/kind-store-demo/catalog-info.yaml"
    );
    await expect(
      addDeliveredCatalogTarget({
        workspacePath,
        name: "kind-store-demo",
      })
    ).rejects.toThrow("already exists");

    await fs.rm(workspacePath, { recursive: true, force: true });
  });

  it("removes legacy application manifests before writing the replacement", async () => {
    const { workspacePath, repoPath } = await createWorkspace();
    const deliveryPath = join(
      repoPath,
      "gitops",
      "apps",
      "backstage-delivery",
      "kind-store-demo"
    );
    const sourcePath = join(
      workspacePath,
      "rendered-update",
      "application-set.yaml"
    );

    await fs.writeFile(
      join(deliveryPath, "kind-store-demo-argocd-app.yaml"),
      "kind: Application\n"
    );
    await fs.mkdir(join(workspacePath, "rendered-update"), { recursive: true });
    await fs.writeFile(sourcePath, "kind: ApplicationSet\n");

    const result = await replaceDeliveredApplicationManifest({
      workspacePath,
      name: "kind-store-demo",
      sourcePath: "./rendered-update/application-set.yaml",
      manifestKind: "applicationset",
    });

    await expect(
      fs.readFile(
        join(deliveryPath, "kind-store-demo-applicationset.yaml"),
        "utf8"
      )
    ).resolves.toBe("kind: ApplicationSet\n");
    await expect(
      fs.access(join(deliveryPath, "kind-store-demo-argocd-app.yaml"))
    ).rejects.toThrow();
    expect(result.removedPaths).toEqual([
      "gitops/apps/backstage-delivery/kind-store-demo/kind-store-demo-argocd-app.yaml",
    ]);

    await fs.rm(workspacePath, { recursive: true, force: true });
  });

  it("removes legacy hardcoded multi-cluster application directories", async () => {
    const { workspacePath, repoPath } = await createWorkspace();
    const deliveryPath = join(
      repoPath,
      "gitops",
      "apps",
      "backstage-delivery",
      "kind-store-demo"
    );

    await fs.writeFile(
      join(deliveryPath, "kind-store-demo-arc-demo-vm-argocd-app.yaml"),
      "kind: Application\n"
    );
    await fs.writeFile(
      join(
        repoPath,
        "backstage",
        "generated",
        "kind-store-demo",
        "catalog-info.yaml"
      ),
      "kind: Component\n"
    );
    await addDeliveredCatalogTarget({
      workspacePath,
      name: "kind-store-demo",
    });
    await fs.writeFile(
      join(deliveryPath, "kind-store-demo-arc-demo-vm-2-argocd-app.yaml"),
      "kind: Application\n"
    );

    const result = await removeDeliveredApplication({
      workspacePath,
      name: "kind-store-demo",
    });

    await expect(fs.access(deliveryPath)).rejects.toThrow();
    expect(result.removedPaths).toContain(
      "gitops/apps/backstage-delivery/kind-store-demo"
    );

    await fs.rm(workspacePath, { recursive: true, force: true });
  });

  it("fails closed when a generated Catalog artifact is missing", async () => {
    const { workspacePath, repoPath } = await createWorkspace();
    const deliveryPath = join(
      repoPath,
      "gitops",
      "apps",
      "backstage-delivery",
      "kind-store-demo"
    );

    await fs.writeFile(
      join(deliveryPath, "kind-store-demo-applicationset.yaml"),
      "kind: ApplicationSet\n"
    );

    await expect(
      removeDeliveredApplication({
        workspacePath,
        name: "kind-store-demo",
      })
    ).rejects.toThrow("Generated Catalog descriptor does not exist");
    await expect(fs.access(deliveryPath)).resolves.toBeUndefined();

    await fs.rm(workspacePath, { recursive: true, force: true });
  });

  it("fails closed when the Catalog index target is missing", async () => {
    const { workspacePath, repoPath } = await createWorkspace();
    const deliveryPath = join(
      repoPath,
      "gitops",
      "apps",
      "backstage-delivery",
      "kind-store-demo"
    );

    await fs.writeFile(
      join(deliveryPath, "kind-store-demo-applicationset.yaml"),
      "kind: ApplicationSet\n"
    );
    await fs.writeFile(
      join(
        repoPath,
        "backstage",
        "generated",
        "kind-store-demo",
        "catalog-info.yaml"
      ),
      "kind: Component\n"
    );

    await expect(
      removeDeliveredApplication({
        workspacePath,
        name: "kind-store-demo",
      })
    ).rejects.toThrow("Catalog target for application");
    await expect(fs.access(deliveryPath)).resolves.toBeUndefined();

    await fs.rm(workspacePath, { recursive: true, force: true });
  });

  it("detects a partially deleted application before PR publication", async () => {
    const { workspacePath, repoPath } = await createWorkspace();

    await fs.rm(
      join(
        repoPath,
        "gitops",
        "apps",
        "backstage-delivery",
        "kind-store-demo"
      ),
      { recursive: true }
    );

    await expect(
      verifyDeliveredApplicationRemoval({
        workspacePath,
        name: "kind-store-demo",
      })
    ).rejects.toThrow("Generated Catalog directory still exists");

    await fs.rm(workspacePath, { recursive: true, force: true });
  });

  it("fails when no generated delivery manifest exists", async () => {
    const { workspacePath } = await createWorkspace();

    await expect(
      removeDeliveredApplication({
        workspacePath,
        name: "kind-store-demo",
      })
    ).rejects.toThrow("No generated delivery manifest exists");

    await fs.rm(workspacePath, { recursive: true, force: true });
  });

  it("fails when an update would leave the generated manifest unchanged", async () => {
    const { workspacePath, repoPath } = await createWorkspace();
    const deliveryPath = join(
      repoPath,
      "gitops",
      "apps",
      "backstage-delivery",
      "kind-store-demo"
    );
    const sourcePath = join(
      workspacePath,
      "rendered-update",
      "application-set.yaml"
    );

    await fs.writeFile(
      join(deliveryPath, "kind-store-demo-applicationset.yaml"),
      "kind: ApplicationSet\n"
    );
    await fs.mkdir(join(workspacePath, "rendered-update"), { recursive: true });
    await fs.writeFile(sourcePath, "kind: ApplicationSet\n");

    await expect(
      replaceDeliveredApplicationManifest({
        workspacePath,
        name: "kind-store-demo",
        sourcePath: "./rendered-update/application-set.yaml",
        manifestKind: "applicationset",
      })
    ).rejects.toThrow("produces no GitOps manifest change");

    await fs.rm(workspacePath, { recursive: true, force: true });
  });

  it("rejects an application name that could escape the generated roots", async () => {
    const { workspacePath } = await createWorkspace();

    await expect(
      removeDeliveredApplication({
        workspacePath,
        name: "../kind-store-demo",
      })
    ).rejects.toThrow("DNS-compatible lowercase name");

    await fs.rm(workspacePath, { recursive: true, force: true });
  });
});
