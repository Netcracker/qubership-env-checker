# Qubership Environment Checker — troubleshooting

Qubership Environment Checker (`env-checker`) is a JupyterLab-based container that validates Kubernetes and OpenShift
clusters. It runs notebooks through `papermill`, collects results, renders reports, and ships them to S3 and a
monitoring backend. It installs as a Helm chart in two modes: Non-Production (a long-running Deployment with a Jupyter
UI) and Production (a headless Job or CronJob).

The cases below are grouped by the component that owns the failure, in the order an operator reaches them: cluster
access and installation first, then the reporting integrations, then the UI and notebook runtime.

## RBAC and cluster access

Every check runs `kubectl` from inside the pod as the ServiceAccount `env-checker-sa`. The Helm chart ships only that
ServiceAccount; the cluster-wide `view` binding it needs is a manual install step. Missing or wrong RBAC is the most
common first-run failure.

### kubectl fails with "forbidden ... at the cluster scope"

**Symptoms:**

* A notebook cell or the smoke test `kubectl get ns` returns HTTP 403.
* The error names the ServiceAccount and ends in `at the cluster scope`:

<!-- markdownlint-disable line-length -->
```text
Error from server (Forbidden): namespaces is forbidden: User "system:serviceaccount:env-checker:env-checker-sa" cannot list resource "namespaces" in API group "" at the cluster scope
```
<!-- markdownlint-enable line-length -->

* The pod itself is `Running` and the UI is reachable; only the cluster queries fail.

**Root cause:**

A ServiceAccount holds no permissions on its own. Every API request is default-denied until an RBAC binding grants it.
Listing namespaces or any resource with `-A` is a cluster-scoped action, which only a `ClusterRoleBinding` can
authorize. The chart creates `env-checker-sa` but no binding, so until an operator adds one the token has no authority.

**How to check:**

1. Confirm the ServiceAccount cannot list cluster-scoped resources:

   ```bash
   kubectl auth can-i list namespaces --as=system:serviceaccount:env-checker:env-checker-sa
   ```

   A healthy install answers `yes`. A `no` confirms the missing binding.

2. List the ServiceAccount's effective permissions to see whether any cluster-wide read exists:

   ```bash
   kubectl auth can-i --list --as=system:serviceaccount:env-checker:env-checker-sa
   ```

   With no binding, only baseline self and discovery rules appear.

**How to fix:**

1. Grant the built-in read-only `view` ClusterRole cluster-wide. Adjust the namespace if the ServiceAccount is not in
   `env-checker`:

   ```bash
   kubectl create clusterrolebinding env-checker-view \
     --clusterrole=view \
     --serviceaccount=env-checker:env-checker-sa
   ```

2. The stock `view` role omits Secrets and RBAC objects by design. If a check must read those or other cluster-scoped
   kinds `view` misses, bind a custom read-only ClusterRole instead of widening the account beyond read access.

**How to avoid this issue:**

Treat the ClusterRoleBinding as a required install step next to `helm install`, and verify it with
`kubectl auth can-i list namespaces --as=...` in a post-install check rather than discovering it from a failing
notebook.

**Data to collect:**

* The full `Error from server (Forbidden): ...` line from the notebook or terminal.
* Output of `kubectl auth can-i --list --as=system:serviceaccount:<namespace>:env-checker-sa`.
* `kubectl get clusterrolebindings -o wide | grep env-checker-sa`.

**Sources:**

