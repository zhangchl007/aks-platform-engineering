## Purpose
<!-- Describe the intention of the changes being proposed. What problem does it solve or functionality does it add? -->
* ...

## Does this introduce a breaking change?
<!-- Mark one with an "x". -->
```
[ ] Yes
[ ] No
```

## Pull Request Type
What kind of change does this Pull Request introduce?

<!-- Please check the one that applies to this PR using "x". -->
```
[ ] Bugfix
[ ] Feature
[ ] Code style update (formatting, local variables)
[ ] Refactoring (no functional changes, no api changes)
[ ] Documentation content changes
[ ] Other... Please describe:
```

## How to Test
*  Get the code

```
git clone [repo-address]
cd [repo-name]
git checkout [branch-name]
npm install
```

* Test the code
<!-- Add steps to run the tests suite and/or manually test -->
```
```

## What to Check
Verify that the following are valid
* ...

## Project specification compliance
For Kubernetes, ArgoCD, Backstage delivery, Terraform, Helm, or script changes,
confirm compliance with `docs/project-specification.md`:

```
[ ] I read docs/project-specification.md for this change.
[ ] Kubernetes desired state is stored in GitOps source and reconciled by ArgoCD.
[ ] I identified the owning ArgoCD Application or ApplicationSet.
[ ] Terraform changes are limited to Azure infrastructure or one-time ArgoCD bootstrap.
[ ] No script, Helm command, kubectl workflow, or Terraform resource continuously mutates an ArgoCD-owned Kubernetes resource.
[ ] Secret handling uses the documented secure bootstrap exception only.
```

## Other Information
<!-- Add any other helpful information that may be needed here. -->
