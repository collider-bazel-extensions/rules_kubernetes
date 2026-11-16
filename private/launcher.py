#!/usr/bin/env python3
"""
rules_kubernetes launcher.

RULES_K8S_MODE=test   (default): etcd → apiserver → manifests → namespace
                                   → controller → wait → execve(test_binary)
RULES_K8S_MODE=server:            etcd → apiserver → manifests → namespace
                                   → write env file → signal.pause()

Tuning (environment; invalid values fail the launcher before anything starts):
  RULES_K8S_ETCD_READY_TIMEOUT       seconds etcd may take to answer /health (15)
  RULES_K8S_APISERVER_READY_TIMEOUT  seconds kube-apiserver may take to answer
                                     /readyz (45)
  RULES_K8S_ETCD_UNSAFE_NO_FSYNC     1 (default): etcd runs with
                                     --unsafe-no-fsync, the data is thrown away
                                     anyway; 0: etcd fsyncs as usual
  RULES_K8S_CRD_ESTABLISHED_TIMEOUT  seconds the CRDs in the manifests may take
                                     to become Established (30)

Admission:
  At most RULES_K8S_MAX_SERVERS (default: the number of usable CPUs, at least
  2; 0 = no limit) launchers per user run an etcd + kube-apiserver at once,
  across Bazel servers: each holds a flock on a slot file under
  RULES_K8S_SLOT_DIR (default /dev/shm/rules_kubernetes-<uid>/slots, which
  Bazel's linux-sandbox leaves writable) from before the TLS bootstrap until
  the launcher, etcd and kube-apiserver have all exited. In test mode the lock
  survives the execve into the test binary. Optionally RULES_K8S_MIN_FREE_MB
  waits for MemAvailable.
"""

import atexit
import dataclasses
import fcntl
import json
import math
import os
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

HOST = "127.0.0.1"


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

def _log(msg):
    print(f"[rules_kubernetes] {msg}", flush=True)


def _find_runfile(rel_path, workspace=""):
    """Resolve a Bazel short_path to an absolute path in the runfiles tree.

    short_path for external repos starts with '../repo/'; in the runfiles
    directory the leading '../' is stripped (repo sits directly under
    RUNFILES_DIR).  Paths in the current workspace have no prefix and must
    be qualified with the workspace name: RUNFILES_DIR/{workspace}/{rel_path}.
    """
    runfiles_dir = os.environ.get("RUNFILES_DIR", "")
    if not runfiles_dir:
        # Derive from the launcher script's own location.
        runfiles_dir = os.path.abspath(sys.argv[0]) + ".runfiles"

    if rel_path.startswith("../"):
        # External repo: strip leading '../'
        normalized = rel_path[3:]
    elif workspace:
        # Current-workspace file: prepend workspace name.
        normalized = workspace + "/" + rel_path
    else:
        normalized = rel_path

    candidate = os.path.join(runfiles_dir, normalized)
    if os.path.exists(candidate):
        return os.path.abspath(candidate)

    raise FileNotFoundError(
        f"runfile not found: {rel_path!r}\n"
        f"  Looked in: {runfiles_dir}\n"
        f"  Normalized: {normalized}"
    )


def _ensure_executable(path):
    try:
        os.chmod(path, os.stat(path).st_mode | 0o111)
    except OSError:
        # Sandboxed runfiles are read-only; skip chmod if the file is
        # already executable (symlinked binary from external repo).
        if not os.access(path, os.X_OK):
            raise


