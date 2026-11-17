#!/usr/bin/env bash
set -euo pipefail

# Launcher pieces that need no kube-apiserver (#5):
#   - RULES_K8S_ETCD_READY_TIMEOUT / RULES_K8S_APISERVER_READY_TIMEOUT: defaults,
#     valid values, invalid values fail before anything starts; the etcd
#     budget is the one _start_etcd waits for.
#   - --unsafe-no-fsync reaches etcd's command line by default, not with
#     RULES_K8S_ETCD_UNSAFE_NO_FSYNC=0, and not for an etcd without the flag.
#   - RULES_K8S_MAX_SERVERS slots: a second launcher process waits, names the
#     holder, and gets the slot once the holder (and everything that
#     inherited the slot, across execve) is gone; 0 = no limit.
#   - Name claims (rules_kind#25): a second launcher for the same target name
#     in one test fails at once, naming both labels, before it writes
#     anything; a claim whose launcher has exited is taken over.

[[ -n "${TEST_TMPDIR:-}" ]] || { echo "ERROR: \$TEST_TMPDIR not set" >&2; exit 1; }
RUNFILES="${TEST_SRCDIR:-${RUNFILES_DIR:-${BASH_SOURCE[0]}.runfiles}}"
launcher_dir=""
for candidate in "${RUNFILES}/_main/private" "${RUNFILES}/rules_kubernetes/private"; do
    [[ -f "$candidate/launcher.py" ]] && { launcher_dir="$candidate"; break; }
done
[[ -n "$launcher_dir" ]] || { echo "ERROR: launcher.py not found" >&2; exit 1; }

export PYTHONPATH="$launcher_dir"
export PYTHONDONTWRITEBYTECODE=1
export RULES_K8S_SLOT_DIR="$TEST_TMPDIR/slots"
unset RULES_K8S_ETCD_READY_TIMEOUT RULES_K8S_APISERVER_READY_TIMEOUT RULES_K8S_CRD_ESTABLISHED_TIMEOUT \
      RULES_K8S_ETCD_UNSAFE_NO_FSYNC RULES_K8S_MAX_SERVERS RULES_K8S_MIN_FREE_MB

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- 1. Readiness timeouts ---------------------------------------------------
echo "=== readiness timeouts"
python3 -c '
import launcher
c = launcher._load_config()
assert (c.etcd_ready_timeout, c.apiserver_ready_timeout) == (15, 45), c
' || fail "defaults are not 15 s / 45 s"
RULES_K8S_ETCD_READY_TIMEOUT=60 RULES_K8S_APISERVER_READY_TIMEOUT=" 2.5 " python3 -c '
import launcher
c = launcher._load_config()
assert (c.etcd_ready_timeout, c.apiserver_ready_timeout) == (60, 2.5), c
' || fail "valid values not read"
echo "PASS: defaults 15/45, values read"

# Each invalid value makes the launcher exit 1 with a message naming the
# variable, before it reads its manifest (none is set here).
for var in RULES_K8S_ETCD_READY_TIMEOUT RULES_K8S_APISERVER_READY_TIMEOUT RULES_K8S_CRD_ESTABLISHED_TIMEOUT; do
    for bad in abc 0 -5 nan inf 10s; do
        set +e
        out="$(env "$var=$bad" python3 "$launcher_dir/launcher.py" 2>&1)"
        rc=$?
        set -e
        [[ $rc == 1 ]] || fail "$var=$bad: exit $rc, want 1: $out"
        grep -qF "ERROR: $var='$bad': expected a positive number of seconds" <<<"$out" \
            || fail "$var=$bad: unclear error: $out"
        grep -q Traceback <<<"$out" && fail "$var=$bad: traceback instead of a message: $out"
    done
done
echo "PASS: invalid timeouts fail clearly"

for spec in RULES_K8S_MAX_SERVERS=-1 RULES_K8S_MAX_SERVERS=two RULES_K8S_MIN_FREE_MB=1.5 \
            RULES_K8S_ETCD_UNSAFE_NO_FSYNC=yes; do
    set +e
    out="$(env "$spec" python3 "$launcher_dir/launcher.py" 2>&1)"
    rc=$?
    set -e
    [[ $rc == 1 ]] && grep -qF "ERROR: ${spec%%=*}=" <<<"$out" || fail "$spec: exit $rc: $out"
