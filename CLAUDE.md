# rules_kubernetes

Bazel rules for running controller and operator integration tests against an
ephemeral Kubernetes API server. Provides hermetic, parallel-safe Kubernetes
clusters for `*_test` targets with zero external dependencies at runtime — no
Docker, no root, no shared cluster. Uses host-installed or downloaded
`kube-apiserver` + `etcd` binaries.

## Commit requirements

- All tests must pass before any commit with code changes (`bazel test //tests/...`).
- All documentation (`README.md`, `DESIGN.md`, `CLAUDE.md`) must be updated to
  reflect any code changes before committing. This includes new rules, changed
  attributes, new public API surface, and behaviour changes.

## Repo layout

```
rules_kubernetes/
├── MODULE.bazel              # Bzlmod module definition
├── WORKSPACE                 # Legacy workspace (compatibility shim)
├── defs.bzl                  # Public API re-exports
├── extensions.bzl            # Module extension: k8s binary repos (download or system)
├── repositories.bzl          # Legacy WORKSPACE equivalents of extensions.bzl
├── BUILD.bazel               # Platform config_settings + kubernetes_binary targets
├── DESIGN.md                 # Architecture and design decisions
├── private/
│   ├── binary.bzl            # kubernetes_binary rule + KubernetesBinaryInfo provider
│   ├── manifest.bzl          # kubernetes_manifest rule + KubernetesManifestInfo provider
│   ├── controller.bzl        # kubernetes_controller rule + KubernetesControllerInfo provider
│   ├── test.bzl              # kubernetes_test macro + _k8s_launcher_test rule
│   ├── server.bzl            # kubernetes_server + kubernetes_health_check rules
│   └── launcher.py           # Launcher: etcd → apiserver → manifests → controller → exec
├── toolchain/
│   ├── toolchain.bzl         # Toolchain type + register helpers
│   └── BUILD.bazel
└── tests/
    ├── BUILD.bazel
    ├── apiserver_smoke_test.sh      # Basic API server connectivity + namespace isolation
    ├── manifest_test.sh             # CRD apply and object create/read round-trip
    ├── controller_test.sh           # Controller reconcile loop end-to-end
    ├── kubernetes_server_test.sh    # kubernetes_server lifecycle test
    ├── kubernetes_health_check_test.sh  # kubernetes_health_check behavior test
    └── controllers/
        └── echo_controller/        # Example controller for smoke tests
```

## Key concepts

### Providers (chain)

```
KubernetesBinaryInfo
  └─ KubernetesManifestInfo   (carries KubernetesBinaryInfo + ordered manifest depset)
       └─ KubernetesControllerInfo  (carries KubernetesManifestInfo + controller binary)
            └─ consumed by kubernetes_test (_k8s_launcher_test) and kubernetes_server
```

### `kubernetes_test` isolation model

Every `kubernetes_test` target gets:
- Its own `etcd` process on a dynamically allocated free port
- Its own `kube-apiserver` process on a dynamically allocated free port
- Ephemeral TLS credentials generated at runtime in `$TEST_TMPDIR/pki/`
- A per-test kubeconfig written to `$TEST_TMPDIR/kubeconfig`
- A UUID-based namespace (`k8s-test-<12-hex-chars>`) created at runtime
- Env vars injected: `KUBECONFIG`, `KUBE_NAMESPACE`, `KUBE_API_SERVER`

No shared state between tests → full `--jobs` parallelism is safe.

### Launcher modes

The launcher (`private/launcher.py`) supports two modes selected by `RULES_K8S_MODE`:

| Mode | Env var | Behaviour |
|------|---------|-----------|
| `test` (default) | `K8S_MANIFEST` | etcd → apiserver → manifests → namespace → controller → wait → execve |
| `server` | `RULES_K8S_MANIFEST` | etcd → apiserver → manifests → namespace → write env file → signal.pause() |

Test mode is used by `kubernetes_test`. Server mode is used by `kubernetes_server`
for `rules_itest` integration.

### Port allocation

`_allocate_port()` uses `socket.bind(('127.0.0.1', 0))` to get a free port.
Three ports are allocated per test: one for `kube-apiserver`, two for `etcd`
(client and peer). Sockets are closed just before the processes start. Up to
5 retries handle the rare TOCTOU race.

### TLS bootstrap

`kube-apiserver` requires TLS. The launcher generates ephemeral credentials at
runtime via `openssl` subprocess calls (or the `cryptography` Python package if
available). All cert/key files are written to `$TEST_TMPDIR/pki/` and
referenced in `$TEST_TMPDIR/kubeconfig`. Nothing is pre-baked into the repo.

### Manifest application

`kubernetes_manifest` files are applied via `kubectl apply -f <file>` in listed
order after the API server is ready and before the controller starts. Failures
print the full `kubectl` output and abort immediately.

### Binary source (distribution-independent)

`extensions.bzl` (Bzlmod) and `repositories.bzl` (WORKSPACE) both support two
modes:

