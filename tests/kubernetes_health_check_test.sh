#!/usr/bin/env bash
# kubernetes_health_check_test.sh
#
# Verifies kubernetes_health_check behaviour without starting a real server:
#   - exits non-zero when the env file is absent
#   - exits 0 when the env file is present
#
# $1: rootpath of the kubernetes_health_check binary

set -euo pipefail

HEALTH_CHECK="$TEST_SRCDIR/$TEST_WORKSPACE/$1"
ENV_FILE="$TEST_TMPDIR/k8s_server_test_svc.env"

echo "--- kubernetes_health_check_test ---"

# Env file absent — must exit non-zero.
if "$HEALTH_CHECK" 2>/dev/null; then
    echo "FAIL: health check should have exited non-zero when env file is absent" >&2
    exit 1
fi
echo "OK: health check exited non-zero when env file is absent"

# Create a minimal env file to simulate a ready server.
cat > "$ENV_FILE" <<'EOF'
KUBECONFIG=/tmp/fake_kubeconfig
KUBE_NAMESPACE=k8s-test-000000000000
KUBE_API_SERVER=https://127.0.0.1:12345
EOF

# Env file present — must exit 0.
if ! "$HEALTH_CHECK" 2>/dev/null; then
    echo "FAIL: health check should have exited 0 when env file is present" >&2
    exit 1
fi
echo "OK: health check exited 0 when env file is present"

echo ""
echo "--- PASS ---"
