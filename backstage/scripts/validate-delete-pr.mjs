import { readFileSync } from 'node:fs';

const eventPath = process.env.GITHUB_EVENT_PATH;
if (!eventPath) {
  console.log('No GitHub event payload; skipping delete PR shape validation.');
  process.exit(0);
}

const event = JSON.parse(readFileSync(eventPath, 'utf8'));
const pullRequest = event.pull_request;
if (!pullRequest) {
  console.log('Not a pull_request event; skipping delete PR shape validation.');
  process.exit(0);
}

const title = pullRequest.title ?? '';
const body = pullRequest.body ?? '';
const isBackstageDeletePr =
  title === 'Remove Backstage delivered application' ||
  body.includes('Backstage request to remove delivered application');

if (!isBackstageDeletePr) {
  console.log('Not a Backstage delete PR; skipping delete PR shape validation.');
  process.exit(0);
}

const appNameMatch = /Backstage request to remove delivered application `([^`]+)`/.exec(body);
if (!appNameMatch) {
  throw new Error(
    'Backstage delete PR body must name the delivered application in backticks.',
  );
}

const appName = appNameMatch[1];
if (!/^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/.test(appName)) {
  throw new Error(`Invalid Backstage delivered application name: ${appName}.`);
}

const token = process.env.GITHUB_TOKEN;
const repository = process.env.GITHUB_REPOSITORY;
if (!token || !repository) {
  throw new Error('GITHUB_TOKEN and GITHUB_REPOSITORY are required for delete PR validation.');
}

const files = [];
let page = 1;
for (;;) {
  const response = await fetch(
    `https://api.github.com/repos/${repository}/pulls/${pullRequest.number}/files?per_page=100&page=${page}`,
    {
      headers: {
        authorization: `Bearer ${token}`,
        accept: 'application/vnd.github+json',
      },
    },
  );
  if (!response.ok) {
    throw new Error(`Failed to list pull request files: ${response.status} ${response.statusText}`);
  }

  const pageFiles = await response.json();
  files.push(...pageFiles);
  if (pageFiles.length < 100) {
    break;
  }
  page += 1;
}

const deliveryPrefix = `gitops/apps/backstage-delivery/${appName}/`;
const descriptorPath = `backstage/generated/${appName}/catalog-info.yaml`;
const catalogIndexPath = 'backstage/catalog/catalog-info.yaml';
const catalogTarget = `../generated/${appName}/catalog-info.yaml`;

const removedDeliveryManifest = files.some(
  file =>
    file.status === 'removed' &&
    file.filename.startsWith(deliveryPrefix) &&
    file.filename.startsWith(`${deliveryPrefix}${appName}-`) &&
    (file.filename.endsWith('-argocd-app.yaml') ||
      file.filename.endsWith('-applicationset.yaml')),
);
const removedDescriptor = files.some(
  file => file.status === 'removed' && file.filename === descriptorPath,
);
const removedCatalogTarget = files.some(
  file =>
    file.filename === catalogIndexPath &&
    file.status === 'modified' &&
    (file.patch ?? '').includes(`-    - ${catalogTarget}`),
);
const invalidDeliveryMutation = files.find(
  file => file.filename.startsWith(deliveryPrefix) && file.status !== 'removed',
);
const invalidDescriptorMutation = files.find(
  file =>
    file.filename.startsWith(`backstage/generated/${appName}/`) &&
    file.status !== 'removed',
);

const missing = [];
if (!removedDeliveryManifest) {
  missing.push(`removed delivery manifest under ${deliveryPrefix}`);
}
if (!removedDescriptor) {
  missing.push(`removed generated Catalog descriptor ${descriptorPath}`);
}
if (!removedCatalogTarget) {
  missing.push(`removed Catalog index target ${catalogTarget}`);
}
if (invalidDeliveryMutation) {
  missing.push(`only removals under ${deliveryPrefix}; saw ${invalidDeliveryMutation.status}`);
}
if (invalidDescriptorMutation) {
  missing.push(
    `only removals under backstage/generated/${appName}/; saw ${invalidDescriptorMutation.status}`,
  );
}

if (missing.length > 0) {
  throw new Error(
    `Backstage delete PR for ${appName} is incomplete. Required: ${missing.join('; ')}.`,
  );
}

console.log(`Validated complete Backstage delete PR shape for ${appName}.`);
