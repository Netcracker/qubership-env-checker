# Repository agent instructions

## Scope

- Qubership Environment Checker is a Jupyter-based service that validates Kubernetes and OpenShift environments.
- This file contains repository-wide guidance; keep path-specific rules near the affected code.

## Repository map

- `charts/env-checker/` contains the Helm chart for deployment configuration.
- `Dockerfile`, `installation/`, and `jovyan/` define the container image, startup scripts, and runtime behavior.
- `jovyan/tests/` contains notebook-driven unit-test sources and examples.
- `agent-packages/troubleshoot-env-checker/` packages the read-only troubleshooting skill and its reference catalog.

## Commands

- For changes to these root instructions, run `pre-commit run --files AGENTS.md CLAUDE.md`.
- For the repository-wide configured pre-commit checks, run `pre-commit run --all-files`.
- To run the documented notebook unit-test flow inside the image, from `/home/jovyan` run
  `bash run.sh --html=true tests/CompositeUnitTestNotebook.ipynb`.
- Pull requests run the `Lint Code Base` Super-Linter workflow; run the applicable local checks before relying on CI.

## Non-obvious invariants

- Keep production deployments headless: `PRODUCTION_MODE=true` intentionally removes interactive UI because
  env-checker has cluster-wide `view` access; verify deployment changes in `charts/env-checker/`.
- `docs/troubleshooting.md` is a symlink. Update the catalog at
  `agent-packages/troubleshoot-env-checker/.apm/skills/troubleshoot-env-checker/references/troubleshooting.md`
  instead and verify the link target.

## Done when

- Relevant configured checks pass, including `pre-commit` for changed text or configuration files.
- Runtime changes use the documented notebook test flow when applicable.
- Report checks run and checks that could not be run.

## Context routing

- Before changing deployment parameters or access, read `docs/InstallationGuide.md` for the supported modes
  and RBAC requirements.
- Before changing notebook execution or test behavior, read `docs/tests/TestGuide.md` for the container
  working directory and supported test flow.
