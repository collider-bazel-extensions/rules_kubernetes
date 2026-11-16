#!/usr/bin/env bash
# manifest_test.sh
#
# Verifies that kubernetes_manifest files are applied to the cluster before
# the test binary runs.
#
# The kubernetes_test target that wraps this script is configured with:
#   manifests = ":test_manifests"
# which applies tests/manifests/test_clusterrole.yaml — a ClusterRole named
# "rules-k8s-test-reader" — and tests/manifests/test_crd.yaml, a CRD the
# launcher waits to be Established before the test starts (#5).

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

echo "--- manifest_test ---"
echo "API server: $KUBE_API_SERVER"
echo "Namespace:  $KUBE_NAMESPACE"

# -------------------------------------------------------------------------
# Verify the ClusterRole was applied by kubernetes_manifest.
# -------------------------------------------------------------------------

echo ""
echo "Checking that ClusterRole rules-k8s-test-reader exists..."
"$KUBECTL" get clusterrole rules-k8s-test-reader \
    --kubeconfig "$KUBECONFIG" >/dev/null
echo "OK: ClusterRole rules-k8s-test-reader exists"

# Verify the ClusterRole has the expected rules.
RESOURCES=$("$KUBECTL" get clusterrole rules-k8s-test-reader \
    --kubeconfig "$KUBECONFIG" \
    -o jsonpath='{.rules[0].resources[*]}')

if echo "$RESOURCES" | grep -q "configmaps"; then
    echo "OK: ClusterRole contains expected rules"
else
    echo "FAIL: ClusterRole rules do not contain 'configmaps': $RESOURCES" >&2
    exit 1
fi

echo ""
echo "--- PASS ---"

# -------------------------------------------------------------------------
# The CRD is Established before the test starts (#5): no retry loop needed.
# -------------------------------------------------------------------------

echo ""
echo "Checking that CRD widgets.rules-k8s.test is Established..."
established="$("$KUBECTL" get crd widgets.rules-k8s.test --kubeconfig "$KUBECONFIG" \
    -o 'jsonpath={.status.conditions[?(@.type=="Established")].status}')"
[[ "$established" == "True" ]] || { echo "FAIL: CRD not Established at test start ($established)" >&2; exit 1; }
cat <<YAML | "$KUBECTL" apply --kubeconfig "$KUBECONFIG" -n "$KUBE_NAMESPACE" -f - >/dev/null
apiVersion: rules-k8s.test/v1
kind: Widget
metadata:
  name: first
spec:
  size: 3
YAML
"$KUBECTL" get widget first --kubeconfig "$KUBECONFIG" -n "$KUBE_NAMESPACE" >/dev/null
echo "OK: CRD Established; a Widget was created without retrying"
