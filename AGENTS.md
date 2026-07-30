# Repository agent instructions

## Scope

- This repository builds Qubership Environment Checker, a Jupyter-based service for validating Kubernetes and
  OpenShift environments and producing diagnostic reports.
- These instructions apply repository-wide. Keep component-specific guidance next to the component when needed.

## Repository map

- `Dockerfile` and `installation/` define the runtime image, startup scripts, and installed tooling.
- `jovyan/` contains the notebook runner, report and integration utilities, and the container-level test suite.
- `charts/env-checker/` contains the Helm chart for interactive and job-based deployments.
- `agent-packages/troubleshoot-env-checker/` contains the read-only troubleshooting APM package.

## Commands

- Run changed-file lint hooks from the root without the dependency updater:
  `SKIP=pre-commit-update pre-commit run --files <changed-file>...`.
- Build the runtime image from the root: `docker build -t qubership-env-checker .`.
- In the built image, run the unit suite from `/home/jovyan` with
  `bash run.sh --html=true tests/CompositeUnitTestNotebook.ipynb`.
- In the built image, exercise the bulk runner from `/home/jovyan` with
  `bash run.sh tests/composite_test.yaml`.

## Non-obvious invariants

- By default, `jovyan/run.sh` replaces top-level output files, old directories, and the selected `-o` subfolder under
  `/home/jovyan/out`; recent sibling directories can remain. Use a unique `-o <subfolder>` and inspect only that path.
- Keep the cluster-wide `view` ClusterRoleBinding an explicit operator step. The chart requires cross-namespace read
  access but does not own that binding; verify RBAC-related changes against `docs/InstallationGuide.md`.
- `docs/troubleshooting.md` is a symlink to the troubleshooting skill reference. Edit
  `agent-packages/troubleshoot-env-checker/.apm/skills/troubleshoot-env-checker/references/troubleshooting.md`, then
  verify the symlink still resolves to that file.

## Done when

- Changed-file hooks pass with the command above, without modifying dependency revisions.
- Runtime or runner changes pass the composite unit suite in the built image, and its final notebook result is true.
- Image changes pass the local Docker build above. Helm changes complete the manual `Helm Charts Release` dry run, or
  the final response reports that workflow as not run.
- Workflow and other lintable changes pass the changed-file hooks and the PR `Lint Code Base` check.
- The final response lists commands run, commands not run, and generated or linked artifacts that were reviewed.

## Context routing

- Before changing deployment modes, chart values, authentication, or RBAC, read `docs/InstallationGuide.md` and
  `docs/authorization.md` for the supported configuration and security boundaries.
- Before changing `jovyan/run.sh`, notebooks, or report tests, read `docs/tests/TestGuide.md` for container paths,
  report outputs, and the composite test contract.
- Before changing the troubleshooting package, read `agent-packages/troubleshoot-env-checker/README.md` and its
  `SKILL.md` because the package is intentionally read-only and advisory.
