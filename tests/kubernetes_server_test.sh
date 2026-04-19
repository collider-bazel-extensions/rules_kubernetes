#!/usr/bin/env bash
# kubernetes_server_test.sh
#
# Verifies kubernetes_server lifecycle:
#   - starts the server and writes the env file
#   - env file contains KUBECONFIG, KUBE_NAMESPACE, KUBE_API_SERVER
#   - KUBECONFIG is a valid kubeconfig (kubectl cluster-info succeeds)
#   - SIGTERM causes a clean (exit 0) shutdown
#
# $1: rootpath of the kubernetes_server binary (relative to TEST_SRCDIR/TEST_WORKSPACE)

set -euo pipefail

SERVER_BIN="$TEST_SRCDIR/$TEST_WORKSPACE/$1"
ENV_FILE="$TEST_TMPDIR/k8s_server_test_svc.env"
SERVER_PID=""

cleanup() {
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "--- kubernetes_server_test ---"

# Start the server in the background.
"$SERVER_BIN" &
SERVER_PID=$!

# Wait up to 60 s for the env file to appear.
# kube-apiserver startup (including TLS bootstrap) takes ~5–10 s.
echo "Waiting for env file: $ENV_FILE"
for i in $(seq 1 300); do
    [[ -f "$ENV_FILE" ]] && break
    sleep 0.2
done

if [[ ! -f "$ENV_FILE" ]]; then
    echo "FAIL: env file never appeared after 60 s" >&2
    exit 1
fi
echo "OK: env file appeared"

# Verify all required variables are present.
# shellcheck disable=SC1090
source "$ENV_FILE"

for var in KUBECONFIG KUBE_NAMESPACE KUBE_API_SERVER; do
    if [[ -z "${!var:-}" ]]; then
        echo "FAIL: $var is missing from env file" >&2
        exit 1
    fi
    echo "OK: $var=${!var}"
done

# Verify the kubeconfig works.
if [[ -n "${KUBECTL:-}" ]]; then
    "$KUBECTL" cluster-info --kubeconfig "$KUBECONFIG" >/dev/null
    echo "OK: kubectl cluster-info succeeded"
else
    echo "SKIP: KUBECTL not set in env file"
fi

# Send SIGTERM and verify clean exit.
kill -TERM "$SERVER_PID"
set +e
wait "$SERVER_PID"
EXIT_CODE=$?
set -e
SERVER_PID=""  # prevent double-kill in trap

if [[ "$EXIT_CODE" != "0" ]]; then
    echo "FAIL: kubernetes_server exited with code $EXIT_CODE after SIGTERM (expected 0)" >&2
    exit 1
fi
echo "OK: kubernetes_server exited cleanly (exit 0) after SIGTERM"

echo ""
echo "--- PASS ---"