* Source code: `README.md:69-90` (Required RBAC Configuration), `docs/InstallationGuide.md:137-146` (smoke test).
* [Using RBAC Authorization — Kubernetes](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
* [namespaces is forbidden ... at the cluster scope — loft-sh/vcluster #652](https://github.com/loft-sh/vcluster/issues/652)

### kubectl works in one namespace but not cluster-wide

**Symptoms:**

* `kubectl get pods -n env-checker` succeeds, but `kubectl get ns` or `kubectl get pods -A` still returns 403.
* The denial ends in `at the cluster scope` or names a single namespace, even after a binding was added.
* An operator added a `RoleBinding` to `view` and is surprised access stays limited to one namespace.

**Root cause:**

A `RoleBinding` grants its permissions only inside its own namespace, even when it references a ClusterRole. It never
authorizes cluster-scoped resources such as namespaces, and it does not cover other namespaces. A cluster-wide
validator needs a `ClusterRoleBinding`. See the base case,
the "kubectl fails with forbidden ... at the cluster scope" case.

**How to check:**

1. Compare access inside and outside the ServiceAccount's namespace:

   ```bash
   kubectl auth can-i list pods -n env-checker  --as=system:serviceaccount:env-checker:env-checker-sa
   kubectl auth can-i list pods -n kube-system  --as=system:serviceaccount:env-checker:env-checker-sa
   kubectl auth can-i list namespaces           --as=system:serviceaccount:env-checker:env-checker-sa
   ```

   A `yes` in the account's own namespace but `no` elsewhere is the fingerprint of a namespaced binding used where a
   cluster-wide one is needed.

2. Find which kind of binding exists:

   ```bash
   kubectl get rolebindings,clusterrolebindings -A -o wide | grep env-checker-sa
   ```

**How to fix:**

1. Add a `ClusterRoleBinding` for the `view` role, as in the base case:

   ```bash
   kubectl create clusterrolebinding env-checker-view \
     --clusterrole=view \
     --serviceaccount=env-checker:env-checker-sa
   ```

2. Remove the namespaced `RoleBinding` once the cluster-wide one works, so the two do not drift. Do not try to cover the
   cluster with per-namespace bindings: they miss namespaces created later and never reach cluster-scoped objects.

**Sources:**

* [Using RBAC Authorization (RoleBinding namespace scope) — Kubernetes](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
* [cannot list resource in cluster scope despite binding — argoproj/argo-cd #9025](https://github.com/argoproj/argo-cd/issues/9025)

### OpenShift: forbidden at cluster scope, or permission denied inside the container

**Symptoms:**

* The same `... cannot list resource "namespaces" ... at the cluster scope` denial as on vanilla Kubernetes.
* A separate, unrelated-looking failure where the container process cannot write, for example
  `mkdir() "/var/cache/..." failed (13: Permission denied)` under the default `restricted-v2` SCC.

**Root cause:**

OpenShift enforces two orthogonal controls. RBAC (`ClusterRoleBinding`) decides what the ServiceAccount token may do
against the API; a Security Context Constraint (SCC) decides what the pod may do at runtime, such as its UID and
filesystem access. A missing binding produces the `Forbidden ... cluster scope` error. A too-restrictive SCC produces
the in-container permission-denied error. Granting an SCC never fixes an RBAC denial, and granting a role never fixes an
SCC denial.

**How to check:**

1. Test the API-side permission:

   ```bash
   oc auth can-i list namespaces --as=system:serviceaccount:env-checker:env-checker-sa
   oc get clusterrolebindings -o wide | grep env-checker-sa
   ```

2. Only if the pod also fails to start its process, inspect the SCC axis separately:

   ```bash
   oc adm policy who-can use scc restricted-v2
   ```

**How to fix:**

1. Grant a cluster-wide read role to the ServiceAccount. The `-z` flag expands to the ServiceAccount in the current
   namespace:

   ```bash
   oc adm policy add-cluster-role-to-user view -z env-checker-sa -n env-checker
   ```

   Prefer `cluster-reader` over `view` when the checks read cluster-scoped objects that `view` omits. Never grant
   `cluster-admin` to a read-only validator.

2. Only if the runtime SCC denial is present, grant an SCC as a distinct action:

   ```bash
   oc adm policy add-scc-to-user <scc> -z env-checker-sa -n env-checker
   ```

3. For OpenShift file-permission issues on the Jupyter home directory, set `CHOWN_HOME: "yes"` and
   `CHOWN_HOME_OPTS: "-R"` in the Helm values, as the repository documents.

**Sources:**

* Source code: `README.md:118-125` (OpenShift Configuration).
* [Using RBAC to define and apply permissions — OpenShift](https://docs.openshift.com/container-platform/latest/authentication/using-rbac.html)
* [Control OpenShift Pod Permissions with SCCs and Service Accounts — kifarunix](https://kifarunix.com/control-openshift-pod-permissions-with-sccs-and-service-accounts/)

## Installation and pod startup

### Container fails to start: "Container must not be started as root"

**Symptoms:**

* The pod never becomes ready; the container exits immediately after start.
* The container log ends with:

<!-- markdownlint-disable line-length -->
```text
ERROR: Container must not be started as root. Start with a non-root user (e.g., --user ${NB_UID}:${NB_GID}) or set runAsUser in Kubernetes.
```
<!-- markdownlint-enable line-length -->

**Root cause:**

The image's entry point `start.sh` refuses to run as UID 0 and exits 1. This is deliberate: the chart's security context
sets `runAsUser: 10001` and `runAsNonRoot: true`. The error appears when the pod is scheduled without that security
context, for example after overriding `securityContext` in custom values or running the image directly with `docker run`
as root.

**How to check:**

1. Inspect the effective security context of the deployed pod:

   ```bash
   kubectl get pod -l app.kubernetes.io/name=env-checker -n env-checker \
     -o jsonpath='{.items[0].spec.securityContext}{"\n"}{.items[0].spec.containers[0].securityContext}{"\n"}'
   ```

   A healthy pod shows a non-zero `runAsUser` and `runAsNonRoot: true`.

**How to fix:**

1. Restore a non-root security context in the Helm values so the pod runs as UID 10001, then reapply the release. Do not
   override the chart's `securityContext` with `runAsUser: 0`.
2. When running the image outside Kubernetes, pass `--user 10001:10001` (or the image's `NB_UID:NB_GID`).

**Sources:**

* Source code: `installation/shells/start.sh:74-77`, `charts/env-checker/templates/Deployment.yaml` (security context).

### S3 and monitoring see empty credentials on a standalone Helm install

**Symptoms:**

* Reports never reach the S3 bucket, and metrics never reach the monitoring backend, on an install done with `helm`
  alone.
* The monitoring push aborts the run with `Cannot determine URL of monitoring system.` (see the "Monitoring push exits
  with Cannot determine URL of monitoring system" case).
* S3 calls fail because the endpoint, access key, or secret resolve to empty.

**Root cause:**

The chart stores `MONITORING_URL`, `MONITORING_USER`, `MONITORING_PASSWORD`, `STORAGE_SERVER_URL`, `STORAGE_USERNAME`,
`STORAGE_PASSWORD`, and `STORAGE_REGION` in the `cloud-passport-envs` Secret, but the pod's environment injects only
`CLOUD_PUBLIC_HOST` from it. No template mounts that Secret as environment variables or as files under
`/etc/cloud-passport`. The code reads each value with `get_env_variable_value_by_name`, which looks first at
`/etc/cloud-passport/<VAR>` and then at the process environment. With neither present, every `MONITORING_*` and
`STORAGE_*` value resolves to `None`. These values reach the pod only when an external platform mounts the Secret at
`/etc/cloud-passport` — a standalone `helm install` does not.

**How to check:**

1. Confirm the values are absent inside the running pod:

   ```bash
   kubectl exec deploy/env-checker -n env-checker -- \
     sh -c 'echo "URL=[$MONITORING_URL] STORE=[$STORAGE_SERVER_URL]"; ls /etc/cloud-passport 2>&1'
   ```

   Empty brackets and a missing `/etc/cloud-passport` directory confirm the gap.

2. Confirm the Secret does hold the values:

   ```bash
   kubectl get secret cloud-passport-envs -n env-checker -o jsonpath='{.data.MONITORING_URL}' | base64 -d; echo
   ```

**How to fix:**

1. Mount the `cloud-passport-envs` Secret into the pod so the code can read it — either as environment variables with
   `envFrom` referencing the Secret, or as files under `/etc/cloud-passport`. Apply this through the platform that owns
   the cloud-passport contract when one is present.
2. Reapply the release and re-run a check; confirm with the `kubectl exec` command above that the values now resolve.

**How to avoid this issue:**

Verify `MONITORING_URL` and `STORAGE_SERVER_URL` resolve inside the pod before relying on report delivery. Reporting is
disabled, not degraded, when these are empty.

**Sources:**

* Source code: `charts/env-checker/templates/_templates.yaml:2-25` (pod env block),
  `charts/env-checker/templates/CloudPassportSecret.yaml`, `jovyan/utils/env_checker_utils.py:16-26`.

## Report storage (S3)

The report store is an S3-compatible backend reached with `boto3` and a custom `endpoint_url`, targeting AWS S3, MinIO,
or Ceph RGW. The client is built with `verify=False`, so TLS certificate errors do not surface here; connection,
credential, and bucket-access failures do. The region is hardcoded to `us-east-1` in `init_env_checker_bucket`. The
`STORAGE_REGION` value exists in the chart, but no code reads it, so changing the region needs a code edit, not a Helm
value. First confirm the credentials are wired at all — see the "S3 and monitoring see empty credentials on a standalone
Helm install" case.

### S3 run crashes: cannot connect to the S3 endpoint

**Symptoms:**

* The report ZIP never appears in the bucket, and the run crashes with an uncaught botocore traceback that names the
  endpoint:

<!-- markdownlint-disable line-length -->
```text
botocore.exceptions.EndpointConnectionError: Could not connect to the endpoint URL: "https://minio.example.com/"
```
<!-- markdownlint-enable line-length -->

**Root cause:**

botocore opens a socket to the resolved host and port before signing the request. A wrong scheme or port (MinIO commonly
listens on `:9000`) or an endpoint reachable only from a different network than the pod produces
`EndpointConnectionError`. `init_env_checker_bucket` catches only `ClientError`, which this is not, so it is uncaught
and crashes the run with a traceback rather than a friendly message.

**How to check:**

1. From the same pod that runs the upload, read the configured endpoint and confirm it answers. The value may arrive as
   a file under `/etc/cloud-passport` or as an environment variable:

   ```bash
   kubectl exec deploy/env-checker -n env-checker -- sh -c \
     'url=$(cat /etc/cloud-passport/STORAGE_SERVER_URL 2>/dev/null || printenv STORAGE_SERVER_URL); \
      echo "url=[$url]"; curl -sS -o /dev/null -w "%{http_code}\n" "$url"'
   ```

2. Confirm the scheme and port match the backend.

**How to fix:**

1. Correct `STORAGE_SERVER_URL` (scheme, host, port) in the values that populate the `cloud-passport-envs` Secret, and
   reapply the release.

**Sources:**

* Source code: `jovyan/utils/infra/s3.py:101-126` (client construction and the `ClientError`-only catch).
* [Could not connect to the endpoint URL — boto/boto3 #4684](https://github.com/boto/boto3/issues/4684)

### S3 startup aborts: "Unexpected error when trying to check S3 bucket existence"

**Symptoms:**

* The run stops during S3 initialization with `sys.exit(1)` and this line, where the trailing value is an HTTP status
  code such as `403`, `400`, or `301`:

<!-- markdownlint-disable line-length -->
```text
Unexpected error when trying to check S3 bucket existence: 403
```
<!-- markdownlint-enable line-length -->

* Reports never reach the bucket, because the run exits before any upload.

**Root cause:**

`init_env_checker_bucket` calls `head_bucket` on the configured bucket. A `404` means the bucket is absent and the code
creates it. Any other code is treated as fatal and exits 1. A `HEAD` response carries no error body, so botocore reports
the HTTP status as the code: `403` means the credentials were rejected or the key has no access to that bucket; `400` or
`301` means the signed region — hardcoded to `us-east-1` — does not match the region the backend serves.

**How to check:**

1. Read the numeric code in the message: `403` points at credentials or bucket access, `400` or `301` at the region.
2. Confirm which storage values reached the pod, reading each from its file or the environment without printing secrets:

   ```bash
   kubectl exec deploy/env-checker -n env-checker -- sh -c \
     'for v in STORAGE_SERVER_URL STORAGE_USERNAME ENVCHECKER_STORAGE_BUCKET; do \
        val=$(cat /etc/cloud-passport/$v 2>/dev/null || printenv $v); echo "$v=[${val:+set}]"; done'
   ```

3. For a `403` with credentials known to be correct, check the pod clock, since a large skew breaks request signing:

   ```bash
   kubectl exec deploy/env-checker -n env-checker -- date -u
   ```

**How to fix:**

1. For `403`, correct `STORAGE_USERNAME` and `STORAGE_PASSWORD`, or grant the key read and write access on
   `ENVCHECKER_STORAGE_BUCKET`, or point the config at a bucket the key owns. Store the secret values without a trailing
   newline. Reapply the release.
2. For `400` or `301`, the backend expects a region other than `us-east-1`. Fixing this needs a code change to the
   hardcoded `region_name` in `init_env_checker_bucket`; setting `STORAGE_REGION` has no effect, because the code does
   not read it.

**Data to collect:**

* The full `Unexpected error when trying to check S3 bucket existence: <code>` line.
* The output of the storage-values check above.

**Sources:**

* Source code: `jovyan/utils/infra/s3.py:101-126` (region hardcoded at `:111`, `head_bucket` handling at `:114-126`).
* [Resolve the S3 access-key error — AWS re:Post](https://repost.aws/knowledge-center/s3-access-key-error)
* [The authorization header is malformed; the region is wrong — AWS re:Post](https://repost.aws/questions/QUHQVY8pX5RgKISg-FjoeetA/)

### Reference: path-style addressing for custom S3 endpoints

This is background, not a single failure. Against MinIO, Ceph, or an IP-based endpoint, botocore's default `auto`
addressing prefers virtual-hosted style (`bucket.host`). Many S3-compatible backends and raw-IP endpoints support only
path-style (`host/bucket`), and a bucket subdomain will not resolve without wildcard DNS. The mismatch can surface as
`EndpointConnectionError`, an unexpected 404, or `SignatureDoesNotMatch`, because the host that gets signed changes.
When a custom endpoint fails these ways despite correct credentials, forcing path-style addressing
(`Config(s3={'addressing_style': 'path'})`) is the fix. This requires a code or config change rather than a Helm value.

**Sources:**

* [Amazon S3 — Boto3 documentation (addressing_style)](https://boto3.amazonaws.com/v1/documentation/api/latest/guide/s3.html)

## Monitoring metrics

Metrics are pushed to `MONITORING_URL` + `/api/v1/write` using the OpenTelemetry Prometheus remote-write exporter with
HTTP basic auth. Unlike the S3 client, this exporter verifies TLS (`insecure_skip_verify` is `False`), so certificate
errors do surface here. The exporter collapses every transport failure into one generic log line, so metrics simply
never appear and the distinguishing detail lives in the wrapped exception — a read-only `curl` preflight is the fastest
way to tell the cases apart (see the "Reference: why all monitoring failures look identical" section below).

### Monitoring push exits with "Cannot determine URL of monitoring system."

**Symptoms:**

* The run aborts as `MonitoringHelper` initializes, with `sys.exit(1)` and:

```text
Cannot determine URL of monitoring system.
```

**Root cause:**

`MonitoringHelper` reads `MONITORING_URL` at import time and exits 1 when it is `None`. On a standalone Helm install the
value is stored in the `cloud-passport-envs` Secret but never mounted into the pod, so it resolves to `None`. See
the "S3 and monitoring see empty credentials on a standalone Helm install" case
for the wiring gap that causes this.

**How to check:**

1. Confirm the value is empty in the pod:

   ```bash
   kubectl exec deploy/env-checker -n env-checker -- sh -c 'echo "[$MONITORING_URL]"; ls /etc/cloud-passport 2>&1'
   ```

**How to fix:**

1. Mount `cloud-passport-envs` into the pod so `MONITORING_URL` resolves, as in the credentials-wiring case. If this
   deployment does not use a monitoring backend, remove the code path that pushes metrics rather than leaving
   `MONITORING_URL` unset, since the unset value aborts the whole run.

**Sources:**

* Source code: `jovyan/utils/monitoringUtils.py:48-51`.

### Metrics never arrive: 401 or 403 on the remote-write endpoint

**Symptoms:**

* Metrics do not appear in the backend. The only app-side signal is one generic export-failure log line wrapping a
  `requests` error such as:

<!-- markdownlint-disable line-length -->
```text
Export POST request failed with reason: 401 Client Error: Unauthorized for url: https://monitoring.example.com/api/v1/write
```
<!-- markdownlint-enable line-length -->

* A `403 Client Error: Forbidden` variant appears when the credentials authenticate but lack write permission.

**Root cause:**

The exporter sends `MONITORING_USER` and `MONITORING_PASSWORD` as HTTP basic auth. A 401 means the backend rejected the
credentials — wrong, empty, or not wired through. A 403 means the credentials authenticated but the account or tenant
lacks write access, or a proxy in front blocks the path.

**How to check:**

1. Probe the endpoint read-only from the pod with the same credentials, reading each value from its file or the
   environment. A real remote-write receiver answers a `GET` with `405 Method Not Allowed`; `401` or `403` points at
   auth:

   ```bash
   kubectl exec deploy/env-checker -n env-checker -- sh -c \
     'u=$(cat /etc/cloud-passport/MONITORING_URL 2>/dev/null || printenv MONITORING_URL); \
      usr=$(cat /etc/cloud-passport/MONITORING_USER 2>/dev/null || printenv MONITORING_USER); \
      pw=$(cat /etc/cloud-passport/MONITORING_PASSWORD 2>/dev/null || printenv MONITORING_PASSWORD); \
      curl -sS -o /dev/null -w "%{http_code}\n" -u "$usr:$pw" "$u/api/v1/write"'
   ```

**How to fix:**

1. Supply correct credentials through `cloud-passport-envs` and reapply the release. For a 403, grant write access on
   the backend for that account or tenant, and check any intermediate proxy rules.

**Sources:**

* Source code: `jovyan/utils/monitoringUtils.py:52-67`.
* [How to implement basic authentication in prometheusremotewrite — opentelemetry-collector-contrib #40275](https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/40275)

### Metrics never arrive: TLS certificate verification fails

**Symptoms:**

* Metrics do not appear, and the generic export-failure line wraps a TLS error:

<!-- markdownlint-disable line-length -->
```text
Export POST request failed with reason: HTTPSConnectionPool(host='monitoring.example.com', port=443): Max retries exceeded with url: /api/v1/write (Caused by SSLError(SSLCertVerificationError(1, '[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: unable to get local issuer certificate')))
```
<!-- markdownlint-enable line-length -->

**Root cause:**

The exporter verifies the server certificate chain against the container's trust store. A backend presenting a
self-signed certificate, a private-CA certificate the image does not trust, or a certificate whose SAN does not match
the host in `MONITORING_URL` fails verification. This exporter keeps verification on, so the failure is a real
configuration problem, not a flag to flip.

**How to check:**

1. Inspect what the endpoint presents and whether a known CA validates it, from the pod:

   ```bash
   kubectl exec deploy/env-checker -n env-checker -- sh -c \
     'u=$(cat /etc/cloud-passport/MONITORING_URL 2>/dev/null || printenv MONITORING_URL); \
      curl -vsS -o /dev/null "$u/api/v1/write" 2>&1 | grep -Ei "SSL|certificate|subject|issuer"'
   ```

   If the same request succeeds with `--cacert <ca.pem>`, the CA is missing from the trust store.

**How to fix:**

1. Add the backend's CA to the container trust store, or use a `MONITORING_URL` host that matches the certificate's SAN.
   Reapply the release.
2. **DANGEROUS — removes transport protection and exposes credentials to interception.** Disabling certificate
   verification is not a fix. Do not set the exporter's `insecure_skip_verify` to `True` to silence this on a real
   network; trust the CA instead.

**Sources:**

* Source code: `jovyan/utils/monitoringUtils.py:60-67` (`insecure_skip_verify` is `False`).
* [Troubleshoot Collector certificate and TLS errors — OneUptime](https://oneuptime.com/blog/post/2026-02-06-troubleshoot-collector-certificate-tls-errors/view)

### Metrics never arrive: wrong URL or path (404 or connection refused)

**Symptoms:**

* Metrics do not appear, and the export-failure line wraps a connection or 404 error:
  * `Connection refused` when the host or port is wrong.
  * `404 Client Error: Not Found for url: .../api/v1/write` against a receiver that does not serve that path.
  * `unsupported path requested: "/api/v1/write"` from VictoriaMetrics cluster, which needs a tenant path.

**Root cause:**

The code builds the endpoint as `urljoin(MONITORING_URL, '/api/v1/write')`. Whether that path is correct depends on the
receiver: native Prometheus serves it only when started with `--web.enable-remote-write-receiver`; VictoriaMetrics
single-node serves it; Cortex, Mimir, and Thanos-receive use `/api/v1/push`. Because the appended path is absolute,
`urljoin` discards any path already in `MONITORING_URL`. A receiver whose push path carries a prefix — VictoriaMetrics
cluster's `/insert/<tenant>/prometheus/api/v1/write` — cannot be reached through `MONITORING_URL` at all, and returns
`unsupported path requested`.

**How to check:**

1. Probe reachability and the served path from the pod, reading the URL from its file or the environment. A `GET`
   returns `405` on a real receiver, `404` on a wrong path, or a connection error when unreachable:

   ```bash
   kubectl exec deploy/env-checker -n env-checker -- sh -c \
     'u=$(cat /etc/cloud-passport/MONITORING_URL 2>/dev/null || printenv MONITORING_URL); \
      echo "url=[$u]"; curl -sS -o /dev/null -w "%{http_code}\n" "$u/api/v1/write"'
   ```

**How to fix:**

1. Set `MONITORING_URL` so that its host plus `/api/v1/write` is the documented push path for the backend, and reapply
   the release. Enable `--web.enable-remote-write-receiver` for native Prometheus. A receiver that needs a path prefix
   or a `/api/v1/push` path cannot be targeted through `MONITORING_URL` alone; that requires a code change to how the
   endpoint is built.

**Sources:**

* Source code: `jovyan/utils/monitoringUtils.py:60-61` (`urljoin(MONITORING_URL, '/api/v1/write')`).
* [remote write receiver needs to be enabled — prometheus/prometheus #16209](https://github.com/prometheus/prometheus/issues/16209)
* [unsupported path requested "/api/v1/write" — VictoriaMetrics #8545](https://github.com/VictoriaMetrics/VictoriaMetrics/issues/8545)

### Reference: why all monitoring failures look identical

This is background for the monitoring cases above. The Python remote-write exporter catches every transport error and
logs one line, `Export POST request failed with reason: <exception>`, then returns a failure result without a visible
retry. Auth, TLS, wrong-path, and bad-sample failures therefore present the same way to an operator watching a
dashboard: metrics simply do not appear. The distinguishing detail is inside the wrapped exception and the receiver's
response body, neither of which the exporter surfaces. A read-only `curl` against `MONITORING_URL/api/v1/write` from the
pod — checking the status code — is the single highest-value step for separating these cases.

**Sources:**

* [Prometheus Remote-Write exporter (Python) — opentelemetry-python-contrib](https://github.com/open-telemetry/opentelemetry-python-contrib/tree/main/exporter/opentelemetry-exporter-prometheus-remote-write)

## External notebooks (Git)

The checker can fetch external notebooks from a Git repository over HTTPS with a username and token, using sparse
checkout. The current path is `jovyan/utils/integration/git_helper.py`, driven by `GIT_*` environment variables from the
`env-checker-git-secret`.

### Git fetch skipped: "Missing required Git configuration"

**Symptoms:**

* The fetch does nothing and logs:

```text
ERROR: Missing required Git configuration: repository_url, target_path
Required environment variables:
  GIT_REPOSITORY_URL - URL of the Git repository
  GIT_TARGET_PATH - Local directory where files will be fetched
```

**Root cause:**

`fetch_from_git_config` requires `GIT_REPOSITORY_URL` and `GIT_TARGET_PATH`. The chart populates the Git Secret only
when the Git values are set — either the new `git.username` and `git.token`, or the legacy `ENVCHECKER_GIT_*` trio. When
those values are unset, the environment variables are absent and the fetch reports them missing.

**How to check:**

1. Confirm which Git variables reached the pod:

   ```bash
   kubectl exec deploy/env-checker -n env-checker -- sh -c 'env | grep -E "^GIT_" || echo "no GIT_ vars set"'
   ```

**How to fix:**

1. Set `git.repositoryUrl` and `git.targetPath` (with `git.username` and `git.token`) in the Helm values so the Secret
   and the environment are populated, then reapply the release.

**Sources:**

* Source code: `jovyan/utils/integration/git_helper.py:160-198`, `charts/env-checker/templates/_templates.yaml` (Git env
  block).

### Git clone fails: authentication failed with a token

**Symptoms:**

* The clone or pull dies at the credential stage:

```text
fatal: Authentication failed for 'https://git.example.com/project/repo.git/'
remote: HTTP Basic: Access denied
```

* On GitHub: `remote: Support for password authentication was removed on August 13, 2021.`
* On GitLab with 2FA: `remote: You have 2FA enabled, please use a personal access token for Git over HTTP.`

**Root cause:**

The helper embeds `GIT_USERNAME` and `GIT_TOKEN` into the URL as `https://<username>:<password>@host/...`. The remote
rejects the request when the token is expired, revoked, scoped too narrowly, or when a real account password is used in
place of a token. GitHub and GitLab require a token in the password field for Git over HTTPS.

**How to check:**

1. Reproduce the authentication read-only, without writing anything and without putting the token on any command line.
   A one-shot credential helper feeds the pod's own `GIT_USERNAME` and `GIT_TOKEN` to Git, so the token reaches neither
   your shell history nor the `git` process arguments, and Git receives the plain repository URL:

   ```bash
   kubectl exec deploy/env-checker -n env-checker -- sh -c '
     GIT_TERMINAL_PROMPT=0 git \
       -c credential.helper='\''!f(){ echo "username=$GIT_USERNAME"; echo "password=$GIT_TOKEN"; }; f'\'' \
       ls-remote "$GIT_REPOSITORY_URL" >/dev/null && echo ok'
   ```

2. Confirm the token is unexpired and has read scope on the repository.

**How to fix:**

1. Put the token in the password position and a valid username in the username position (GitHub accepts any non-empty
   username, for example `x-access-token`; GitLab wants the token owner's username or `oauth2`). Regenerate an expired
   or revoked token with read scope and update the Git Secret. Reapply the release.

**Sources:**

* Source code: `jovyan/utils/integration/git_helper.py:127-157` (`get_auth_string`).
* [remote: HTTP Basic: Access denied — gitlab-org/gitlab-foss #21246](https://gitlab.com/gitlab-org/gitlab-foss/-/issues/21246)

### Git clone hangs or fails: "could not read Username ... No such device or address"

**Symptoms:**

* The clone hangs briefly, then fails — only inside the container, never on a developer laptop:

<!-- markdownlint-disable line-length -->
```text
fatal: could not read Username for 'https://git.example.com': No such device or address
```
<!-- markdownlint-enable line-length -->

**Root cause:**

`authenticate_repo_url` embeds credentials only when both `GIT_USERNAME` and `GIT_TOKEN` are non-empty. When only one is
set — a mistyped Secret key or an empty mounted value — the bare URL reaches `git pull`, Git tries to prompt for the
missing credential, and the container has no terminal to prompt on, so the read fails.

**How to check:**

1. Confirm both variables are present and non-empty:

   ```bash
   kubectl exec deploy/env-checker -n env-checker -- sh -c 'echo "user=[$GIT_USERNAME] token_set=[${GIT_TOKEN:+yes}]"'
   ```

2. Turn the hang into an immediate, loggable failure to confirm the cause:

   ```bash
   kubectl exec deploy/env-checker -n env-checker -- \
     sh -c 'GIT_TERMINAL_PROMPT=0 git ls-remote "$GIT_REPOSITORY_URL"'
   ```

**How to fix:**

1. Set both `GIT_USERNAME` and `GIT_TOKEN` so the credentials are embedded, and reapply the release. Fix the Secret key
   name if one value was mounted empty.

**How to avoid this issue:**

Set `GIT_TERMINAL_PROMPT=0` in the container so a missing credential fails fast instead of hanging until a timeout.

**Sources:**

* Source code: `jovyan/utils/integration/git_helper.py:44-59`, `62-88`.
* [could not read Username ... No such device or address — GitHub community #26580](https://github.com/orgs/community/discussions/26580)

### Git clone fails: repository not found, host unresolved, or certificate not trusted

**Symptoms:**

* One of:

<!-- markdownlint-disable line-length -->
```text
fatal: repository 'https://git.example.com/project/repo.git/' not found
fatal: unable to access 'https://git.example.com/...': Could not resolve host: git.example.com
fatal: unable to access 'https://git.example.com/...': server certificate verification failed. CAfile: none CRLfile: none
```
<!-- markdownlint-enable line-length -->

* The TLS variant appears only against internal or self-hosted Git, and only from the pod.

**Root cause:**

Three distinct failures share this section. `not found` on a private repository usually means no read access rather than
a missing repository, because an unauthenticated request returns 404. `Could not resolve host` means the pod's DNS
cannot resolve the Git host, often an internal-only name or an egress NetworkPolicy. `server certificate verification
failed ... CAfile: none` means the container trusts no CA for a self-hosted server's chain; the current helper does not
disable TLS verification, so it hits this rather than silently ignoring it.

**How to check:**

1. Separate the three with one read-only command and read which error prints:

   ```bash
   kubectl exec deploy/env-checker -n env-checker -- git ls-remote "$GIT_REPOSITORY_URL"
   ```

2. For a TLS error, inspect the presented chain and the trust store:

   ```bash
   kubectl exec deploy/env-checker -n env-checker -- \
     sh -c 'echo | openssl s_client -connect git.example.com:443 -showcerts 2>/dev/null | openssl x509 -noout -issuer'
   ```

3. For a DNS error: `getent hosts git.example.com` from inside the pod.

**How to fix:**

1. For `not found`, verify the exact URL and that the token grants read access — do not trust the anonymous 404.
2. For DNS, correct the hostname, cluster DNS, or egress policy.
3. For TLS, mount the internal root CA into the image and point Git at it:
   `git config --global http.sslCAInfo /path/to/ca.crt`. Prefer trusting the CA to disabling verification.
4. **DANGEROUS — removes transport protection and exposes the token to interception.** Setting
   `git config --global http.sslVerify false` silences the certificate error by turning off verification for every
   host. Use it only as a temporary step on a trusted network, and restore verification afterward; trusting the CA is
   the real fix.

**Sources:**

* Source code: `jovyan/utils/integration/git_helper.py:26-41` (existence check swallows failures), `99-109`.
* [server certificate verification failed. CAfile: none — renovatebot/renovate #25232](https://github.com/renovatebot/renovate/discussions/25232)
* [Troubleshooting SSL — GitLab docs](https://docs.gitlab.com/omnibus/settings/ssl/ssl_troubleshooting/)

### Git fetch leaves the target empty: wrong branch or sparse path

**Symptoms:**

* The clone appears to succeed, but the target directory is empty or the run fails moving files. One of:

```text
fatal: couldn't find remote ref develop
error: pathspec 'notebooks/foo' did not match any file(s) known to git
```

* Or a Python `FileNotFoundError` from `shutil.move`, because the sparse source path never materialized.

**Root cause:**

`git pull origin <branch>` fails with `couldn't find remote ref` when `GIT_BRANCH` does not exist on the remote — often
`main` versus `master`. When `GIT_SPARSE_PATH` does not match a real path on that branch (leading slash, wrong case, or
a file-versus-directory mismatch), the pull can still succeed while checking out nothing under the sparse path; then
`shutil.move` on the missing source path raises.

**How to check:**

1. Confirm the branch exists on the remote. A one-shot credential helper feeds the pod's `GIT_USERNAME` and `GIT_TOKEN`
   to Git, keeping the token out of your shell history and the `git` arguments:

   ```bash
   kubectl exec deploy/env-checker -n env-checker -- sh -c '
     GIT_TERMINAL_PROMPT=0 git \
       -c credential.helper='\''!f(){ echo "username=$GIT_USERNAME"; echo "password=$GIT_TOKEN"; }; f'\'' \
       ls-remote --heads "$GIT_REPOSITORY_URL" "$GIT_BRANCH"'
   ```

2. Confirm the sparse path exists on that branch, with exact case. The pod's working directory is not a Git repository,
   so fetch the branch into a throwaway directory that is removed afterward, then match the path exactly — an exact file
   or a directory prefix, so `notebooks/foo` does not match `notebooks/foobar`:

   ```bash
   kubectl exec deploy/env-checker -n env-checker -- sh -c '
     d=$(mktemp -d); git -C "$d" init -q;
     GIT_TERMINAL_PROMPT=0 git -C "$d" \
       -c credential.helper='\''!f(){ echo "username=$GIT_USERNAME"; echo "password=$GIT_TOKEN"; }; f'\'' \
       fetch -q --depth 1 "$GIT_REPOSITORY_URL" "$GIT_BRANCH" &&
     git -C "$d" ls-tree -r --name-only FETCH_HEAD |
       awk -v p="$GIT_SPARSE_PATH" '\''$0==p || index($0, p"/")==1'\''; rm -rf "$d"'
   ```

**How to fix:**

1. Set `GIT_BRANCH` to a branch that exists (check `main` versus `master`) and `GIT_SPARSE_PATH` to a real
   repository-relative path with no leading slash and exact case. Reapply the release.

**Sources:**

* Source code: `jovyan/utils/integration/git_helper.py:99-124`.
* [Git — sparse-checkout documentation](https://git-scm.com/docs/sparse-checkout)

## UI authentication (oauth2-proxy and Keycloak)

In Non-Production mode the Jupyter UI is reached through an nginx ingress. When OIDC is enabled, a separate oauth2-proxy
Deployment authenticates against Keycloak. When OIDC is disabled, the UI is protected by a token. These cases apply only
to the Non-Production UI path.

### Cannot open the UI: token prompt or 403 without OIDC

**Symptoms:**

* The Jupyter UI shows a token or password prompt, or returns `403 Forbidden`, and no Keycloak login appears.
* This is the expected state when OIDC is not configured.

**Root cause:**

With OIDC disabled, the chart injects `ENVIRONMENT_CHECKER_UI_ACCESS_TOKEN` from the `env-checker-ui-access-token`
Secret. When the value is not set in the Helm values, the chart generates a random 32-character token. Access requires
that token; without it the UI stays locked.

**How to check:**

1. Read the token from the Secret:

   ```bash
   kubectl get secret env-checker-ui-access-token -n env-checker -o jsonpath='{.data.access-token}' | base64 -d; echo
   ```

**How to fix:**

1. Open the UI with the token, for example `http://localhost:8888/?token=<token>` after a
   `kubectl port-forward svc/env-checker 8888:8888 -n env-checker`. To set a known token instead of the generated one,
   set `ENVIRONMENT_CHECKER_UI_ACCESS_TOKEN` in the Helm values and reapply.

**Sources:**

* Source code: `charts/env-checker/templates/UiAccessTokenSecret.yaml:14`,
  `charts/env-checker/templates/_templates.yaml:9-13`, `docs/InstallationGuide.md:127-135`.

### Keycloak login fails: "Invalid parameter: redirect_uri"

**Symptoms:**

* Keycloak shows `Invalid parameter: redirect_uri` after the user is sent to log in.
* Or the browser lands in a redirect loop after a successful Keycloak login, because the callback never validates.

**Root cause:**

Keycloak matches the `redirect_uri` oauth2-proxy sends against the client's Valid Redirect URIs exactly — scheme, host,
port, and trailing slash all count. An ingress that does not forward `X-Forwarded-Proto` makes oauth2-proxy build an
`http://` redirect while Keycloak has `https://` registered, so the exact match fails. A related failure is Keycloak
issuing tokens with `aud: account` rather than the client ID, which oauth2-proxy then rejects.

**How to check:**

1. Read the outbound `redirect_uri` from the oauth2-proxy logs:

   ```bash
   kubectl logs deploy/<oauth2-proxy-deployment> -n env-checker | grep -i redirect
   ```

2. In Keycloak, open the client and compare its Valid Redirect URIs against oauth2-proxy's `--redirect-url`
   (`https://<host>/oauth2/callback`), byte for byte, including any trailing slash.

**How to fix:**

1. Register the exact callback URL in the Keycloak client. Ensure the ingress forwards `X-Forwarded-Proto: https` so
   oauth2-proxy builds an `https` redirect. If tokens carry `aud: account`, add a Keycloak audience mapper that sets the
   client ID, or set oauth2-proxy `--oidc-extra-audience` accordingly. Keep `openid` in the requested scope.

**Sources:**

* Source code: `charts/env-checker/templates/Oauth2.yaml`, `docs/authorization.md`.
* [Redirection error after authenticating with Keycloak — oauth2-proxy #3276](https://github.com/oauth2-proxy/oauth2-proxy/issues/3276)
* [Keycloak OIDC Auth Provider — oauth2-proxy docs](https://oauth2-proxy.github.io/oauth2-proxy/configuration/providers/keycloak_oidc/)

### UI login loops between sign-in and the app

**Symptoms:**

* After a successful Keycloak login the browser bounces back to sign-in, indefinitely.
* oauth2-proxy logs cycle through 401 on `/oauth2/auth`, a 302 to sign-in, `[AuthSuccess]`, a 302 to `/oauth2/callback`,
  and back to 401. It also logs:

<!-- markdownlint-disable line-length -->
```text
Error loading cookied session: cookie "_oauth2_proxy" not present, removing session
```
<!-- markdownlint-enable line-length -->

**Root cause:**

nginx issues an auth subrequest to `/oauth2/auth`; a 401 triggers the redirect to sign-in. The loop happens when the
session cookie oauth2-proxy sets on the callback is never sent back on the protected-path subrequest — usually a scheme
mismatch, because `X-Forwarded-Proto` is not propagated and the cookie is set over `http` while the browser is on
`https`, or a `--cookie-domain` that does not cover the app host.

**How to check:**

1. Confirm the ingress auth annotations use `https` and `$host`:

   ```bash
   kubectl get ingress -n env-checker -o yaml | grep -E "auth-url|auth-signin"
   ```

2. In the browser devtools, check whether `_oauth2_proxy` is stored for the app domain after the callback.

**How to fix:**

1. Propagate `X-Forwarded-Proto` and `X-Forwarded-Host` at the ingress so oauth2-proxy builds `https` redirects and the
   cookie matches the browser scheme. Set `--cookie-domain` to cover both the app and the auth host. Keep the app,
   ingress, and oauth2-proxy on one canonical `https` host.

**Sources:**

* [redirect loop after AuthSuccess — oauth2-proxy #2889](https://github.com/oauth2-proxy/oauth2-proxy/issues/2889)
* [External OAUTH authentication — ingress-nginx docs](https://kubernetes.github.io/ingress-nginx/examples/auth/oauth-external-auth/)

### UI login fails with a CSRF-cookie error over HTTPS

**Symptoms:**

* Login fails after Keycloak with one of:

```text
403 Permission Denied http: named cookie not present
Invalid authentication via OAuth2: unable to obtain CSRF cookie
Login Failed: Unable to find a valid CSRF token. Please try again.
```

* It often works in one browser and fails in another, or fails only when the user arrives from a bookmarked login page.

**Root cause:**

oauth2-proxy sets a short-lived CSRF cookie when it starts the login at `/oauth2/start` and reads it back on
`/oauth2/callback` to match the OAuth `state`. The error means that cookie is absent on the callback. Several conditions
cause it: the login did not start at `/oauth2/start`, so no cookie was ever set — a bookmarked or refreshed Keycloak
login page skips it; the cookie's attributes or scheme keep the browser from returning it; or, when oauth2-proxy runs
more than one replica, the replicas hold different `cookie-secret` values, so the replica handling the callback cannot
read the cookie the other one set. The default cookie session store is stateless and needs no shared backend, only a
matching secret, and the chart runs a single replica by default. The chart's `--cookie-secure=false` is a known-fragile
setting on a public HTTPS ingress, because a cookie without `Secure` cannot be `SameSite=None`, but the symptom alone
does not prove it is the cause here — browser devtools do.

**How to check:**

1. Look for the CSRF error in the oauth2-proxy logs:

   ```bash
   kubectl logs deploy/<oauth2-proxy-deployment> -n env-checker | grep -iE "csrf|named cookie"
   ```

2. In browser devtools, start the login from the application URL rather than a bookmarked Keycloak page, and watch the
   cookies: confirm `_oauth2_proxy_csrf` is set at `/oauth2/start` and returned on `/oauth2/callback`. Note its `Secure`
   and `SameSite` attributes and whether its scheme matches the browser's.
3. If oauth2-proxy runs more than one replica, confirm every replica holds the same `cookie-secret`.

**How to fix:**

1. Start the login from the application URL so oauth2-proxy sets a fresh CSRF cookie. Do not resume from a bookmarked or
   stale Keycloak login page.
2. If devtools show the cookie is set but not returned, align its attributes with the browser scheme: on a public HTTPS
   ingress set `--cookie-secure=true`, which also allows `--cookie-samesite=none` when the callback needs it. Never pair
   `--cookie-secure=false` with a public HTTPS ingress.
3. If oauth2-proxy runs more than one replica, give every replica the same `cookie-secret`. The default cookie store is
   stateless, so a matching secret is enough; a shared session store is needed only when one is deliberately configured.
4. Ensure Keycloak users have an email address. `--insecure-oidc-allow-unverified-email=true` skips verification but
   does not supply a missing email.

**Sources:**

* Source code: `charts/env-checker/templates/Oauth2.yaml` (`--cookie-secure=false`).
* [named cookie not present after authenticated — oauth2-proxy #628](https://github.com/oauth2-proxy/oauth2-proxy/issues/628)
* [CSRF cookie missing when resuming from a bookmarked login page — oauth2-proxy #1736](https://github.com/oauth2-proxy/oauth2-proxy/issues/1736)
* [Session storage (stateless cookie store) — oauth2-proxy docs](https://oauth2-proxy.github.io/oauth2-proxy/configuration/session_storage/)
* [Unable to find a valid CSRF token — oauth2-proxy #2965](https://github.com/oauth2-proxy/oauth2-proxy/issues/2965)

## Notebook execution and reports

### Report shows "Timeout Exception" for a check

**Symptoms:**

* A row in the generated report is rendered in red with the label `Timeout Exception`.
* The affected check produced no result values.

**Root cause:**

The report generator renders the fixed label `Timeout Exception` for any notebook whose run recorded an exception, keyed
off the `isExceptionOccured` flag in the report scrap. The label is hardcoded and does not mean the check timed out.
Any exception in the notebook — an RBAC denial, an unresponsive backend, malformed data, or a bug in the check —
produces the same red `Timeout Exception` text. The real cause is in the failing cell's traceback, not in the label.

**How to check:**

1. Read the executed notebook for the underlying exception rather than the summary row. In the Jupyter UI, open the
   executed copy of the notebook named in the report and read the failing cell's traceback.
2. Confirm cluster access is healthy for the resources that check queries (see
   the "kubectl fails with forbidden ... at the cluster scope" case).

**How to fix:**

1. Resolve the specific exception the traceback names — grant the missing RBAC, fix an unresponsive backend, correct the
   check's input, or narrow its scope if it genuinely timed out. Re-run the check once the cause is addressed.

**Data to collect:**

* The executed notebook file and its failing cell traceback.
* The report name and the timestamp of the run.

**Sources:**

* Source code: `jovyan/utils/report_generator.py:74-75`, `jovyan/utils/custom_reporter.py`.

### Report missing: "Cannot find ... in result.yaml"

**Symptoms:**

* Report assembly or the monitoring push logs one of:

```text
Cannot find /home/jovyan/.../notebook.ipynb in result.yaml
Oops! Cannot get result tag from notebook
An error occured while parsing result.yaml: <error>
```

* The check ran, but its result never reaches the report table or the monitoring metrics.

**Root cause:**

`run.sh` records each executed notebook's metrics into `result.yaml`, and later steps look the notebook up by path to
build the report and push metrics. The lookup fails when the notebook did not write its expected result scrap — usually
because the notebook itself errored before tagging its output — or when `result.yaml` is malformed. The missing entry is
a downstream symptom of a failed notebook run, not an independent fault.

**How to check:**

1. Confirm the notebook produced a result tag. In the executed notebook, verify the reporting cell ran without an
   exception (see the "Report shows Timeout Exception for a check" case).
2. Read `result.yaml` from the pod for the notebook path named in the error:

   ```bash
   kubectl exec deploy/env-checker -n env-checker -- sh -c 'find / -name result.yaml 2>/dev/null'
   ```

**How to fix:**

1. Fix the notebook run that failed to record its result — most often the same cause as the `Timeout Exception` case —
   and re-run it so `result.yaml` gets a complete entry.

**Sources:**

* Source code: `jovyan/utils/nb_data_manipulation_utils.py:189-288`, `jovyan/utils/parseOut.py:14-15`,
  `jovyan/utils/env_checker_utils.py:211-227`.
