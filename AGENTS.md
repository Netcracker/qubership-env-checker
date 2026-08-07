# Repository agent instructions

## Scope

- This repository builds Qubership Environment Checker: a Jupyter-based container for Kubernetes and OpenShift
  validation, its Helm chart, and an advisory troubleshooting APM package.
- These instructions apply repository-wide; place narrower guidance beside the files it governs.

## Repository map

- `Dockerfile` and `installation/` assemble the image; `jovyan/` supplies the runtime scripts, utilities, notebooks,
  and tests copied to `/home/jovyan` in that image.
- `charts/env-checker/` contains the Helm chart for interactive and job-based deployments.
- `agent-packages/troubleshoot-env-checker/` is the source of the read-only troubleshooting skill and its reference.
- `.github/workflows/` and `.github/super-linter.env` define the automated build, release, link, and lint checks.

## Commands

- Build the local image from the repository root: `docker build -t qubership-env-checker .`.
- Run the full unit notebook in that image:
  `docker run --rm qubership-env-checker bash run.sh --html=true tests/CompositeUnitTestNotebook.ipynb`.
- Run one focused test in that image:
  `docker run --rm qubership-env-checker python /home/jovyan/tests/unittests/<area>/<name>_test.py`.
- Validate the Helm chart from the repository root: `helm lint charts/env-checker`.
- For changed files, run the applicable hook by ID with `pre-commit run <hook-id> --files <paths>`; hook IDs and
  configuration live in `.pre-commit-config.yaml`.

## Non-obvious invariants

- Keep the `jovyan/` to `/home/jovyan/` image layout intact: tests and scripts use absolute container paths. If the
  layout changes, update the Docker copy step and all affected paths, rebuild the image, and rerun the notebook suite.
- Edit the troubleshooting catalog at
  `agent-packages/troubleshoot-env-checker/.apm/skills/troubleshoot-env-checker/references/troubleshooting.md`;
  `docs/troubleshooting.md` is a symlink to that authoritative file.
- Do not use `pre-commit run --all-files` as a routine read-only check: the configured `pre-commit-update` hook rewrites
  `.pre-commit-config.yaml`. Select the non-updater hooks relevant to the changed files instead.
- Treat `jovyan/tests/unittests/integrations/` as inactive until the test guide enables it; the composite notebook runs
  the report and shell suites.

## Done when

- `git diff --check` passes and applicable configured lint hooks pass.
- Image or runtime changes build successfully and the focused or full containerized tests pass as appropriate.
- Helm changes pass `helm lint charts/env-checker` and preserve the intended interactive, Job, and CronJob rendering.
- Troubleshooting-package changes keep `docs/troubleshooting.md` linked to the package reference.
- Report every check run and any relevant check that could not be run.

## Context routing

- Before changing notebook execution or tests, read `docs/tests/TestGuide.md` for the supported suite and container
  paths.
- Before changing repository-backed notebook fetching, read `docs/GitIntegrationDocumentation.md` for both the current
  environment-variable flow and the deprecated compatibility flow.
- Before changing deployment values or templates, read `docs/InstallationGuide.md` for RBAC, modes, and smoke checks.
- Before changing the troubleshooting package, read `agent-packages/troubleshoot-env-checker/README.md` for its
  read-only contract and file layout.
