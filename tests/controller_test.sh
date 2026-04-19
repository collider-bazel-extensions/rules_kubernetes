#!/usr/bin/env bash
# controller_test.sh
#
# Verifies the echo_controller end-to-end:
#   1. Creates a ConfigMap labelled echo-input=true.
#   2. Waits for the controller to create the mirrored <name>-echo ConfigMap.
#   3. Verifies the mirrored ConfigMap has the same data.
#
# The kubernetes_test target wrapping this script is configured with:
#   controller = ":echo_controller"
# which runs tests/controllers/echo_controller/main.py via ready_probe=env_file.

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

echo "--- controller_test ---"
echo "API server: $KUBE_API_SERVER"
echo "Namespace:  $KUBE_NAMESPACE"

CM_NAME="echo-input-$$"
ECHO_NAME="${CM_NAME}-echo"

# -------------------------------------------------------------------------
# 1. Create the input ConfigMap with the echo-input=true label.
# -------------------------------------------------------------------------

echo ""
echo "Creating input ConfigMap $CM_NAME..."
"$KUBECTL" create configmap "$CM_NAME" \
    --namespace "$KUBE_NAMESPACE" \
    --kubeconfig "$KUBECONFIG" \
    --from-literal=message="hello from rules_kubernetes"

"$KUBECTL" label configmap "$CM_NAME" \
    --namespace "$KUBE_NAMESPACE" \
    --kubeconfig "$KUBECONFIG" \
    echo-input=true
echo "OK: input ConfigMap created and labelled"

# -------------------------------------------------------------------------
# 2. Wait for the echo controller to create the mirrored ConfigMap.
# -------------------------------------------------------------------------

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

# Fail if it never appeared.
"$KUBECTL" get configmap "$ECHO_NAME" \
    --namespace "$KUBE_NAMESPACE" \
    --kubeconfig "$KUBECONFIG" >/dev/null
echo "OK: echo ConfigMap appeared"

# -------------------------------------------------------------------------
# 3. Verify the mirrored data matches.
# -------------------------------------------------------------------------

MSG=$("$KUBECTL" get configmap "$ECHO_NAME" \
    --namespace "$KUBE_NAMESPACE" \
    --kubeconfig "$KUBECONFIG" \
    -o jsonpath='{.data.message}')

if [[ "$MSG" == "hello from rules_kubernetes" ]]; then
    echo "OK: echo ConfigMap contains correct data"
else
    echo "FAIL: expected 'hello from rules_kubernetes', got '$MSG'" >&2
    exit 1
fi

echo ""
echo "--- PASS ---"
