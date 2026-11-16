#!/usr/bin/env bash
# etcd_flags_test.sh <yes|no>
#
# Runs inside kubernetes_test: finds this test's etcd (its --data-dir is
# $TEST_TMPDIR/etcd_data) and checks whether --unsafe-no-fsync is on its
# command line (#5), then writes through the API server.

set -euo pipefail

require_env() { [[ -n "${!1:-}" ]] || { echo "FAIL: \$$1 is not set" >&2; exit 1; }; }
require_env KUBECONFIG
require_env KUBE_NAMESPACE
require_env KUBECTL
require_env TEST_TMPDIR

want="$1"
data_dir="$TEST_TMPDIR/etcd_data"
cmdline=""
for f in /proc/[0-9]*/cmdline; do
    args="$(tr '\0' '\n' < "$f" 2>/dev/null)" || continue
    if grep -qx -- "--data-dir" <<<"$args" && grep -qxF -- "$data_dir" <<<"$args"; then
        cmdline="$args"
        break
    fi
done
[[ -n "$cmdline" ]] || { echo "FAIL: no etcd with --data-dir $data_dir" >&2; exit 1; }
echo "etcd command line:"; sed 's/^/  /' <<<"$cmdline"

if grep -qx -- "--unsafe-no-fsync" <<<"$cmdline"; then got=yes; else got=no; fi
if [[ "$got" != "$want" ]]; then
    echo "FAIL: --unsafe-no-fsync on etcd's command line: $got, want $want" >&2
    exit 1
fi
echo "OK: --unsafe-no-fsync: $got"

"$KUBECTL" --kubeconfig "$KUBECONFIG" -n "$KUBE_NAMESPACE" \
    create configmap fsync-probe --from-literal=k=v >/dev/null
"$KUBECTL" --kubeconfig "$KUBECONFIG" -n "$KUBE_NAMESPACE" \
    get configmap fsync-probe -o jsonpath='{.data.k}' | grep -qx v
echo "OK"