| Tag / function                      | Behavior                                              |
|-------------------------------------|-------------------------------------------------------|
| `kubernetes.version()`              | Downloads envtest-bins tarballs (kube-apiserver + etcd) |
| `kubernetes.system()`               | Symlinks host-installed kube-apiserver + etcd         |
| `kubernetes_system_dependencies()`  | WORKSPACE equivalent of `kubernetes.system()`         |

**Auto-detection** — when `bin_dir` is omitted, the repository rule resolves
both binaries:

1. `command -v kube-apiserver` (PATH lookup)
2. Common paths: `/usr/local/kubebuilder/bin`, `/usr/local/bin`, `/usr/bin`,
   and `$HOME/.local/kubebuilder/bin`

If either binary cannot be found, the build fails with a clear error pointing
to the missing binary and a suggested install command.

Download source: GitHub releases from `kubernetes-sigs/controller-tools`
(the same tarballs used by `setup-envtest` from `sigs.k8s.io/controller-runtime`):

```
https://github.com/kubernetes-sigs/controller-tools/releases/download/
    envtest-v<version>/envtest-v<version>-<os>-<arch>.tar.gz
```

Platforms supported: `linux_amd64`, `darwin_arm64`, `darwin_amd64`.

### Analysis-time validation

`kubernetes_manifest` validates at analysis time:
- `srcs` must be non-empty.
- All files must have `.yaml` or `.yml` extension.

`kubernetes_controller` validates at analysis time:
- `controller_binary` must be a label.

Failures surface as `bazel build` errors, not as flaky test failures.

### Combined test manifest

`_k8s_launcher_test` generates a JSON manifest at build time:

```json
{
  "workspace":          "<workspace_name>",
  "kube_apiserver_bin": "<runfile path>",
  "etcd_bin":           "<runfile path>",
  "kubectl_bin":        "<runfile path>",
  "controller_binary":  "<runfile path>",
  "manifest_files":     ["config/crd/foo_crd.yaml", "config/rbac/role.yaml"]
}
```

`controller_binary` and `manifest_files` are omitted when not provided.

### `kubernetes_server` readiness protocol

`kubernetes_server` writes `$TEST_TMPDIR/<name>.env` atomically (via temp file
+ `os.replace`) once the server is fully ready:

```
KUBECONFIG=/tmp/.../kubeconfig
KUBE_NAMESPACE=k8s-test-abc123def456
KUBE_API_SERVER=https://127.0.0.1:54321
KUBECTL=/path/to/kubectl
```

`kubernetes_health_check` exits 0 iff this file exists.

## Public API

```python
load("@rules_kubernetes//:defs.bzl",
    "kubernetes_manifest",
    "kubernetes_controller",
    "kubernetes_test",
    "kubernetes_server",
    "kubernetes_health_check",
)

# Declare YAML manifests to apply before the test (CRDs, RBAC, etc.).
kubernetes_manifest(
    name = "my_crds",
    srcs = glob(["config/crd/*.yaml"]),
    # Applied in listed order. Use numeric prefixes: 001_crd.yaml, 002_rbac.yaml.
)

# Declare a controller binary.
kubernetes_controller(
    name              = "my_controller",
    controller_binary = "//cmd/controller",   # required: a *_binary target
    manifests         = ":my_crds",           # optional
    ready_probe       = "lease",              # "lease" (default) or "env_file"
    # "lease": polls for a leader-election Lease object in the namespace
    # "env_file": controller writes $RULES_K8S_READY_FILE when ready
)

# Run an isolated test against an ephemeral Kubernetes API server.
kubernetes_test(
    name       = "my_test",
    controller = ":my_controller",    # optional: kubernetes_controller target
    srcs       = ["my_test.sh"],      # forwarded to test_rule
    deps       = [...],               # forwarded to test_rule
    size       = "medium",            # optional, default "medium"
    timeout    = None,                # optional
    tags       = [...],               # optional
    test_rule  = go_test,             # optional; default native.sh_test
    **kwargs,
)

# Long-running API server for rules_itest multi-service tests.
kubernetes_server(
    name      = "my_apiserver",
    manifests = ":my_crds",           # optional
)

kubernetes_health_check(
    name   = "my_apiserver_health",
    server = ":my_apiserver",
)
```

### Environment variables injected into the test binary

| Variable          | Example value             | Description                        |
|-------------------|---------------------------|------------------------------------|
| `KUBECONFIG`      | `$TEST_TMPDIR/kubeconfig` | Path to per-test kubeconfig file   |
| `KUBE_NAMESPACE`  | `k8s-test-abc123def456`   | Isolated per-test namespace        |
| `KUBE_API_SERVER` | `https://127.0.0.1:54321` | API server address                 |
| `KUBECTL`         | `/path/to/kubectl`        | Absolute path to the kubectl binary |

### MODULE.bazel (Bzlmod)