done
echo "PASS: other invalid settings fail clearly"

# The CRDs to wait for come from kubectl apply's output (#5).
python3 -c '
import launcher
assert launcher._load_config().crd_established_timeout == 30
out = """customresourcedefinition.apiextensions.k8s.io/widgets.rules-k8s.test serverside-applied
clusterrole.rbac.authorization.k8s.io/reader serverside-applied
customresourcedefinition.apiextensions.k8s.io/gadgets.example.com unchanged
"""
assert launcher._applied_crds(out) == ["widgets.rules-k8s.test", "gadgets.example.com"], launcher._applied_crds(out)
assert launcher._applied_crds("") == []
' || fail "CRD names from kubectl apply output"
echo "PASS: CRD names parsed from kubectl apply; RULES_K8S_CRD_ESTABLISHED_TIMEOUT defaults to 30 s"

# --- 2. A fake etcd ------------------------------------------------------------
# Records its argv, lists --unsafe-no-fsync in --help unless FAKE_OLD_ETCD is
# set, and answers /health on its client URL unless FAKE_NEVER_READY is set.
fake_etcd="$TEST_TMPDIR/fake-etcd"
cat > "$fake_etcd" <<'FAKE'
#!/usr/bin/env python3
import http.server, os, sys, time
args = sys.argv[1:]
if args == ["--help"]:
    print("  --data-dir\n" + ("" if os.environ.get("FAKE_OLD_ETCD") else "  --unsafe-no-fsync 'false'\n"))
    sys.exit(0)
with open(os.environ["FAKE_ARGV"], "w") as f:
    f.write("\n".join(args) + "\n")
if os.environ.get("FAKE_NEVER_READY"):
    time.sleep(600)
