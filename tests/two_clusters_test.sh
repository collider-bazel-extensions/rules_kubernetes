#!/usr/bin/env bash
# two_clusters_test.sh <server A> <server B> <server C>
#
# Two kubernetes_server targets in one test (rules_kind#25): each gets its own
# kubeconfig ($TEST_TMPDIR/<name>.kubeconfig) and state, and each env file
# reaches its own API server. A third target with A's name (in another
# package) fails at once, naming both labels, and A keeps serving.
#
# $1-$3: rootpaths of //tests:two_a_svc, //tests:two_b_svc and
# //tests/samename:two_a_svc.

set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
PIDS=()
cleanup() {
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null || true; done
}
trap cleanup EXIT

bin() { echo "$TEST_SRCDIR/$TEST_WORKSPACE/$1"; }
"$(bin "$1")" > "$TEST_TMPDIR/a.log" 2>&1 & PIDS+=($!)
"$(bin "$2")" > "$TEST_TMPDIR/b.log" 2>&1 & PIDS+=($!)

for name in two_a_svc two_b_svc; do
    for _ in $(seq 1 1200); do [[ -f "$TEST_TMPDIR/$name.env" ]] && break; sleep 0.2; done
    [[ -f "$TEST_TMPDIR/$name.env" ]] || { cat "$TEST_TMPDIR"/[ab].log >&2; fail "$name.env never appeared"; }
done
echo "OK: both env files written"

envvar() { (set -a; source "$TEST_TMPDIR/$1.env"; echo "${!2}"); }
KA="$(envvar two_a_svc KUBECONFIG)";      KB="$(envvar two_b_svc KUBECONFIG)"
SA="$(envvar two_a_svc KUBE_API_SERVER)"; SB="$(envvar two_b_svc KUBE_API_SERVER)"
KUBECTL="$(envvar two_a_svc KUBECTL)"

[[ "$KA" == "$TEST_TMPDIR/two_a_svc.kubeconfig" ]] || fail "A's KUBECONFIG is $KA"
[[ "$KB" == "$TEST_TMPDIR/two_b_svc.kubeconfig" ]] || fail "B's KUBECONFIG is $KB"
[[ -f "$KA" && -f "$KB" ]] || fail "a kubeconfig is missing"
[[ "$SA" != "$SB" ]] || fail "both env files name the API server $SA"
echo "OK: separate kubeconfigs and API servers ($SA, $SB)"

server_of() { "$KUBECTL" --kubeconfig "$1" config view --minify -o jsonpath='{.clusters[0].cluster.server}'; }
[[ "$(server_of "$KA")" == "$SA" ]] || fail "A's kubeconfig points at $(server_of "$KA"), not $SA"
[[ "$(server_of "$KB")" == "$SB" ]] || fail "B's kubeconfig points at $(server_of "$KB"), not $SB"
echo "OK: each kubeconfig points at its own API server"

"$KUBECTL" --kubeconfig "$KA" create namespace only-in-a >/dev/null
"$KUBECTL" --kubeconfig "$KA" get namespace only-in-a >/dev/null || fail "A can't see its namespace"
if "$KUBECTL" --kubeconfig "$KB" get namespace only-in-a >/dev/null 2>&1; then
    fail "a namespace created through A's kubeconfig is visible through B's"
fi
echo "OK: the clusters are separate"

# Same name as A, another package: refused before it starts anything.
set +e
out="$(timeout 60 "$(bin "$3")" 2>&1)"
rc=$?
set -e
[[ $rc == 1 ]] || fail "//tests/samename:two_a_svc: exit $rc, want 1: $out"
grep -qF "kubernetes_server //tests/samename:two_a_svc: \$TEST_TMPDIR/two_a_svc.env and two_a_svc.kubeconfig are already used by //tests:two_a_svc (pid ${PIDS[0]}) in this test" <<<"$out" \
    || fail "the clash message does not name both targets: $out"
"$KUBECTL" --kubeconfig "$KA" get namespace only-in-a >/dev/null || fail "A stopped serving after the clash"
[[ "$(envvar two_a_svc KUBE_API_SERVER)" == "$SA" ]] || fail "A's env file was rewritten"
echo "OK: a second target named two_a_svc is refused, naming both"

echo "--- PASS ---"