def _allocate_port():
    """Bind to port 0 to get a free port, then close the socket."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind((HOST, 0))
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        return s.getsockname()[1]


def _stop_proc(proc, grace=5):
    """SIGTERM, then SIGKILL after `grace` seconds; wait for the exit.

    Registered with atexit for etcd, kube-apiserver and the controller.
    kube-apiserver's graceful shutdown can take minutes on a loaded host
    (more so once etcd is gone), and the server slot stays taken until it
    exits; the data is thrown away, so there is nothing to shut down
    gracefully for."""
    if proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


def _is_port_conflict(log_file):
    """Return True if the log file mentions an address-already-in-use error."""
    try:
        with open(log_file) as f:
            return "address already in use" in f.read().lower()
    except FileNotFoundError:
        return False


# ---------------------------------------------------------------------------
# Configuration from the environment
# ---------------------------------------------------------------------------

class ConfigError(ValueError):
    """An invalid RULES_K8S_* setting; reported without a traceback."""


_DEFAULT_ETCD_READY_TIMEOUT      = 15
_DEFAULT_APISERVER_READY_TIMEOUT = 45
_DEFAULT_CRD_ESTABLISHED_TIMEOUT = 30


def _env_seconds(name, default):
    """A positive, finite number of seconds from `name`, or `default` when
    unset or empty."""
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        value = None
    if value is None or not math.isfinite(value) or value <= 0:
        raise ConfigError(
            f"{name}={raw!r}: expected a positive number of seconds "
            f"(default {default})")
    return value


def _env_count(name, default):
    """A non-negative integer from `name`, or `default` when unset or empty."""
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        value = -1
    if value < 0:
        raise ConfigError(
            f"{name}={raw!r}: expected a non-negative integer (default {default})")
    return value


def _env_bool(name, default):
    """'1' or '0' from `name`, or `default` when unset or empty."""
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    if raw not in ("0", "1"):
        raise ConfigError(f"{name}={raw!r}: expected 1 or 0")
    return raw == "1"


def _default_max_servers():
    """The number of CPUs this process may run on, at least 2: as many as
    one Bazel server runs tests at once by default (--local_test_jobs), so a
    single Bazel server is never held back, while several together are."""
    try:
        cpus = len(os.sched_getaffinity(0))
    except (AttributeError, OSError):
        cpus = os.cpu_count() or 1
    return max(2, cpus)


@dataclasses.dataclass
class _Config:
    etcd_ready_timeout:      float
    apiserver_ready_timeout: float
    crd_established_timeout: float
    etcd_unsafe_no_fsync:    bool
    max_servers:             int
    min_free_mb:             int


def _load_config():
    """Read every RULES_K8S_* tuning variable; raise ConfigError on the
    first invalid one."""
    return _Config(
        etcd_ready_timeout = _env_seconds(
            "RULES_K8S_ETCD_READY_TIMEOUT", _DEFAULT_ETCD_READY_TIMEOUT),
        apiserver_ready_timeout = _env_seconds(
            "RULES_K8S_APISERVER_READY_TIMEOUT", _DEFAULT_APISERVER_READY_TIMEOUT),
        crd_established_timeout = _env_seconds(
            "RULES_K8S_CRD_ESTABLISHED_TIMEOUT", _DEFAULT_CRD_ESTABLISHED_TIMEOUT),
        etcd_unsafe_no_fsync = _env_bool("RULES_K8S_ETCD_UNSAFE_NO_FSYNC", True),
        max_servers = _env_count("RULES_K8S_MAX_SERVERS", _default_max_servers()),
        min_free_mb = _env_count("RULES_K8S_MIN_FREE_MB", 0),
    )


# ---------------------------------------------------------------------------
# Admission: a per-user limit on concurrent API servers
# ---------------------------------------------------------------------------

def _slot_dir():
    """RULES_K8S_SLOT_DIR, or /dev/shm/rules_kubernetes-<uid>/slots.

    /dev/shm because it is the one host-shared directory that Bazel's
    linux-sandbox leaves writable (it mounts $XDG_RUNTIME_DIR read-only and
    gives each test a private /tmp), so sandboxed and unsandboxed launchers
    of every Bazel server meet in the same directory. Elsewhere (macOS) the
    default is $XDG_RUNTIME_DIR, else the temp dir. Point several users at
    one directory (e.g. a mode-1777 one) to share the limit across them."""
    d = os.environ.get("RULES_K8S_SLOT_DIR")
    shared = bool(d)
    if not d:
        uid = os.getuid()
        if os.path.isdir("/dev/shm"):
            base = os.path.join("/dev/shm", f"rules_kubernetes-{uid}")
        else:
            runtime_dir = os.environ.get("XDG_RUNTIME_DIR") or ""
            if runtime_dir and os.path.isdir(runtime_dir):
                base = os.path.join(runtime_dir, "rules_kubernetes")
            else:
                base = os.path.join(tempfile.gettempdir(), f"rules_kubernetes-{uid}")
        try:
            os.makedirs(base, mode=0o700, exist_ok=True)
            st = os.stat(base)
        except OSError as e:
            raise RuntimeError(
                f"cannot create the server slot directory {base}: {e}\n"
                "Set RULES_K8S_SLOT_DIR to a directory the test can write "
                "(and --sandbox_writable_path=<it> when sandboxed), or "
                "RULES_K8S_MAX_SERVERS=0 to turn the limit off.") from e
        # /dev/shm is world-writable: don't use another user's directory.
        if st.st_uid != uid or st.st_mode & 0o022:
            raise RuntimeError(
                f"server slot directory {base} is not owned by uid {uid} "
                "or is writable by others; remove it, or set "
                "RULES_K8S_SLOT_DIR")
        d = os.path.join(base, "slots")
    try:
        os.makedirs(d, mode=0o777 if shared else 0o700, exist_ok=True)
    except OSError as e:
        raise RuntimeError(
            f"cannot create the server slot directory {d}: {e}\n"
            "Set RULES_K8S_SLOT_DIR to a directory the test can write "
            "(and --sandbox_writable_path=<it> when sandboxed), or "
            "RULES_K8S_MAX_SERVERS=0 to turn the limit off.") from e
    return d


def _acquire_slot(limit, target):
    """Block until one of `limit` slots is free and return its fd, or None
    when limit is 0 (no limit).

    The fd is inheritable: it survives the launcher's execve into the test
    binary, and _start_etcd/_start_apiserver pass it to etcd and
    kube-apiserver, so the slot stays taken until every one of them has
    exited (the kernel drops a flock when its last fd closes, SIGKILL
    included). The wait has no timeout of its own; the test's timeout
    bounds it."""
    if limit <= 0:
        return None
    d = _slot_dir()
    last_report = None
    while True:
        holders = []
        for i in range(limit):
            path = os.path.join(d, f"slot-{i}")
            fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o666)
            try:
                # Lockable by every user sharing RULES_K8S_SLOT_DIR (the
                # default directory is private to the user anyway).
                os.fchmod(fd, 0o666)
            except OSError:
                pass  # created by another user
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                try:
                    holders.append(os.read(fd, 4096).decode(errors="replace").strip())
                except OSError:
                    pass
                os.close(fd)
                continue
            os.ftruncate(fd, 0)
            os.write(fd, f"pid {os.getpid()} target {target} "
                         f"since {time.strftime('%H:%M:%S')}".encode())
            os.set_inheritable(fd, True)
            _log(f"server slot {i + 1}/{limit} acquired")
            return fd
        now = time.monotonic()
        if last_report is None or now - last_report >= 60:
            _log(f"waiting for a server slot (RULES_K8S_MAX_SERVERS={limit}); "
                 "held by: " + "; ".join(h or "?" for h in holders))
            last_report = now
        time.sleep(1)


def _mem_available_mb():
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) // 1024
    except (OSError, ValueError):
        pass
    return None


def _wait_free_memory(want):
    """With RULES_K8S_MIN_FREE_MB set, wait until MemAvailable reaches it."""
    if want <= 0:
        return
    last_report = None
    while True:
        have = _mem_available_mb()
        if have is None or have >= want:
            return
        now = time.monotonic()
        if last_report is None or now - last_report >= 60:
            _log(f"waiting for memory: {have} MB available, "
                 f"RULES_K8S_MIN_FREE_MB={want}")
            last_report = now
        time.sleep(5)


# ---------------------------------------------------------------------------
# TLS bootstrap
# ---------------------------------------------------------------------------

def _run_openssl(*args):
    result = subprocess.run(
        ["openssl"] + list(args),
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"openssl {args[0]} failed:\n{result.stderr}")


def _bootstrap_tls(pki_dir):
    """Generate ephemeral TLS credentials for one test run.

    Files written to pki_dir/:
      ca.key / ca.crt          — self-signed CA
      server.key / server.crt  — kube-apiserver cert (SAN: IP:127.0.0.1)
      client.key / client.crt  — admin client cert (O=system:masters)
      sa.key / sa.pub          — service-account signing key pair
    """
    os.makedirs(pki_dir, mode=0o700, exist_ok=True)

    # CA
    _run_openssl("genrsa", "-out", f"{pki_dir}/ca.key", "2048")
    _run_openssl("req", "-x509", "-new", "-nodes",
                 "-key",  f"{pki_dir}/ca.key",
                 "-subj", "/CN=test-ca",
                 "-days", "1",
                 "-out",  f"{pki_dir}/ca.crt")

    # API server cert — must include SAN for Go's strict TLS validation.
    _run_openssl("genrsa", "-out", f"{pki_dir}/server.key", "2048")
    _run_openssl("req", "-new", "-nodes",
                 "-key",  f"{pki_dir}/server.key",
                 "-subj", "/CN=kube-apiserver",
                 "-out",  f"{pki_dir}/server.csr")

    ext_path = f"{pki_dir}/server_ext.cnf"
    with open(ext_path, "w") as f:
        f.write("subjectAltName=IP:127.0.0.1\n")

    _run_openssl("x509", "-req",
                 "-in",      f"{pki_dir}/server.csr",
                 "-CA",      f"{pki_dir}/ca.crt",
                 "-CAkey",   f"{pki_dir}/ca.key",
                 "-CAcreateserial",
                 "-out",     f"{pki_dir}/server.crt",
                 "-days",    "1",
                 "-extfile", ext_path)

    # Admin client cert — CN=admin, O=system:masters → cluster-admin via RBAC.
    _run_openssl("genrsa", "-out", f"{pki_dir}/client.key", "2048")
    _run_openssl("req", "-new", "-nodes",
                 "-key",  f"{pki_dir}/client.key",
                 "-subj", "/CN=admin/O=system:masters",
                 "-out",  f"{pki_dir}/client.csr")
    _run_openssl("x509", "-req",
                 "-in",    f"{pki_dir}/client.csr",
                 "-CA",    f"{pki_dir}/ca.crt",
                 "-CAkey", f"{pki_dir}/ca.key",
                 "-CAcreateserial",
                 "-out",   f"{pki_dir}/client.crt",
                 "-days",  "1")

    # Service-account signing key pair (required by kube-apiserver ≥ 1.20).
    _run_openssl("genrsa", "-out",    f"{pki_dir}/sa.key", "2048")
    _run_openssl("rsa",    "-in",     f"{pki_dir}/sa.key",
                 "-pubout", "-out",   f"{pki_dir}/sa.pub")


def _write_kubeconfig(kubeconfig_path, pki_dir, apiserver_url, namespace):
    content = f"""\
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority: {pki_dir}/ca.crt
    server: {apiserver_url}
  name: test-cluster
