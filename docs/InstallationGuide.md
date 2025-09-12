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

### HWE

All information about profiles and the amount of allocated resources for them can be found at the
[following link](HardwareEstimationAndSizing.md):

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
