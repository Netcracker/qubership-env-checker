#!/usr/bin/env bash
# Renders the chart with every workload enabled and asserts the security context required by the hardening policy.
#
# Usage: charts/env-checker/tests/security_hardening_test.sh

set -euo pipefail

chart_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
rendered_manifest=$(mktemp)
trap 'rm -f "$rendered_manifest"' EXIT

# Deployment, oauth2-proxy Deployment, Job, and CronJob.
expected_workloads=4
# Every env-checker workload mounts /tmp; oauth2-proxy mounts it too.
expected_python_containers=3

case_name=""

fail() {
    echo "FAIL ($case_name): $*" >&2
    exit 1
}

count() {
    grep -cE "$1" "$rendered_manifest" || true
}

assert_count() {
    local pattern=$1 expected=$2 actual
    actual=$(count "$pattern")
    [[ "$actual" -eq "$expected" ]] || fail "expected $expected occurrences of '$pattern', found $actual"
}

# render <case name> [extra helm --set arguments...]
render() {
    case_name=$1
    shift
    helm template env-checker "$chart_dir" \
        --set ENVIRONMENT_CHECKER_JOB_COMMAND=true \
        --set ENVIRONMENT_CHECKER_CRON_JOB_COMMAND=true \
        --set ENVIRONMENT_CHECKER_CRON_SCHEDULE='0 * * * *' \
        --set OPS_IDP_URL=https://idp.example.com \
        "$@" \
        >"$rendered_manifest"
}

assert_common() {
    assert_count 'readOnlyRootFilesystem: true' "$expected_workloads"
    assert_count 'runAsNonRoot: true' "$expected_workloads"
    assert_count 'allowPrivilegeEscalation: false' "$expected_workloads"
    assert_count 'type: RuntimeDefault' "$expected_workloads"
    assert_count 'drop: \["ALL"\]' "$expected_workloads"

    # One tmp volume and one tmp volume mount per workload.
    assert_count 'name: tmp' $((expected_workloads * 2))
    assert_count 'mountPath: /tmp' "$expected_workloads"
    assert_count 'name: "PYTHONDONTWRITEBYTECODE"' "$expected_python_containers"

    if grep -Eq 'hostNetwork: true|hostPID: true|hostIPC: true|hostPath:' "$rendered_manifest"; then
        fail "rendered manifests contain a forbidden host setting"
    fi

    # Ports 17-995, 1080, 1236, 1433-1434, 1494, 1512, 1524-1525, 1645-1646, 1649, 1758-1759, 1789, 1812, 1911, 26000.
    if grep 'containerPort' "$rendered_manifest" |
        grep -E '[^0-9](1[7-9]|[2-9][0-9]|[1-9][0-9]{2}|99[0-5]|1080|1236|143[34]|1494|1512|152[45]|164[56]|1649|175[89]|1789|1812|1911|26000)$'; then
        fail "rendered manifests contain a forbidden container port"
    fi
}

render "non-production on KUBERNETES" --set PAAS_PLATFORM=KUBERNETES
assert_common
# The platform branch pins the image's jovyan user.
assert_count 'runAsUser: 1000$' "$expected_workloads"
assert_count 'runAsGroup: 1000$' "$expected_workloads"

render "non-production on OPENSHIFT" --set PAAS_PLATFORM=OPENSHIFT
assert_common
# No UID is requested, so the security context constraints assign one from the namespace range.
assert_count 'runAsUser' 0
assert_count 'runAsGroup' 0

# Non-production may opt out of the read-only root filesystem for the env-checker containers; oauth2-proxy stays
# read-only.
render "non-production with a writable root filesystem" --set READONLY_CONTAINER_FILE_SYSTEM_ENABLED=false
assert_count 'readOnlyRootFilesystem: false' "$expected_python_containers"
assert_count 'readOnlyRootFilesystem: true' 1

# Production ignores the flag. Only Deployment, Job, and CronJob render in production.
render "production with the flag set to false" --set PRODUCTION_MODE=true --set READONLY_CONTAINER_FILE_SYSTEM_ENABLED=false
assert_count 'readOnlyRootFilesystem: true' "$expected_python_containers"
assert_count 'readOnlyRootFilesystem: false' 0

echo "Security hardening checks passed."
