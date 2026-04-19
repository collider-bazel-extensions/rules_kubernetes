#!/usr/bin/env bash
# apiserver_smoke_test.sh
#
# Verifies basic Kubernetes API server connectivity:
#   - KUBECONFIG, KUBE_NAMESPACE, KUBE_API_SERVER are set and non-empty
#   - kubectl cluster-info succeeds
#   - Can create, get, and delete a ConfigMap in the isolated test namespace
#   - The namespace name is unique (UUID-based)

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

echo "--- apiserver_smoke_test ---"
echo "API server: $KUBE_API_SERVER"
echo "Namespace:  $KUBE_NAMESPACE"
echo "KUBECONFIG: $KUBECONFIG"

require_env KUBECTL

# -------------------------------------------------------------------------
# 1. Cluster connectivity
# -------------------------------------------------------------------------

echo ""
echo "Checking cluster connectivity..."
"$KUBECTL" cluster-info --kubeconfig "$KUBECONFIG" >/dev/null
echo "OK: cluster-info succeeded"

# -------------------------------------------------------------------------
# 2. Namespace isolation — name must match UUID pattern
# -------------------------------------------------------------------------

if [[ "$KUBE_NAMESPACE" =~ ^k8s-test-[0-9a-f]{12}$ ]]; then
    echo "OK: namespace matches UUID pattern: $KUBE_NAMESPACE"
else
    echo "FAIL: namespace does not match expected pattern 'k8s-test-<12hex>': $KUBE_NAMESPACE" >&2
    exit 1
fi

# Verify the namespace actually exists in the cluster.
"$KUBECTL" get namespace "$KUBE_NAMESPACE" --kubeconfig "$KUBECONFIG" >/dev/null
echo "OK: namespace exists in cluster"

# -------------------------------------------------------------------------
# 3. ConfigMap CRUD round-trip
# -------------------------------------------------------------------------

CM_NAME="smoke-test-$$"

echo ""
echo "Creating ConfigMap $CM_NAME..."
"$KUBECTL" create configmap "$CM_NAME" \
    --namespace "$KUBE_NAMESPACE" \
    --kubeconfig "$KUBECONFIG" \
    --from-literal=key=value

echo "Getting ConfigMap $CM_NAME..."
VAL=$("$KUBECTL" get configmap "$CM_NAME" \
    --namespace "$KUBE_NAMESPACE" \
    --kubeconfig "$KUBECONFIG" \
    -o jsonpath='{.data.key}')

if [[ "$VAL" == "value" ]]; then
    echo "OK: ConfigMap data round-tripped correctly"
else
    echo "FAIL: expected 'value', got '$VAL'" >&2
    exit 1
fi

echo "Deleting ConfigMap $CM_NAME..."
"$KUBECTL" delete configmap "$CM_NAME" \
    --namespace "$KUBE_NAMESPACE" \
    --kubeconfig "$KUBECONFIG" >/dev/null
echo "OK: ConfigMap deleted"

echo ""
echo "--- PASS ---"
