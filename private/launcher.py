#!/usr/bin/env python3
"""
rules_kubernetes launcher.

RULES_K8S_MODE=test   (default): etcd → apiserver → manifests → namespace
                                   → controller → wait → execve(test_binary)
RULES_K8S_MODE=server:            etcd → apiserver → manifests → namespace
                                   → write env file → signal.pause()
"""

import atexit
import dataclasses
import json
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


def _is_port_conflict(log_file):
    """Return True if the log file mentions an address-already-in-use error."""
    try:
        with open(log_file) as f:
            return "address already in use" in f.read().lower()
    except FileNotFoundError:
        return False


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

def _wait_etcd_ready(port, log_file, timeout=15):
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
        f"etcd did not become ready within {timeout}s.\nLog:\n{log}")


def _start_etcd(etcd_bin, test_tmpdir):
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
        ]
        env = os.environ.copy()
        env["HOME"] = test_tmpdir

        with open(log_file, "w") as log_f:
            proc = subprocess.Popen(cmd, stdout=log_f, stderr=log_f, env=env)

        try:
            _wait_etcd_ready(client_port, log_file)
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

def _wait_apiserver_ready(port, pki_dir, log_file, timeout=45):
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
                f"kube-apiserver TCP port did not open within {timeout}s.\n"
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
        f"kube-apiserver /readyz did not return 200 within {timeout}s.\n"
        f"Last error: {last_err}\nLog:\n{log}")


def _start_apiserver(apiserver_bin, etcd_client_port, pki_dir, test_tmpdir):
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
            proc = subprocess.Popen(cmd, stdout=log_f, stderr=log_f, env=env)

        try:
            _wait_apiserver_ready(port, pki_dir, log_file)
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


def _k8s_setup(m, workspace):
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

    _log("bootstrapping TLS…")
    _bootstrap_tls(pki_dir)

    _log("starting etcd…")
    etcd_proc, etcd_client_port = _start_etcd(etcd_bin, test_tmpdir)
    atexit.register(etcd_proc.terminate)
    _log(f"etcd ready on :{etcd_client_port}")

    _log("starting kube-apiserver…")
    apiserver_proc, apiserver_port = _start_apiserver(
        apiserver_bin, etcd_client_port, pki_dir, test_tmpdir)
    atexit.register(apiserver_proc.terminate)
    apiserver_url = f"https://{HOST}:{apiserver_port}"
    _log(f"kube-apiserver ready at {apiserver_url}")

    kubeconfig = os.path.join(test_tmpdir, "kubeconfig")
    _write_kubeconfig(kubeconfig, pki_dir, apiserver_url, namespace)

    manifest_files = m.get("manifest_files", [])
    if manifest_files:
        _log(f"applying {len(manifest_files)} manifest file(s)…")
        resolved = [_find_runfile(p, workspace) for p in manifest_files]
        _apply_manifests(kubectl_bin, kubeconfig, resolved)

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

def main_test(m, workspace):
    state = _k8s_setup(m, workspace)

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
        atexit.register(controller_proc.terminate)

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

def main_server(m, workspace):
    state = _k8s_setup(m, workspace)

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
        main_server(m, workspace)
    else:
        main_test(m, workspace)


if __name__ == "__main__":
    main()