port = int(args[args.index("--listen-client-urls") + 1].rsplit(":", 1)[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"health":"true"}')
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
FAKE
chmod +x "$fake_etcd"

start_fake_etcd() { # runs _start_etcd with the fake, as _k8s_setup does
    python3 -c '
import os, sys, launcher
cfg = launcher._load_config()
d = sys.argv[2]; os.makedirs(d, exist_ok=True)
proc, port = launcher._start_etcd(sys.argv[1], d, cfg.etcd_ready_timeout,
    launcher._etcd_extra_flags(sys.argv[1], cfg.etcd_unsafe_no_fsync))
proc.terminate(); proc.wait()
' "$fake_etcd" "$TEST_TMPDIR/etcd-run"
}

echo "=== etcd --unsafe-no-fsync"
export FAKE_ARGV="$TEST_TMPDIR/etcd-argv"
start_fake_etcd > "$TEST_TMPDIR/etcd.out" 2>&1 || { cat "$TEST_TMPDIR/etcd.out" >&2; fail "fake etcd did not start"; }
grep -qx -- --unsafe-no-fsync "$FAKE_ARGV" || { cat "$FAKE_ARGV" >&2; fail "--unsafe-no-fsync not on etcd's command line by default"; }
echo "PASS: --unsafe-no-fsync is on etcd's command line by default"

RULES_K8S_ETCD_UNSAFE_NO_FSYNC=0 start_fake_etcd > "$TEST_TMPDIR/etcd.out" 2>&1 || { cat "$TEST_TMPDIR/etcd.out" >&2; fail "fake etcd did not start"; }
grep -q -- --unsafe-no-fsync "$FAKE_ARGV" && fail "RULES_K8S_ETCD_UNSAFE_NO_FSYNC=0 still passes --unsafe-no-fsync"
echo "PASS: RULES_K8S_ETCD_UNSAFE_NO_FSYNC=0 leaves it out"

FAKE_OLD_ETCD=1 start_fake_etcd > "$TEST_TMPDIR/etcd.out" 2>&1 || { cat "$TEST_TMPDIR/etcd.out" >&2; fail "fake etcd did not start"; }
grep -q -- --unsafe-no-fsync "$FAKE_ARGV" && fail "--unsafe-no-fsync passed to an etcd without it"
grep -q "etcd has no --unsafe-no-fsync" "$TEST_TMPDIR/etcd.out" || fail "no message for an etcd without --unsafe-no-fsync"
echo "PASS: an etcd without the flag runs without it"

echo "=== RULES_K8S_ETCD_READY_TIMEOUT bounds the etcd wait"
start=$SECONDS
set +e
FAKE_NEVER_READY=1 RULES_K8S_ETCD_READY_TIMEOUT=1 start_fake_etcd > "$TEST_TMPDIR/etcd.out" 2>&1
rc=$?
set -e
[[ $rc != 0 ]] || fail "etcd that never answers counted as ready"
grep -q "etcd did not become ready within 1s (RULES_K8S_ETCD_READY_TIMEOUT)" "$TEST_TMPDIR/etcd.out" \
    || { cat "$TEST_TMPDIR/etcd.out" >&2; fail "timeout message"; }
(( SECONDS - start < 10 )) || fail "a 1 s budget took $((SECONDS - start)) s"
echo "PASS: a 1 s etcd budget gives up after 1 s"

# --- 3. Server slots -------------------------------------------------------------
echo "=== RULES_K8S_MAX_SERVERS=1"
export RULES_K8S_MAX_SERVERS=1
# The holder takes the slot the way _k8s_setup does, then execs a sleep the
# way test mode execs the test binary: the slot must survive the execve.
TEST_TARGET=//first python3 -c '
import os, launcher
cfg = launcher._load_config()
fd = launcher._acquire_slot(cfg.max_servers, os.environ["TEST_TARGET"])
print("holding", flush=True)
os.execv("/bin/sleep", ["sleep", "600"])
' > "$TEST_TMPDIR/a.log" 2>&1 &
holder=$!
for _ in $(seq 50); do grep -q holding "$TEST_TMPDIR/a.log" && break; sleep 0.1; done
grep -q holding "$TEST_TMPDIR/a.log" || { cat "$TEST_TMPDIR/a.log" >&2; fail "holder did not get the slot"; }
grep -q "server slot 1/1 acquired" "$TEST_TMPDIR/a.log" || fail "no acquired message"

TEST_TARGET=//second python3 -c '
import launcher
cfg = launcher._load_config()
launcher._acquire_slot(cfg.max_servers, "//second")
print("acquired", flush=True)
' > "$TEST_TMPDIR/b.log" 2>&1 &
waiter=$!
sleep 3
grep -q acquired "$TEST_TMPDIR/b.log" && fail "second launcher got a slot that was taken (lost across execve?)"
grep -q "waiting for a server slot (RULES_K8S_MAX_SERVERS=1); held by: pid $holder target //first" "$TEST_TMPDIR/b.log" \
    || { cat "$TEST_TMPDIR/b.log" >&2; fail "waiting message does not name the holder"; }
echo "PASS: second launcher waits and names the holder, across the holder's execve"

kill -KILL "$holder"
wait "$holder" 2>/dev/null || true
for _ in $(seq 50); do grep -q acquired "$TEST_TMPDIR/b.log" && break; sleep 0.2; done
grep -q acquired "$TEST_TMPDIR/b.log" || { cat "$TEST_TMPDIR/b.log" >&2; fail "slot not freed by SIGKILL"; }
wait "$waiter"
echo "PASS: SIGKILLed holder's slot is taken over"

echo "=== RULES_K8S_MAX_SERVERS=0 and the default"
RULES_K8S_MAX_SERVERS=0 timeout 10 python3 -c '
import launcher
assert launcher._acquire_slot(launcher._load_config().max_servers, "t") is None
' || fail "RULES_K8S_MAX_SERVERS=0 still limits"
unset RULES_K8S_MAX_SERVERS
python3 -c '
import os, launcher
want = max(2, len(os.sched_getaffinity(0)))
got = launcher._load_config().max_servers
assert got == want, (got, want)
' || fail "default is not max(2, usable CPUs)"
[[ "$(stat -c %a "$RULES_K8S_SLOT_DIR/slot-0")" == 666 ]] || fail "slot file not mode 666"
echo "PASS: 0 means no limit; default max(2, CPUs); slot files lockable by other users"

# The default directory must be writable here, i.e. inside Bazel's
# linux-sandbox, which mounts $XDG_RUNTIME_DIR read-only.
if [[ -d /dev/shm ]]; then
    RULES_K8S_SLOT_DIR= python3 -c '
import os, launcher
d = launcher._slot_dir()
assert d == "/dev/shm/rules_kubernetes-%d/slots" % os.getuid(), d
# Not a slot: real launchers may hold those right now.
probe = os.path.join(d, "probe-%d" % os.getpid())
open(probe, "w").close()
os.unlink(probe)
' || fail "default slot directory not usable"
    echo "PASS: default slot directory /dev/shm/rules_kubernetes-$(id -u)/slots is usable"
fi

# --- 4. Name claims ----------------------------------------------------------
echo "=== name claims"
claims="$TEST_TMPDIR/claims"
mkdir -p "$claims"
python3 -c '
import launcher, sys, time
launcher._claim_name(sys.argv[1], "c", "//b:c", "kubernetes_server")
print("holding", flush=True)
time.sleep(600)
' "$claims" > "$TEST_TMPDIR/claim_holder.log" 2>&1 &
holder=$!
for _ in $(seq 50); do grep -q holding "$TEST_TMPDIR/claim_holder.log" && break; sleep 0.1; done
grep -q holding "$TEST_TMPDIR/claim_holder.log" || { cat "$TEST_TMPDIR/claim_holder.log" >&2; fail "holder did not claim c"; }

# A real launcher (server mode) with the same name: exits 1 naming both
# targets, before it resolves a binary or writes a file.
echo '{"workspace": "_main", "kube_apiserver_bin": "x", "etcd_bin": "x", "kubectl_bin": "x"}' > "$claims/manifest.json"
set +e
out="$(TEST_TMPDIR="$claims" RULES_K8S_MODE=server RULES_K8S_MANIFEST="$claims/manifest.json" \
       RULES_K8S_OUTPUT_ENV_FILE="$claims/c.env" RULES_K8S_TARGET_NAME=c RULES_K8S_TARGET_LABEL=//a:c \
       python3 "$launcher_dir/launcher.py" 2>&1)"
rc=$?
set -e
[[ $rc == 1 ]] || fail "second claimant: exit $rc, want 1: $out"
grep -qF "ERROR: kubernetes_server //a:c: \$TEST_TMPDIR/c.env and c.kubeconfig are already used by //b:c (pid $holder) in this test; give the targets different names" <<<"$out" \
    || fail "second claimant: message does not name both targets: $out"
grep -q Traceback <<<"$out" && fail "second claimant: traceback: $out"
leftover="$(cd "$claims" && ls -A | grep -v -x -e c.claim -e manifest.json || true)"
[[ -z "$leftover" ]] || fail "second claimant wrote files: $leftover"
grep -q "\"pid\": $holder" "$claims/c.claim" || fail "holder's claim was replaced: $(cat "$claims/c.claim")"
echo "PASS: a second launcher for the same name fails, naming both targets"

# Different names don't conflict.
python3 -c '
import launcher, sys
launcher._claim_name(sys.argv[1], "d", "//a:d", "kubernetes_server")
' "$claims" || fail "a different name was refused"
echo "PASS: different names coexist"

# The holder exits: its claim is taken over.
kill -KILL "$holder"; wait "$holder" 2>/dev/null || true
python3 -c '
import json, launcher, os, sys
launcher._claim_name(sys.argv[1], "c", "//a:c", "kubernetes_test")
held = json.load(open(os.path.join(sys.argv[1], "c.claim")))
assert held == {"label": "//a:c", "pid": os.getpid(), "rule": "kubernetes_test"}, held
' "$claims" || fail "stale claim not taken over"
ls "$claims" | grep -q '\.tmp$' && fail "temporary claim files left: $(ls "$claims")"
echo "PASS: an exited launcher's claim is taken over"

echo "PASS"
