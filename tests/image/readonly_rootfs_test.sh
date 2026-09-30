#!/usr/bin/env bash
# Runs the env-checker image the way the Helm chart runs it: read-only root filesystem, dropped capabilities,
# root-owned emptyDir volumes, and both UID strategies of the chart. On KUBERNETES the chart requests UID/GID 1000;
# on any other platform it requests none, so 10001:0 stands for a UID assigned by OpenShift security context
# constraints.
#
# Usage: tests/image/readonly_rootfs_test.sh <image>

set -euo pipefail

image=${1:?usage: $0 <image>}
api_timeout_seconds=${API_TIMEOUT_SECONDS:-180}
users=("1000:1000" "10001:0")

# Kubernetes creates an emptyDir as root:root 0777; tmpfs with mode=0777 and no uid/gid option reproduces that.
readonly_flags=(
    --read-only
    --tmpfs "/tmp:size=100m,mode=1777"
    --tmpfs "/home/jovyan:size=512m,mode=0777,exec"
    --tmpfs "/home/jovyan/out:size=100m,mode=0777"
    --cap-drop ALL
    --security-opt no-new-privileges
    -e PYTHONDONTWRITEBYTECODE=1
    -e ENVIRONMENT_CHECKER_UI_ACCESS_TOKEN=test-token
)

containers=()
cleanup() {
    if [[ ${#containers[@]} -gt 0 ]]; then
        docker rm -f "${containers[@]}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

echo "## Image runs as a non-root user by default"
default_uid=$(docker run --rm --entrypoint id "$image" -u)
[[ "$default_uid" -ge 1000 ]] || fail "default UID is $default_uid, expected >= 1000"

echo "## home-template matches the baked /home/jovyan (the template layer must stay last in the Dockerfile)"
baked=$(docker run --rm --entrypoint ls "$image" -A /home/jovyan)
template=$(docker run --rm --entrypoint ls "$image" -A /opt/env-checker/home-template)
[[ "$baked" == "$template" ]] || fail "home-template differs from /home/jovyan:
$(diff <(echo "$baked") <(echo "$template") || true)"

echo "## home-template is readable by an arbitrary UID with GID 0"
docker run --rm --user 10001:0 --entrypoint ls "$image" /opt/env-checker/home-template >/dev/null ||
    fail "UID 10001 with GID 0 cannot read /opt/env-checker/home-template"

for user in "${users[@]}"; do
    echo "## Deployment path as $user: start.sh populates the home volume and JupyterLab answers on /api"
    name="ec-ro-deploy-${user%%:*}"
    containers+=("$name")
    docker run -d --name "$name" --user "$user" "${readonly_flags[@]}" "$image" >/dev/null
    deadline=$((SECONDS + api_timeout_seconds))
    until docker exec "$name" python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8888/api")' \
        >/dev/null 2>&1; do
        if [[ "$(docker inspect -f '{{.State.Status}}' "$name")" != "running" ]]; then
            docker logs "$name" >&2 || true
            fail "container exited before JupyterLab started (user $user)"
        fi
        if ((SECONDS >= deadline)); then
            docker logs "$name" >&2 || true
            fail "JupyterLab did not answer on /api within ${api_timeout_seconds}s (user $user)"
        fi
        sleep 5
    done
    docker exec "$name" test -x /home/jovyan/run.sh || fail "/home/jovyan/run.sh missing after start (user $user)"
    if docker logs "$name" 2>&1 | grep -Eiq "read-only file system|permission denied"; then
        docker logs "$name" >&2 || true
        fail "filesystem errors in the container log (user $user)"
    fi
    docker rm -f "$name" >/dev/null

    echo "## Job path as $user: the chart command runs run.sh through tini and start.sh"
    if ! job_output=$(docker run --rm --user "$user" "${readonly_flags[@]}" -w /home/jovyan --entrypoint tini "$image" \
        -g -- /usr/local/bin/start.sh /bin/sh -c \
        './run.sh tests/notebooks/test_notebook.ipynb && test -f /home/jovyan/out/result.yaml' 2>&1); then
        echo "$job_output" >&2
        fail "run.sh did not complete under a read-only root filesystem (user $user)"
    fi
done

echo "Read-only root filesystem checks passed."
