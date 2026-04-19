#!/usr/bin/env bash
# controller_manifest_test.sh
#
# Verifies that a kubernetes_controller with attached kubernetes_manifest
# files has both its manifests applied and its controller running before
# the test binary executes.
#
# The kubernetes_test target wrapping this script uses:
#   controller = ":echo_controller_with_manifest"
# which declares:
#   manifests = ":test_manifests"   → applies test_clusterrole.yaml
#   ready_probe = "env_file"        → controller writes RULES_K8S_READY_FILE
#
# This test confirms:
#   1. The ClusterRole from the controller's manifest exists.
#   2. The echo controller is running (mirrors a labelled ConfigMap).

set -euo pipefail

require_env() {
    local var="$1"
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: required environment variable \$$var is not set" >&2
        exit 1
    fi
}

require_env KUBECONFIG
require_env KUBE_NAMESPACE
require_env KUBE_API_SERVER
require_env KUBECTL

echo "--- controller_manifest_test ---"
echo "API server: $KUBE_API_SERVER"
echo "Namespace:  $KUBE_NAMESPACE"

# -------------------------------------------------------------------------
# 1. Verify the manifest was applied (ClusterRole from controller's manifests).
# -------------------------------------------------------------------------

echo ""
echo "Checking that ClusterRole rules-k8s-test-reader exists..."
"$KUBECTL" get clusterrole rules-k8s-test-reader \
    --kubeconfig "$KUBECONFIG" >/dev/null
echo "OK: ClusterRole rules-k8s-test-reader exists"

# -------------------------------------------------------------------------
# 2. Verify the echo controller is running by triggering a reconcile.
# -------------------------------------------------------------------------

CM_NAME="echo-input-manifest-$$"
ECHO_NAME="${CM_NAME}-echo"

echo ""
echo "Creating input ConfigMap $CM_NAME..."
"$KUBECTL" create configmap "$CM_NAME" \
    --namespace "$KUBE_NAMESPACE" \
    --kubeconfig "$KUBECONFIG" \
    --from-literal=payload="controller+manifest composition"

"$KUBECTL" label configmap "$CM_NAME" \
    --namespace "$KUBE_NAMESPACE" \
    --kubeconfig "$KUBECONFIG" \
    echo-input=true
echo "OK: input ConfigMap created and labelled"

echo "Waiting for echo ConfigMap $ECHO_NAME..."
for i in $(seq 1 40); do
    if "$KUBECTL" get configmap "$ECHO_NAME" \
        --namespace "$KUBE_NAMESPACE" \
        --kubeconfig "$KUBECONFIG" \
        --ignore-not-found 2>/dev/null | grep -q "$ECHO_NAME"; then
        break
    fi
    sleep 0.5
done

"$KUBECTL" get configmap "$ECHO_NAME" \
    --namespace "$KUBE_NAMESPACE" \
    --kubeconfig "$KUBECONFIG" >/dev/null
echo "OK: echo ConfigMap appeared"

VAL=$("$KUBECTL" get configmap "$ECHO_NAME" \
    --namespace "$KUBE_NAMESPACE" \
    --kubeconfig "$KUBECONFIG" \
    -o jsonpath='{.data.payload}')

if [[ "$VAL" == "controller+manifest composition" ]]; then
    echo "OK: echo ConfigMap contains correct data"
else
    echo "FAIL: expected 'controller+manifest composition', got '$VAL'" >&2
    exit 1
fi

echo ""
echo "--- PASS ---"