contexts:
- context:
    cluster: test-cluster
    namespace: {namespace}
    user: test-admin
  name: test-context
current-context: test-context
users:
- name: test-admin
  user:
    client-certificate: {pki_dir}/client.crt
    client-key: {pki_dir}/client.key
"""
    with open(kubeconfig_path, "w") as f:
        f.write(content)


def _make_ssl_ctx(pki_dir):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.load_verify_locations(f"{pki_dir}/ca.crt")
    ctx.load_cert_chain(f"{pki_dir}/client.crt", f"{pki_dir}/client.key")
    return ctx


# ---------------------------------------------------------------------------
# etcd
# ---------------------------------------------------------------------------

def _wait_etcd_ready(port, log_file, timeout=_DEFAULT_ETCD_READY_TIMEOUT):
    """Poll TCP + HTTP /health until etcd is up."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((HOST, port), timeout=1):
                pass
            resp = urllib.request.urlopen(
                f"http://{HOST}:{port}/health", timeout=2)
            if resp.status == 200:
                return
        except Exception:
            pass
        time.sleep(0.2)

    with open(log_file) as f:
        log = f.read()
    raise TimeoutError(
        f"etcd did not become ready within {timeout:g}s "
        f"(RULES_K8S_ETCD_READY_TIMEOUT).\nLog:\n{log}")


