import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import yaml from 'js-yaml';

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const backstageRoot = resolve(scriptDirectory, '..');
const repositoryRoot = resolve(backstageRoot, '..');
const catalogEntry = resolve(backstageRoot, 'catalog', 'catalog-info.yaml');
const externalGroups = new Set(
  (process.env.BACKSTAGE_CATALOG_EXTERNAL_GROUPS ??
    'k8sadmin,akspe-backstage-users,akspe-kind-cluster-deployers,akspe-aks-cluster-deployers')
    .split(',')
    .map(value => value.trim().toLowerCase())
    .filter(Boolean),
);

const parseDocuments = file => {
  const documents = yaml.loadAll(readFileSync(file, 'utf8'));
  return documents.filter(Boolean);
};

const entryDocuments = parseDocuments(catalogEntry);
if (entryDocuments.length !== 1 || entryDocuments[0].kind !== 'Location') {
  throw new Error(`${catalogEntry} must contain exactly one Location entity.`);
}

const targets = entryDocuments[0].spec?.targets;
if (!Array.isArray(targets) || targets.length === 0) {
  throw new Error(`${catalogEntry} must declare at least one catalog target.`);
}

const entities = targets.flatMap(target => {
  if (typeof target !== 'string' || /^https?:\/\//.test(target)) {
    throw new Error(`Catalog target must be a repository-relative path: ${String(target)}.`);
  }
  return parseDocuments(resolve(dirname(catalogEntry), target));
});

const refs = new Set();
const owners = [];
for (const entity of entities) {
  if (
    (typeof entity.apiVersion !== 'string' ||
      !['backstage.io/', 'scaffolder.backstage.io/'].some(prefix =>
        entity.apiVersion.startsWith(prefix),
      )) ||
    typeof entity.kind !== 'string' ||
    !entity.metadata?.name
  ) {
    throw new Error(
      `Invalid Catalog entity: apiVersion, kind, and metadata.name are required. Received ${JSON.stringify(entity)}.`,
    );
  }

  const namespace = entity.metadata.namespace ?? 'default';
  const ref = `${entity.kind.toLowerCase()}:${namespace}/${entity.metadata.name}`.toLowerCase();
  if (refs.has(ref)) {
    throw new Error(`Duplicate Catalog entity reference: ${ref}.`);
  }
  refs.add(ref);
  if (entity.spec?.owner) {
    owners.push(String(entity.spec.owner));
  }
}

for (const owner of owners) {
  const normalized = owner.includes(':')
    ? owner.toLowerCase()
    : `group:default/${owner.toLowerCase()}`;
  const ownerName = normalized.split('/').at(-1);
  if (!refs.has(normalized) && !externalGroups.has(ownerName)) {
    throw new Error(
      `Unresolved owner ${owner}. Add its entity to the Catalog or BACKSTAGE_CATALOG_EXTERNAL_GROUPS.`,
    );
  }
}

const templatesRequiringExistingApplications = new Set([
  'update-aks-application',
  'update-kind-application',
]);
for (const templateName of templatesRequiringExistingApplications) {
  const template = entities.find(
    entity => entity.kind === 'Template' && entity.metadata?.name === templateName,
  );
  const nameParameter = template?.spec?.parameters
    ?.flatMap(parameterGroup =>
      Object.entries(parameterGroup?.properties ?? {}).map(([name, schema]) => ({
        name,
        schema,
      })),
    )
    .find(parameter => parameter.name === 'name');
  if (
    nameParameter &&
    typeof nameParameter.schema === 'object' &&
    nameParameter.schema !== null &&
    Object.hasOwn(nameParameter.schema, 'default')
  ) {
    throw new Error(
      `${templateName} must not set a default application name. Update and cleanup workflows require an explicitly selected existing delivery application from the watched branch.`,
    );
  }
}

const generatedRoot = resolve(backstageRoot, 'generated');
const deliveryRoot = resolve(
  repositoryRoot,
  'gitops',
  'apps',
  'backstage-delivery',
);
const generatedCatalogTargets = new Set(
  targets.filter(target => target.startsWith('../generated/')),
);
const generatedTarget = name => `../generated/${name}/catalog-info.yaml`;
const deliveryNames = existsSync(deliveryRoot)
  ? readdirSync(deliveryRoot).filter(name =>
      statSync(resolve(deliveryRoot, name)).isDirectory(),
    )
  : [];
const generatedNames = existsSync(generatedRoot)
  ? readdirSync(generatedRoot).filter(name =>
      statSync(resolve(generatedRoot, name)).isDirectory(),
    )
  : [];

for (const name of deliveryNames) {
  const deliveryPath = resolve(deliveryRoot, name);
  const manifests = readdirSync(deliveryPath).filter(
    file =>
      file.startsWith(`${name}-`) &&
      (file.endsWith('-argocd-app.yaml') ||
        file.endsWith('-applicationset.yaml')),
  );
  if (manifests.length !== 1) {
    throw new Error(
      `Delivery ${name} must contain exactly one generated Application or ApplicationSet manifest.`,
    );
  }
  const descriptorPath = resolve(generatedRoot, name, 'catalog-info.yaml');
  if (!existsSync(descriptorPath)) {
    throw new Error(`Delivery ${name} is missing ${descriptorPath}.`);
  }
  if (!generatedCatalogTargets.has(generatedTarget(name))) {
    throw new Error(`Delivery ${name} is missing its Catalog index target.`);
  }
}

for (const name of generatedNames) {
  const descriptorPath = resolve(generatedRoot, name, 'catalog-info.yaml');
  if (
    existsSync(descriptorPath) &&
    !deliveryNames.includes(name)
  ) {
    throw new Error(
      `Generated Catalog descriptor ${name} has no matching delivery manifest.`,
    );
  }
}

for (const target of generatedCatalogTargets) {
  const match = /^\.\.\/generated\/([^/]+)\/catalog-info\.yaml$/.exec(target);
  if (!match || !deliveryNames.includes(match[1])) {
    throw new Error(`Catalog target ${target} has no matching delivery manifest.`);
  }
}

console.log(`Validated ${entities.length} production Catalog entities from ${catalogEntry}.`);
