# EnvChecker Installation Guide

## Table of Contents

* [EnvChecker Installation Guide](#envchecker-installation-guide)
  * [Table of Contents](#table-of-contents)
  * [Prerequisites](#prerequisites)
  * [How to configure view role for env-checker](#how-to-configure-view-role-for-env-checker)
  * [Third Party Software](#third-party-software)
  * [Deployment](#deployment)
    * [Local deployment](#local-deployment)
    * [Deployment Parameters](#deployment-parameters)
    * [HWE](#hwe)
    * [Read-only root filesystem](#read-only-root-filesystem)
  * [Tests](#tests)
    * [Sanity check](#sanity-check)
    * [Smoke test scenario](#smoke-test-scenario)

This document describes installation process for Qubership Environment Checker microservice.

## Prerequisites

Environment checker - should be installed inside the k8s cluster. The following are the prerequisites that must be met
before you start with the installation. The prerequisites are as follows:

It is required to perform a manual step of adding the clustered **view role** to the namespace account service (How to
do this, see more in the chapter "How to configure view role for env-checker")

## How to configure view role for env-checker

The env-checker service is started as ServiceAccount=env-checker-sa. In order for queries to be executed inside the
env-checker, you need to create a ClusterRoleBinding.

**ClusterRoleBinding.yaml example**

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: view-for-env-checker
subjects:
  - kind: ServiceAccount
    name: env-checker-sa # <--- env-checker service account
    namespace: {{ .Release.Namespace }} # <--- fill current namespace
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view # <--- ClusterRole with List of Rules for get\list\watch
```

## Third Party Software

The prerequisites are as follows:

| **Name**   | **Requirement** | **Version** |
| ---------- | --------------- | ----------- |
| Kubernetes | Mandatory       | 1.21+       |

## Deployment

### Local deployment

To quickly get started in a local Kubernetes environment, execute the following Helm command:

```bash
helm upgrade --install qubership-env-checker \
    --namespace=env-checker \
    --create-namespace \
    --set NAMESPACE=env-checker \
    charts/env-checker
```

Next, to access the UI of the env-checker service, you can either use port-forwarding:

```yaml
kubectl port-forward svc/env-checker 8080:8888 &
```

Or access it via Ingress. For Windows, you need to add the Ingress value to your hosts file:

```yaml
127.0.0.1         env-checker-env-checker.qubership
```

If you encounter issues executing kubectl commands, follow these steps:

Add your cluster's /.kube/config file to any directory within the env-checker pods. Change the value in the added configuration:
```yaml
clusters:
  server: https://127.0.0.1:6443
```

to

```yaml
clusters:
  server: https://kubernetes.default.svc.cluster.local:443
```

### Deployment Parameters

You may need to deploy the following Helm parameters during Environment checker installation. The deployment parameters
are described in the following table.

| **Parameter**                        | **Required (Mandatory\Optional)** | **Default value**  | **Value Example**                                       | **Description**                                                                                                                                                |
| ------------------------------------ | --------------------------------- | ------------------ |---------------------------------------------------------| -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| CLOUD_PUBLIC_HOST                    | M                                 | -                  | `k8s-apps10.k8s.qubership.org`                          | The public host is specified to create some Kubernetes elements, such as Ingress in env-checker.                                                               |
| CHOWN_HOME                           | O (M for Openshift)               | -                  | - / yes (for Openshift). possible values: 'yes' or 'no' | enables home directory ownership change during container deploy                                                                                                |
| CHOWN_HOME_OPTS                      | O (M for Openshift)               | -                  | - / '-R' (for Openshift). possible values: - / '-R'     | sets CHOWN_HOME mode to recursive                                                                                                                              |
| PRODUCTION_MODE                      | O                                 | FALSE              | Possible values: TRUE or FALSE                          | Flag indicating that the server is a production environment. env-checker will be launched in different modes (pod with Service/Ingres or no).                  |
| ENVIRONMENT_CHECKER_LOG_LEVEL        | O                                 | ERROR              | DEBUG                                                   | Log level for all env-checker Notebooks. Any custom value is available. By default, only ERROR or DEBUG are used.                                              |
| OPS_IDP_URL                          | O (M for IDP integration)         | -                  | `https://keycloak.k8s.qubership.org`                    | URL to keycloak. If IDP parameters are not defined then access to Env Checker is allowable via Jupiter default token                                           |
| ENVCHECKER_KEYCLOACK_REALM           | O (M for IDP integration)         | -                  | test-realm                                              | Name of IDP realm. User for Env-checker authentication have to belong to the realm                                                                             |
| ENVCHECKER_KEYCLOACK_CLIENT_ID       | O (M for IDP integration)         | -                  | test-env-checker-client                                 | IDP Client ID which have to belong to the realm. Client parameter in IDP 'Valid Redirect URIs' have to contain env-checker ingress URL                         |
| ENVCHECKER_KEYCLOACK_CLIENT_SECRET   | O (M for IDP integration)         | -                  | b4iwkh7nQBSxIgBEtlYSxUfNuoGZY19K                        | IDP Client Secret. The value can be viewed in the Credentials tab on the idp client.\_If there is no Credentials tab. Set the Client authentication flag to ON |
| ENVIRONMENT_CHECKER_JOB_COMMAND      | O                                 | -                  | ./run.sh notebooks/TestNotebook.ipynb                   | Command to run env-checker shell in Job mode. **Required to create Kubernetes Job**                                                                            |
| ENVIRONMENT_CHECKER_CRON_JOB_COMMAND | O                                 | -                  | ./run.sh notebooks/TestNotebook.ipynb                   | Command to run env-checker shell in CronJob mode. **Required to create Kubernetes CronJob**                                                                    |
| ENVIRONMENT_CHECKER_CRON_SCHEDULE    | O                                 | -                  | 0 \*/1 \* \* \*                                         | Schedule the release of CronJob in Cron format. Runs for non prod environments. **Required to create Kubernetes CronJob**                                      |
| ENVIRONMENT_CHECKER_UI_ACCESS_TOKEN  | O                                 | <Random>           | token12345                                              | Token to log in to Env-Checker UI.                                                                                                                             |
| PAAS_PLATFORM                        | O                                 | KUBERNETES         | OPENSHIFT                                               | Target platform, `KUBERNETES` or `OPENSHIFT`. On `KUBERNETES` the pods request UID/GID 1000; on any other value the platform assigns the UID. |
| READONLY_CONTAINER_FILE_SYSTEM_ENABLED | O                               | TRUE               | FALSE                                                   | Non-production only: `FALSE` makes the env-checker root filesystem writable. Ignored when `PRODUCTION_MODE` is `TRUE`.             |
| HOME_VOLUME_SIZE_LIMIT               | O                                 | 512Mi              | 2Gi                                                     | Size limit of the ephemeral `/home/jovyan` volume. See [Read-only root filesystem](#read-only-root-filesystem).                                                |
| OUTPUT_VOLUME_SIZE_LIMIT             | O                                 | 100Mi              | 500Mi                                                   | Size limit of the ephemeral `/home/jovyan/out` volume that holds the results of the last `run.sh` invocation.                                                  |

### HWE

All information about profiles and the amount of allocated resources for them can be found at the
[following link](HardwareEstimationAndSizing.md):

### Read-only root filesystem

The containers run with `readOnlyRootFilesystem: true`: the image content, including the Python environment in
`/opt/conda`, cannot be modified at runtime. In production mode (`PRODUCTION_MODE: true`) this is always on. In
non-production mode `READONLY_CONTAINER_FILE_SYSTEM_ENABLED: false` makes the root filesystem of the env-checker
containers writable again; the oauth2-proxy container stays read-only. Three `emptyDir` volumes are writable in every
mode; their sizes are described in [Hardware Estimation and Sizing](HardwareEstimationAndSizing.md#ephemeral-storage):

| Path               | Purpose                                                                                     |
| ------------------ | ------------------------------------------------------------------------------------------- |
| `/home/jovyan`     | Working directory of JupyterLab: notebooks, cloned Git repositories, user files             |
| `/home/jovyan/out` | Results of the last `run.sh` invocation                                                     |
| `/tmp`             | Temporary files                                                                             |

The volumes live as long as the pod. Files written there are lost when the pod is deleted or rescheduled, which matches
the previous behavior of the container filesystem.

#### Installing packages at runtime

Packages built into the image work as before. With a read-only root filesystem, new packages can be installed at
runtime as long as they land in `/home/jovyan`; everything installed this way lives until the pod is deleted and counts
toward `HOME_VOLUME_SIZE_LIMIT`.

* `pip install <package>` from a notebook or terminal installs into the user site `/home/jovyan/.local` because
  `/opt/conda` is not writable. The package is importable from the default kernel right away.
* A virtual environment keeps experiments apart from the default kernel and still sees the packages of the image:

  ```bash
  python -m venv --system-site-packages ~/venvs/<name>
  ~/venvs/<name>/bin/pip install <package>
  ~/venvs/<name>/bin/python -m ipykernel install --user --name <name>
  ```

  The new kernel appears in the JupyterLab launcher.
* `mamba create -p ~/envs/<name> <package>` creates a separate conda environment. The image's conda configuration
  already falls back to `/home/jovyan/.conda` for environments and the package cache; the package cache alone takes
  about 200Mi, so raise `HOME_VOLUME_SIZE_LIMIT` before relying on this.
* `mamba install <package>` into the base environment writes to `/opt/conda` and needs a writable root filesystem:
  either add the package to the `Dockerfile` and rebuild the image, or, in non-production mode only, deploy with
  `READONLY_CONTAINER_FILE_SYSTEM_ENABLED: false`. Packages installed this way are also lost when the pod is deleted.

## Tests

### Sanity check

Check for non-prod environments

1. Log in to Kubernetes
2. Go to the namespace where env-checker was installed
3. Go to ingress service link (token to log in to UI may be configured via optional Helm parameter
   `ENVIRONMENT_CHECKER_UI_ACCESS_TOKEN`. If this parameter is not set, check value in secret `env-checker-ui-access-token` with random generated access token.
4. **ER** - Check if UI env-checker is available

### Smoke test scenario

For a smoke test, firstly need to make sure that the prerequisites have been set correctly,
namely the access rights for the service account. To do this, run the command in the JupiterLab UI terminal:

```bash
kubectl get ns
```

If an error occurs, check that the ClusterRoleBinding was created correctly