```python
bazel_dep(name = "rules_kubernetes", version = "0.1.0")

kubernetes = use_extension("@rules_kubernetes//:extensions.bzl", "kubernetes")

# Use the host-installed kube-apiserver + etcd (auto-detects from PATH):
kubernetes.system(versions = ["1.29"])

# Or specify the path explicitly:
# kubernetes.system(versions = ["1.29"], bin_dir = "/usr/local/kubebuilder/bin")

# Or download pre-built tarballs:
# kubernetes.version(versions = ["1.29"])

use_repo(kubernetes,
    "k8s_1_29_linux_amd64",
    "k8s_1_29_darwin_arm64",
    "k8s_1_29_darwin_amd64",
)
```

### WORKSPACE (legacy)

```python
load("@rules_kubernetes//:repositories.bzl", "kubernetes_system_dependencies")

kubernetes_system_dependencies(versions = ["1.29"])
```

## Development

### Running the self-tests

```sh
bazel test //tests/...
```

All tests must pass before any commit with code changes.

### Test results (last full run: 2026-04-19)

All 5 tests pass on Linux x86_64 with Kubernetes 1.29 (envtest binaries).

| Test target                       | What it verifies                                                              | Result |
|-----------------------------------|-------------------------------------------------------------------------------|--------|
| `//tests:apiserver_smoke_test`    | API server connectivity, namespace isolation, ConfigMap CRUD                  | PASSED |
| `//tests:manifest_test`           | kubernetes_manifest applies YAML before the test binary runs                  | PASSED |
| `//tests:controller_test`         | echo_controller mirrors ConfigMaps; env_file readiness probe                  | PASSED |
| `//tests:kubernetes_server_test`  | kubernetes_server starts, writes env file, responds to SIGTERM                | PASSED |
| `//tests:kubernetes_health_check_test` | kubernetes_health_check exits non-zero without env file, 0 when present  | PASSED |

### Launcher script

`private/launcher.py` is the heart of both `kubernetes_test` and
`kubernetes_server`. The mode is selected by the `RULES_K8S_MODE` environment
variable (set by the generated wrapper script):

| Mode | Set by | Behaviour |
|---|---|---|
| `test` (default) | `kubernetes_test` wrapper | `_k8s_setup` → `os.execve(test_binary)` |
| `server` | `kubernetes_server` wrapper | `_k8s_setup` → write env file → `signal.pause()` |

Both modes share `_k8s_setup`, which:

1. Reads the JSON manifest (`K8S_MANIFEST` or `RULES_K8S_MANIFEST`).
2. Resolves all runfile paths.
3. Ensures all binaries have the execute bit set.
4. Allocates three free TCP ports.
5. Generates UUID namespace name.
6. Bootstraps TLS credentials (`_bootstrap_tls`).
7. Starts `etcd`; waits for readiness.
8. Starts `kube-apiserver`; waits for `/readyz` (max 30 s).
9. Retries on port conflict only; fails immediately on any other error.
10. Applies manifest files via `kubectl apply -f` in order.
11. Creates the UUID namespace via `kubectl create namespace`.
12. Starts the controller subprocess (if provided).
13. Waits for controller readiness (leader-election lease poll).
14. Returns a `_K8sState` dataclass with connection details.

After `_k8s_setup`, test mode calls `os.execve` with env vars set;
server mode writes the env file and blocks.

### Test script requirements

All test shell scripts must:
- Begin with `set -euo pipefail`.
- Use a `require_env VAR` guard for `KUBECONFIG`, `KUBE_NAMESPACE`,
  `KUBE_API_SERVER`, and `KUBECTL` before first use.
- Use `"$KUBECTL"` (not bare `kubectl`) — `kubectl` is not on `$PATH` in the
  sandbox; the launcher injects its absolute path via the `KUBECTL` env var.
- Pass `--namespace "$KUBE_NAMESPACE"` on kubectl calls to stay scoped to the
  isolated test namespace.
- Pass `--kubeconfig "$KUBECONFIG"` (or rely on the injected `KUBECONFIG` env
  var, which kubectl respects automatically).

### Style

- All `.bzl` files use 4-space indentation.
- Provider fields are documented with inline comments.
- Public rules/macros have docstrings.
- `private/` contains implementation details; only `defs.bzl` is the stable API.

## Known limitations

- **No actual pod execution.** There is no kubelet. Pods never transition to
  `Running`. Use kwok (Phase 2) if simulated pod lifecycle is needed.
- **Windows is not supported** (no pre-built binary source; PRs welcome).
- **TLS cert generation** requires `openssl` in `PATH` (present on all
  supported Linux and macOS platforms).
- **Controller readiness** is heuristic: the launcher polls for a
  leader-election lease. Controllers that do not use leader election need a
  custom readiness probe.
- **`kubernetes_test` adds ~3–6 s overhead per test** for etcd + apiserver
  startup. For very large test suites, consider a shared-server mode using
  `kubernetes_server`.
- **Target name collision.** Two `kubernetes_server` targets with the same local
  name in different packages write to the same `$TEST_TMPDIR/<name>.env`. Use
  unique target names within a test run.
- **Downloaded tarball SHA-256 checksums** in `extensions.bzl`/`repositories.bzl`
  are placeholder values for darwin platforms. Pin real values before enabling
  `kubernetes.version()` on macOS.
