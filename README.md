# rules_kubernetes

Bazel rules for running Kubernetes controller and operator integration tests
against an ephemeral API server. No Docker, no root, no shared cluster — each
test gets its own `kube-apiserver` + `etcd` on dynamically allocated ports.

```
bazel test //my/controller/...   # all tests run in parallel, fully isolated
```

## What it does

`rules_kubernetes` wraps the **envtest** approach from
[`sigs.k8s.io/controller-runtime`](https://github.com/kubernetes-sigs/controller-runtime):

- Starts `etcd` and `kube-apiserver` (no kubelet, no Docker).
- Bootstraps ephemeral TLS credentials at runtime.
- Creates a UUID-based namespace per test (`k8s-test-<12hex>`).
- Applies your `kubernetes_manifest` files (CRDs, RBAC, etc.).
- Starts your controller, waits for readiness.
- Calls `os.execve` into the test binary with `KUBECONFIG`, `KUBE_NAMESPACE`,
  `KUBE_API_SERVER`, and `KUBECTL` set.
- Cleans up all processes after the test exits.

## What you can test

- Controllers and operators (reconcile loops, watches, finalizers)
- Admission webhooks (validating, mutating)
- CRD validation (structural schemas, CEL rules)
- RBAC policies (SubjectAccessReview, impersonation)
- Any code that uses `client-go` or `controller-runtime`

## What you cannot test

- Actual pod scheduling or container execution (no kubelet)
- Node lifecycle, kubelet, CNI plugins

---

## Installation

### Bzlmod (`MODULE.bazel`)

```python
bazel_dep(name = "rules_kubernetes", version = "0.1.0")

kubernetes = use_extension("@rules_kubernetes//:extensions.bzl", "kubernetes")

# Use the host-installed kube-apiserver + etcd (auto-detects from PATH):
kubernetes.system(versions = ["1.29"])

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

### Getting the binaries

The easiest way is `setup-envtest` from `sigs.k8s.io/controller-runtime`:

```sh
go install sigs.k8s.io/controller-runtime/tools/setup-envtest@latest
setup-envtest use 1.29 --bin-dir ~/.local/kubebuilder/bin
```

`rules_kubernetes` auto-detects binaries from `$PATH` and common locations
including `~/.local/kubebuilder/bin`.

---

## Quick start

```python
# BUILD.bazel
load("@rules_kubernetes//:defs.bzl",
    "kubernetes_manifest",
    "kubernetes_controller",
    "kubernetes_test",
)

kubernetes_manifest(
    name = "crds",
    srcs = glob(["config/crd/*.yaml"]),
)

kubernetes_controller(
    name              = "my_controller",
    controller_binary = "//cmd/controller",
    manifests         = ":crds",
    ready_probe       = "env_file",  # or "lease" for leader-election controllers
)

kubernetes_test(
    name       = "integration_test",
    srcs       = ["integration_test.sh"],
    controller = ":my_controller",
    size       = "medium",
)
```

```bash
# integration_test.sh
set -euo pipefail

# KUBECONFIG, KUBE_NAMESPACE, KUBE_API_SERVER, and KUBECTL are injected.
"$KUBECTL" get pods --namespace "$KUBE_NAMESPACE" --kubeconfig "$KUBECONFIG"
echo "PASS"
```

---

## Public API

```python
load("@rules_kubernetes//:defs.bzl",
    "kubernetes_manifest",
    "kubernetes_controller",
    "kubernetes_test",
    "kubernetes_server",
    "kubernetes_health_check",
)
```

### `kubernetes_manifest`

Declares YAML files (CRDs, RBAC, Namespaces) to apply before the controller
starts and before the test binary runs.

```python
kubernetes_manifest(
    name = "crds",
    srcs = glob(["config/crd/*.yaml"]),
    # Applied in listed order. Use numeric prefixes for determinism:
    # 001_crd.yaml, 002_rbac.yaml
)
```

Files must have `.yaml` or `.yml` extension. Applied via `kubectl apply -f`.

### `kubernetes_controller`

Declares a controller binary and wires it to a manifest set.

```python
kubernetes_controller(
    name              = "my_controller",
    controller_binary = "//cmd/controller",  # required: any *_binary target
    manifests         = ":crds",             # optional: kubernetes_manifest
    ready_probe       = "lease",             # "lease" (default) or "env_file"
)
```

`ready_probe` values:

| Value | Behaviour |
|---|---|
| `"lease"` | Polls for a leader-election `Lease` object in the test namespace. Use for controllers built with `controller-runtime`'s leader election. |
| `"env_file"` | Polls for `$RULES_K8S_READY_FILE` to be created. The controller writes this file when ready. Use for controllers that do not use leader election. |

### `kubernetes_test`

Runs a test binary against an isolated ephemeral API server.

```python
kubernetes_test(
    name       = "my_test",
    srcs       = ["my_test.sh"],
    controller = ":my_controller",   # optional
    manifests  = ":crds",            # optional (if no controller)
    deps       = [...],              # forwarded to test_rule
    size       = "medium",
    timeout    = None,
    tags       = [],
    test_rule  = go_test,            # optional; default native.sh_test
    **kwargs,
)
```

Expands into two targets:
- `<name>_inner` — the bare test binary (tagged `manual`).
- `<name>` — the launcher wrapper that sets up the API server and exec's the inner binary.

### `kubernetes_server`

Long-running API server for `rules_itest` multi-service integration tests.

```python
kubernetes_server(
    name      = "db_api_server",
    manifests = ":crds",   # optional
)

kubernetes_health_check(
    name   = "db_api_server_health",
    server = ":db_api_server",
)
```

The server writes `$TEST_TMPDIR/<name>.env` atomically when ready. The health
check exits 0 iff that file exists. Source the env file to get connection
details:

```bash
source "$TEST_TMPDIR/db_api_server.env"
"$KUBECTL" cluster-info --kubeconfig "$KUBECONFIG"
```

Env file contents:

```
KUBECONFIG=/tmp/.../kubeconfig
KUBE_NAMESPACE=k8s-test-abc123def456
KUBE_API_SERVER=https://127.0.0.1:54321
KUBECTL=/path/to/kubectl
```

---

## Environment variables

These are set for every `kubernetes_test` invocation and written to the
`kubernetes_server` env file:

| Variable          | Example                   | Description                         |
|-------------------|---------------------------|-------------------------------------|
| `KUBECONFIG`      | `$TEST_TMPDIR/kubeconfig` | Per-test kubeconfig (ephemeral TLS) |
| `KUBE_NAMESPACE`  | `k8s-test-abc123def456`   | Isolated test namespace             |
| `KUBE_API_SERVER` | `https://127.0.0.1:54321` | API server address                  |
| `KUBECTL`         | `/path/to/kubectl`        | Absolute path to kubectl            |

> `kubectl` is **not** on `$PATH` in the Bazel sandbox. Always use `"$KUBECTL"`.

---

## Binary acquisition

Two modes are available per version:

| Mode | MODULE.bazel tag | WORKSPACE function | Description |
|---|---|---|---|
| System | `kubernetes.system()` | `kubernetes_system_dependencies()` | Symlinks host-installed binaries |
| Download | `kubernetes.version()` | `kubernetes_dependencies()` | Downloads envtest tarballs from GitHub |

Download tarballs come from
`https://github.com/kubernetes-sigs/controller-tools/releases` — the same
source as `setup-envtest`.

Supported platforms: `linux_amd64`, `darwin_arm64`, `darwin_amd64`.

---

## Integration with rules_itest

`kubernetes_server` and `kubernetes_health_check` slot directly into
[rules_itest](https://github.com/dzbarsky/rules_itest):

```python
load("@rules_itest//:defs.bzl", "itest_service", "service_test")

kubernetes_server(name = "k8s", manifests = ":crds")
kubernetes_health_check(name = "k8s_health", server = ":k8s")

itest_service(
    name         = "k8s_svc",
    exe          = ":k8s",
    health_check = ":k8s_health",
)

itest_service(
    name = "api_svc",
    exe  = "//cmd/api",
    deps = [":k8s_svc"],   # start k8s before the API server
    http_health_check_address = "http://127.0.0.1:${PORT}/healthz",
    autoassign_port = True,
)

service_test(
    name     = "api_integration_test",
    test     = ":api_test_bin",
    services = [":k8s_svc", ":api_svc"],
)
```

---

## Known limitations

- **No pod execution.** There is no kubelet. Pods never reach `Running` without
  a simulator like [kwok](https://kwok.sigs.k8s.io) (planned for Phase 2).
- **`~3–6 s` overhead per test** for etcd + apiserver startup.
- **openssl required** for TLS certificate generation (present on all supported
  platforms).
- **Windows not supported** (no pre-built binary source; PRs welcome).
- **darwin tarball SHA-256 checksums are placeholders** in `extensions.bzl`.
  Pin real values before using `kubernetes.version()` on macOS.
- **Target name uniqueness** — two `kubernetes_server` targets with the same
  local name in different packages write to the same `$TEST_TMPDIR/<name>.env`.
