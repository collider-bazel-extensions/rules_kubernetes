#!/usr/bin/env bash
# server_manifest_test.sh
#
# Verifies that kubernetes_server applies kubernetes_manifest files before
# writing its readiness env file.
#
# The kubernetes_server target uses ":test_manifests" which applies
# tests/manifests/test_clusterrole.yaml — a ClusterRole named
# "rules-k8s-test-reader".  This test confirms the ClusterRole exists
# in the cluster after the server is ready.
#
# $1: rootpath of the kubernetes_server binary (relative to TEST_SRCDIR/TEST_WORKSPACE)

set -euo pipefail

SERVER_BIN="$TEST_SRCDIR/$TEST_WORKSPACE/$1"
ENV_FILE="$TEST_TMPDIR/k8s_server_manifest_svc.env"
SERVER_PID=""

cleanup() {
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "--- server_manifest_test ---"

# Start the server in the background.
"$SERVER_BIN" &
SERVER_PID=$!

# Wait up to 60 s for the env file to appear.
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

# shellcheck disable=SC1090
source "$ENV_FILE"

for var in KUBECONFIG KUBE_NAMESPACE KUBE_API_SERVER KUBECTL; do
    if [[ -z "${!var:-}" ]]; then
        echo "FAIL: $var is missing from env file" >&2
        exit 1
    fi
    echo "OK: $var=${!var}"
done

# -------------------------------------------------------------------------
# Verify the ClusterRole was applied by kubernetes_manifest.
# -------------------------------------------------------------------------

echo ""
echo "Checking that ClusterRole rules-k8s-test-reader exists..."
"$KUBECTL" get clusterrole rules-k8s-test-reader \
    --kubeconfig "$KUBECONFIG" >/dev/null
echo "OK: ClusterRole rules-k8s-test-reader exists"

# Send SIGTERM and verify clean exit.
kill -TERM "$SERVER_PID"
set +e
wait "$SERVER_PID"
EXIT_CODE=$?
set -e
SERVER_PID=""

if [[ "$EXIT_CODE" != "0" ]]; then
    echo "FAIL: kubernetes_server exited with code $EXIT_CODE after SIGTERM (expected 0)" >&2
    exit 1
fi
echo "OK: kubernetes_server exited cleanly after SIGTERM"

echo ""
echo "--- PASS ---"