def _etcd_supports_no_fsync(etcd_bin):
    """True if this etcd has --unsafe-no-fsync (etcd >= 3.5; every envtest
    release rules_kubernetes downloads has it, a kubernetes.system() etcd
    may not)."""
    try:
        r = subprocess.run([etcd_bin, "--help"], capture_output=True,
                           text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return "--unsafe-no-fsync" in r.stdout + r.stderr


def _etcd_extra_flags(etcd_bin, unsafe_no_fsync):
    if not unsafe_no_fsync:
        return []
    if not _etcd_supports_no_fsync(etcd_bin):
        _log("etcd has no --unsafe-no-fsync (etcd < 3.5); running with fsync")
        return []
    # The data dir lives in $TEST_TMPDIR and is thrown away with the test,
    # so a crash-consistent disk image buys nothing; fsync stalls on a loaded
    # host do cause `etcdserver: request timed out` (#5).
    return ["--unsafe-no-fsync"]


def _start_etcd(etcd_bin, test_tmpdir, ready_timeout=_DEFAULT_ETCD_READY_TIMEOUT,
                extra_flags=(), pass_fds=()):
    """Start etcd; return (proc, client_port). Retries on port conflict."""
    for attempt in range(1, 6):
        client_port = _allocate_port()
        peer_port   = _allocate_port()
        data_dir    = os.path.join(test_tmpdir, "etcd_data")
        log_file    = os.path.join(test_tmpdir, "etcd.log")

        if os.path.exists(data_dir):
            import shutil
            shutil.rmtree(data_dir)

        token = uuid.uuid4().hex[:8]
        cmd = [
            etcd_bin,
            "--data-dir",                    data_dir,
            "--listen-client-urls",          f"http://{HOST}:{client_port}",
            "--advertise-client-urls",       f"http://{HOST}:{client_port}",
            "--listen-peer-urls",            f"http://{HOST}:{peer_port}",
            "--initial-advertise-peer-urls", f"http://{HOST}:{peer_port}",
            "--initial-cluster",             f"default=http://{HOST}:{peer_port}",
            "--initial-cluster-state",       "new",
            "--initial-cluster-token",       f"test-{token}",
            "--log-level",                   "error",
        ] + list(extra_flags)
        env = os.environ.copy()
        env["HOME"] = test_tmpdir

        with open(log_file, "w") as log_f:
            proc = subprocess.Popen(cmd, stdout=log_f, stderr=log_f, env=env,
                                    pass_fds=pass_fds)

        try:
            _wait_etcd_ready(client_port, log_file, ready_timeout)
            return proc, client_port
        except TimeoutError:
            proc.terminate()
            proc.wait()
            if _is_port_conflict(log_file):
                _log(f"etcd port conflict on attempt {attempt}, retrying…")
                continue
            with open(log_file) as f:
                _log(f"etcd log:\n{f.read()}")
            raise

    raise RuntimeError("etcd failed to start after 5 attempts (port conflict)")


# ---------------------------------------------------------------------------
# kube-apiserver
# ---------------------------------------------------------------------------

def _wait_apiserver_ready(port, pki_dir, log_file,
                          timeout=_DEFAULT_APISERVER_READY_TIMEOUT):
    """Poll TCP + HTTPS /readyz until kube-apiserver is up."""
    # Wait for the TCP port to open first (fast, no TLS setup needed).
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((HOST, port), timeout=1):
                break
        except OSError:
            time.sleep(0.2)
    else:
        with open(log_file) as f:
            raise TimeoutError(
                f"kube-apiserver TCP port did not open within {timeout:g}s "
                f"(RULES_K8S_APISERVER_READY_TIMEOUT).\n"
                f"Log:\n{f.read()}")

    ssl_ctx   = _make_ssl_ctx(pki_dir)
    last_err  = None
    while time.monotonic() < deadline:
        try:
            resp = urllib.request.urlopen(
                f"https://{HOST}:{port}/readyz",
                context=ssl_ctx, timeout=2)
            if resp.status == 200:
                return
        except Exception as e:
            last_err = e
        time.sleep(0.5)

    with open(log_file) as f:
        log = f.read()
    raise TimeoutError(
        f"kube-apiserver /readyz did not return 200 within {timeout:g}s "
        f"(RULES_K8S_APISERVER_READY_TIMEOUT).\n"
        f"Last error: {last_err}\nLog:\n{log}")


def _start_apiserver(apiserver_bin, etcd_client_port, pki_dir, test_tmpdir,
                     ready_timeout=_DEFAULT_APISERVER_READY_TIMEOUT, pass_fds=()):
    """Start kube-apiserver; return (proc, port). Retries on port conflict."""
    for attempt in range(1, 6):
        port     = _allocate_port()
        log_file = os.path.join(test_tmpdir, "apiserver.log")

        cmd = [
            apiserver_bin,
            "--etcd-servers",                  f"http://{HOST}:{etcd_client_port}",
            "--bind-address",                  HOST,
            "--secure-port",                   str(port),
            "--tls-cert-file",                 f"{pki_dir}/server.crt",
            "--tls-private-key-file",          f"{pki_dir}/server.key",
            "--client-ca-file",                f"{pki_dir}/ca.crt",
            "--service-account-key-file",      f"{pki_dir}/sa.pub",
            "--service-account-signing-key-file", f"{pki_dir}/sa.key",
            "--service-account-issuer",        "https://kubernetes.default.svc",
            "--authorization-mode",            "RBAC",
            "--enable-admission-plugins",      "NamespaceLifecycle",
            "--disable-admission-plugins",     "ServiceAccount",
            "--allow-privileged=true",
            "--feature-gates",                 "AllAlpha=false",
            "--storage-backend",               "etcd3",
            "--v",                             "2",
        ]
        env = os.environ.copy()
        env["HOME"] = test_tmpdir

        with open(log_file, "w") as log_f:
            proc = subprocess.Popen(cmd, stdout=log_f, stderr=log_f, env=env,
                                    pass_fds=pass_fds)

        try:
            _wait_apiserver_ready(port, pki_dir, log_file, ready_timeout)
            return proc, port
        except TimeoutError:
            proc.terminate()
            proc.wait()
            if _is_port_conflict(log_file):
                _log(f"apiserver port conflict on attempt {attempt}, retrying…")
                continue
            with open(log_file) as f:
                _log(f"apiserver log:\n{f.read()}")
            raise

    raise RuntimeError("kube-apiserver failed to start after 5 attempts (port conflict)")


# ---------------------------------------------------------------------------
# Post-startup setup
# ---------------------------------------------------------------------------

def _kubectl(kubectl_bin, kubeconfig, *args):
    result = subprocess.run(
        [kubectl_bin, "--kubeconfig", kubeconfig] + list(args),
        capture_output=True, text=True,
    )
    return result


def _apply_manifests(kubectl_bin, kubeconfig, manifest_files):
    # Server-side apply (--server-side) stores field-owner state on
    # the apiserver instead of the legacy
    # `kubectl.kubernetes.io/last-applied-configuration` annotation,
    # which has a hard 256KB size limit. Many real-world CRDs
    # (CNPG Cluster, Argo Workflows, etc.) exceed that limit and
    # fail client-side apply with `metadata.annotations: Too long`.
    # Server-side apply has been the recommended path since k8s 1.22
    # and is GA — see https://kubernetes.io/docs/reference/using-api/server-side-apply/.
    # `--force-conflicts` makes the rule the field manager
    # unconditionally; rules_kubernetes is the source of truth for
    # the manifests it applies, so taking over fields from a prior
    # client-side apply is the right default.
    #
    # Returns the names of the CustomResourceDefinitions applied, from
    # kubectl's "<kind>.<group>/<name> serverside-applied" lines.
    crds = []
    for path in manifest_files:
        _log(f"applying (server-side): {os.path.basename(path)}")
        r = _kubectl(kubectl_bin, kubeconfig,
                     "apply", "--server-side", "--force-conflicts",
                     "-f", path)
        if r.returncode != 0:
            raise RuntimeError(
                f"kubectl apply failed for {path}:\n{r.stdout}\n{r.stderr}")
        if r.stdout.strip():
            _log(r.stdout.strip())
        crds += _applied_crds(r.stdout)
    return crds


_CRD_PREFIX = "customresourcedefinition.apiextensions.k8s.io/"


def _applied_crds(apply_stdout):
    names = []
    for line in apply_stdout.splitlines():
        ref = line.split(" ", 1)[0]
        if ref.startswith(_CRD_PREFIX):
            names.append(ref[len(_CRD_PREFIX):])
    return names


def _wait_crds_established(kubectl_bin, kubeconfig, crds, timeout):
    """Wait until every CRD in `crds` has condition Established=True (#5).

    A CRD's custom resources can't be created until it is Established, and
    `kubectl wait --for=condition=Established` errors out ("<nil> is of the
    type <nil>") while the CRD has no conditions yet, so consumers each
    carried a retry loop. Polls `kubectl get` instead."""
    pending = list(dict.fromkeys(crds))
    _log(f"waiting for {len(pending)} CRD(s) to be Established…")
    deadline = time.monotonic() + timeout
    jsonpath = '{.status.conditions[?(@.type=="Established")].status}'
    while True:
        still = []
        for name in pending:
            r = _kubectl(kubectl_bin, kubeconfig, "get", "crd", name,
                         "-o", f"jsonpath={jsonpath}")
            if r.returncode != 0 or r.stdout.strip() != "True":
                still.append(name)
        pending = still
        if not pending:
            return
        if time.monotonic() >= deadline:
            raise RuntimeError(
                f"CRDs not Established after {timeout:g} s: "
                f"{', '.join(pending)} (RULES_K8S_CRD_ESTABLISHED_TIMEOUT)")
        time.sleep(0.2)


def _create_namespace(kubectl_bin, kubeconfig, namespace):
    r = _kubectl(kubectl_bin, kubeconfig, "create", "namespace", namespace)
    if r.returncode != 0:
        raise RuntimeError(
            f"kubectl create namespace {namespace} failed:\n{r.stderr}")


# ---------------------------------------------------------------------------
# Controller readiness
# ---------------------------------------------------------------------------

def _wait_controller_ready(kubectl_bin, kubeconfig, namespace, ready_probe,
                            ready_file, proc, timeout=30):
    if ready_probe == "env_file":
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if os.path.exists(ready_file):
                return
            if proc.poll() is not None:
                raise RuntimeError(
                    f"controller exited (code {proc.returncode}) before writing ready file")
            time.sleep(0.3)
        # Soft timeout: proceed if controller is still alive.
        if proc.poll() is None:
            _log(f"WARNING: controller ready file not found after {timeout}s, proceeding")
            return
        raise RuntimeError(
            f"controller exited (code {proc.returncode}) before writing ready file")

    else:  # "lease"
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                raise RuntimeError(
                    f"controller exited (code {proc.returncode}) before leader election")
            r = _kubectl(kubectl_bin, kubeconfig,
                         "get", "leases", "-n", namespace, "-o", "name")
            if r.returncode == 0 and r.stdout.strip():
                return
            time.sleep(0.5)
        if proc.poll() is None:
            _log(f"WARNING: no leader-election Lease after {timeout}s, proceeding")
            return
        raise RuntimeError(
            f"controller exited (code {proc.returncode}) before leader election")


# ---------------------------------------------------------------------------
# Shared setup
# ---------------------------------------------------------------------------

@dataclasses.dataclass
class _K8sState:
    kubeconfig:    str
    namespace:     str
    apiserver_url: str
    pki_dir:       str
    kubectl_bin:   str


def _k8s_setup(m, workspace, cfg):
    test_tmpdir = os.environ.get("TEST_TMPDIR") or tempfile.mkdtemp()

    # Resolve binary paths from the manifest's short_paths.
    apiserver_bin = _find_runfile(m["kube_apiserver_bin"], workspace)
    etcd_bin      = _find_runfile(m["etcd_bin"],           workspace)
    kubectl_bin   = _find_runfile(m["kubectl_bin"],        workspace)

    _ensure_executable(apiserver_bin)
    _ensure_executable(etcd_bin)
    _ensure_executable(kubectl_bin)

    namespace = "k8s-test-" + uuid.uuid4().hex[:12]
    pki_dir   = os.path.join(test_tmpdir, "pki")

    # Held (not closed) until this process, or the test binary it execs,
    # and the etcd and kube-apiserver that inherit it have all exited.
    slot = _acquire_slot(cfg.max_servers,
                         os.environ.get("TEST_TARGET") or "?")
    slot_fds = () if slot is None else (slot,)
    _wait_free_memory(cfg.min_free_mb)

    _log("bootstrapping TLS…")
    _bootstrap_tls(pki_dir)

    _log("starting etcd…")
    etcd_proc, etcd_client_port = _start_etcd(
        etcd_bin, test_tmpdir, cfg.etcd_ready_timeout,
        _etcd_extra_flags(etcd_bin, cfg.etcd_unsafe_no_fsync), slot_fds)
    atexit.register(_stop_proc, etcd_proc)
    _log(f"etcd ready on :{etcd_client_port}")

    _log("starting kube-apiserver…")
    apiserver_proc, apiserver_port = _start_apiserver(
        apiserver_bin, etcd_client_port, pki_dir, test_tmpdir,
        cfg.apiserver_ready_timeout, slot_fds)
    atexit.register(_stop_proc, apiserver_proc)
    apiserver_url = f"https://{HOST}:{apiserver_port}"
    _log(f"kube-apiserver ready at {apiserver_url}")

    kubeconfig = os.path.join(test_tmpdir, "kubeconfig")
    _write_kubeconfig(kubeconfig, pki_dir, apiserver_url, namespace)

    manifest_files = m.get("manifest_files", [])
    if manifest_files:
        _log(f"applying {len(manifest_files)} manifest file(s)…")
        resolved = [_find_runfile(p, workspace) for p in manifest_files]
        crds = _apply_manifests(kubectl_bin, kubeconfig, resolved)
        if crds:
            _wait_crds_established(kubectl_bin, kubeconfig, crds,
                                   cfg.crd_established_timeout)

    _log(f"creating namespace {namespace}…")
    _create_namespace(kubectl_bin, kubeconfig, namespace)

    return _K8sState(
        kubeconfig    = kubeconfig,
        namespace     = namespace,
        apiserver_url = apiserver_url,
        pki_dir       = pki_dir,
        kubectl_bin   = kubectl_bin,
    )


# ---------------------------------------------------------------------------
# Test mode
# ---------------------------------------------------------------------------

def main_test(m, workspace, cfg):
    state = _k8s_setup(m, workspace, cfg)

    controller_proc = None
    if "controller_binary" in m:
        controller_bin = _find_runfile(m["controller_binary"], workspace)
        _ensure_executable(controller_bin)

        ready_probe = m.get("ready_probe", "lease")
        ready_file  = os.path.join(
            os.environ.get("TEST_TMPDIR", ""), "controller_ready")

        controller_env = os.environ.copy()
        controller_env["KUBECONFIG"]            = state.kubeconfig
        controller_env["KUBE_NAMESPACE"]        = state.namespace
        controller_env["KUBE_API_SERVER"]       = state.apiserver_url
        controller_env["RULES_K8S_READY_FILE"]  = ready_file

        _log(f"starting controller: {os.path.basename(controller_bin)}")
        controller_proc = subprocess.Popen(
            [controller_bin], env=controller_env)
        atexit.register(_stop_proc, controller_proc)

        _log("waiting for controller readiness…")
        _wait_controller_ready(
            state.kubectl_bin, state.kubeconfig, state.namespace,
            ready_probe, ready_file, controller_proc)
        _log("controller is ready")

    test_binary = os.environ.get("K8S_TEST_BINARY", "")
    if not test_binary or not os.path.exists(test_binary):
        raise RuntimeError(
            f"K8S_TEST_BINARY is not set or does not exist: {test_binary!r}")
    _ensure_executable(test_binary)

    test_env = os.environ.copy()
    test_env.setdefault("HOME", os.environ.get("TEST_TMPDIR", "/tmp"))
    test_env["KUBECONFIG"]      = state.kubeconfig
    test_env["KUBE_NAMESPACE"]  = state.namespace
    test_env["KUBE_API_SERVER"] = state.apiserver_url
    test_env["KUBECTL"]         = state.kubectl_bin

    _log(f"Namespace:  {state.namespace}")
    _log(f"API server: {state.apiserver_url}")
    _log(f"KUBECONFIG: {state.kubeconfig}")

    os.execve(test_binary, [test_binary] + sys.argv[1:], test_env)


# ---------------------------------------------------------------------------
# Server mode
# ---------------------------------------------------------------------------

def main_server(m, workspace, cfg):
    state = _k8s_setup(m, workspace, cfg)

    output_env_file = os.environ.get("RULES_K8S_OUTPUT_ENV_FILE", "")
    if not output_env_file:
        raise RuntimeError("RULES_K8S_OUTPUT_ENV_FILE is not set")

    _log(f"Namespace:  {state.namespace}")
    _log(f"API server: {state.apiserver_url}")

    # Write atomically.
    tmp = output_env_file + ".tmp"
    with open(tmp, "w") as f:
        f.write(f"KUBECONFIG={state.kubeconfig}\n")
        f.write(f"KUBE_NAMESPACE={state.namespace}\n")
        f.write(f"KUBE_API_SERVER={state.apiserver_url}\n")
        f.write(f"KUBECTL={state.kubectl_bin}\n")
    os.replace(tmp, output_env_file)
    _log(f"wrote env file: {output_env_file}")

    def _shutdown(signum, _frame):
        _log(f"received signal {signum}, shutting down…")
        sys.exit(0)

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT,  _shutdown)

    while True:
        signal.pause()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    mode = os.environ.get("RULES_K8S_MODE", "test")

    try:
        cfg = _load_config()
    except ConfigError as e:
        print(f"[rules_kubernetes] ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    if mode == "server":
        manifest_path = os.environ.get("RULES_K8S_MANIFEST", "")
        var_name      = "RULES_K8S_MANIFEST"
    else:
        manifest_path = os.environ.get("K8S_MANIFEST", "")
        var_name      = "K8S_MANIFEST"

    if not manifest_path:
        print(
            f"[rules_kubernetes] ERROR: {var_name} is not set",
            file=sys.stderr)
        sys.exit(1)

    with open(manifest_path) as f:
        m = json.load(f)

    workspace = m["workspace"]

    if mode == "server":
        main_server(m, workspace, cfg)
    else:
        main_test(m, workspace, cfg)


if __name__ == "__main__":
    main()
