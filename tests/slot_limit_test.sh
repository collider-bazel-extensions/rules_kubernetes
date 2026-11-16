#!/usr/bin/env bash
# slot_limit_test.sh <rootpath of a kubernetes_server> <its target name>
#
# RULES_K8S_MAX_SERVERS=1 (#5): two kubernetes_server launchers in separate
# processes (each with its own TEST_TMPDIR, as two Bazel servers would have)
# share one slot directory. The second waits, naming the first, and starts
# its etcd + kube-apiserver only after the first has shut down.

set -euo pipefail

SERVER_BIN="$TEST_SRCDIR/$TEST_WORKSPACE/$1"
NAME="$2"
export RULES_K8S_MAX_SERVERS=1
export RULES_K8S_SLOT_DIR="$TEST_TMPDIR/slots"
# The waiter's readiness budgets must not include its wait for the slot.
export RULES_K8S_ETCD_READY_TIMEOUT=60
export RULES_K8S_APISERVER_READY_TIMEOUT=120

PIDS=()
cleanup() {
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT

start() { # start <dir>: one launcher with TEST_TMPDIR=<dir>, log in <dir>.log
    mkdir -p "$TEST_TMPDIR/$1"
    TEST_TMPDIR="$TEST_TMPDIR/$1" TEST_TARGET="//slot/$1" "$SERVER_BIN" > "$TEST_TMPDIR/$1.log" 2>&1 &
    PIDS+=($!)
}
wait_for() { # wait_for <file> <seconds>
    for _ in $(seq "$(( $2 * 5 ))"); do [[ -f "$1" ]] && return 0; sleep 0.2; done
    return 1
}

start a
A_PID="${PIDS[0]}"
wait_for "$TEST_TMPDIR/a/$NAME.env" 120 || { cat "$TEST_TMPDIR/a.log" >&2; echo "FAIL: first server not ready" >&2; exit 1; }
grep -q "server slot 1/1 acquired" "$TEST_TMPDIR/a.log" || { echo "FAIL: first server took no slot" >&2; exit 1; }
echo "OK: first server ready"

start b
for _ in $(seq 50); do grep -q "waiting for a server slot" "$TEST_TMPDIR/b.log" && break; sleep 0.2; done
sleep 3
if [[ -f "$TEST_TMPDIR/b/$NAME.env" ]] || grep -q "starting etcd" "$TEST_TMPDIR/b.log"; then
    cat "$TEST_TMPDIR/b.log" >&2
    echo "FAIL: second server started while the first held the only slot" >&2
    exit 1
fi
grep -q "waiting for a server slot (RULES_K8S_MAX_SERVERS=1); held by: pid $A_PID target //slot/a" "$TEST_TMPDIR/b.log" \
    || { cat "$TEST_TMPDIR/b.log" >&2; echo "FAIL: waiting message does not name the first server" >&2; exit 1; }
echo "OK: second server waits for the first"

kill -TERM "$A_PID"
wait "$A_PID"
# The launcher stops its etcd and kube-apiserver before it exits, so they
# neither linger nor keep the slot.
for f in /proc/[0-9]*/cmdline; do
    args="$(tr '\0' '\n' < "$f" 2>/dev/null)" || continue
    if grep -q "^$TEST_TMPDIR/a/" <<<"$args"; then
        echo "FAIL: first server's process outlived its launcher: ${args//$'\n'/ }" >&2
        exit 1
    fi
done
echo "OK: first server shut down, its etcd and kube-apiserver with it"

wait_for "$TEST_TMPDIR/b/$NAME.env" 120 || { cat "$TEST_TMPDIR/b.log" >&2; echo "FAIL: second server not ready after the first shut down" >&2; exit 1; }
grep -q "server slot 1/1 acquired" "$TEST_TMPDIR/b.log" || { echo "FAIL: second server took no slot" >&2; exit 1; }
source "$TEST_TMPDIR/b/$NAME.env"
"$KUBECTL" --kubeconfig "$KUBECONFIG" get namespace "$KUBE_NAMESPACE" >/dev/null
echo "OK: second server ready once the slot was free"

echo "PASS"
