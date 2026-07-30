# Agent instructions

## Repository

- Purpose: Qubership Environment Checker is a Jupyter-based microservice for validating Kubernetes and OpenShift
  environments and generating reports.
- Main paths: `charts/env-checker/` holds the Helm chart; `jovyan/` holds runtime and test assets;
  `agent-packages/troubleshoot-env-checker/` holds the advisory troubleshooting skill.
- Read `docs/InstallationGuide.md` for the parameter reference, hardware-sizing link, and smoke-test procedures.

## Commands

- Run the documented unit-test notebook from `/home/jovyan`:
  `bash run.sh --html=true tests/CompositeUnitTestNotebook.ipynb`.
- List troubleshooting catalog cases:

  ```bash
  python3 agent-packages/troubleshoot-env-checker/.apm/skills/troubleshoot-env-checker/scripts/show_cases.py \
    agent-packages/troubleshoot-env-checker/.apm/skills/troubleshoot-env-checker/references/troubleshooting.md
  ```

## Change boundaries

- Edit the troubleshooting reference at
  `agent-packages/troubleshoot-env-checker/.apm/skills/troubleshoot-env-checker/references/troubleshooting.md`;
  `docs/troubleshooting.md` is its symlink.
- Keep the troubleshooting skill read-only and advisory; it must not access or change live systems.

## Updating Key Conventions

- If a user corrects a mistake that could recur in this repository, propose the smallest complete instruction.
- Add the exact approved instruction; omit task-specific, personal, sensitive, duplicate, or tool-enforced guidance.

## Key Conventions

- No key conventions recorded yet.
