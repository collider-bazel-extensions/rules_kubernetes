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
bazel_dep(name = "rules_kubernetes", version = "0.3.0")

kubernetes = use_extension("@rules_kubernetes//:extensions.bzl", "kubernetes")

# v0.3+: kubernetes.version() fetches kube-apiserver + etcd + kubectl
# hermetically from controller-tools' envtest releases. No host
# install required.
kubernetes.version(versions = ["1.29"])

use_repo(kubernetes,
    "k8s_1_29_linux_amd64",
    "k8s_1_29_darwin_arm64",
    "k8s_1_29_darwin_amd64",
)
```

Use `kubernetes.system(versions = [...])` instead if you want to reuse host-installed binaries (e.g. installed via `setup-envtest`). Both modes coexist per minor version; rules_kubernetes's own `MODULE.bazel` uses `kubernetes.version()` so CI runs on bare `ubuntu-latest`.

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

## Examples

### API-server-only test (no controller)

Tests for client libraries, admission webhooks, or any code that only needs
the API server — no controller binary required.

```python
# BUILD.bazel
kubernetes_test(
    name = "client_test",
    srcs = ["client_test.sh"],
    size = "medium",
)
```

```bash
# client_test.sh
set -euo pipefail
require_env() { [[ -n "${!1:-}" ]] || { echo "ERROR: \$$1 not set" >&2; exit 1; }; }
require_env KUBECONFIG
require_env KUBE_NAMESPACE
require_env KUBECTL

# Create a resource and verify it round-trips.
"$KUBECTL" create configmap test-cm \
    --namespace "$KUBE_NAMESPACE" \
    --kubeconfig "$KUBECONFIG" \
    --from-literal=key=hello

VAL=$("$KUBECTL" get configmap test-cm \
    --namespace "$KUBE_NAMESPACE" \
    --kubeconfig "$KUBECONFIG" \
    -o jsonpath='{.data.key}')
[[ "$VAL" == "hello" ]] || { echo "FAIL: got $VAL" >&2; exit 1; }
echo "PASS"
```

---

### CRD + RBAC + controller (leader-election)

A typical controller-runtime operator that uses leader election.

```python
# BUILD.bazel
load("@rules_kubernetes//:defs.bzl", "kubernetes_manifest", "kubernetes_controller", "kubernetes_test")

kubernetes_manifest(
    name = "crds_and_rbac",
    srcs = glob(["config/crd/*.yaml"]) + glob(["config/rbac/*.yaml"]),
    # Applied in listed order — CRDs first, then RBAC.
)

kubernetes_controller(
    name              = "operator",
    controller_binary = "//cmd/operator",
    manifests         = ":crds_and_rbac",
    ready_probe       = "lease",   # controller-runtime leader election
)

kubernetes_test(
    name       = "operator_test",
    srcs       = ["operator_test.sh"],
    controller = ":operator",
    size       = "medium",
)
```

```bash
# operator_test.sh — the operator is fully ready before this runs.
set -euo pipefail
require_env() { [[ -n "${!1:-}" ]] || { echo "ERROR: \$$1 not set" >&2; exit 1; }; }
require_env KUBECONFIG; require_env KUBE_NAMESPACE; require_env KUBECTL

# Apply a custom resource and wait for the operator to reconcile it.
"$KUBECTL" apply -f - --kubeconfig "$KUBECONFIG" <<EOF
apiVersion: mygroup.example.com/v1
kind: MyResource
metadata:
  name: test-resource
  namespace: $KUBE_NAMESPACE
spec:
  replicas: 1
EOF

# Wait for the operator to set status.ready=true.
for i in $(seq 1 30); do
    ready=$("$KUBECTL" get myresource test-resource \
        --namespace "$KUBE_NAMESPACE" \
        --kubeconfig "$KUBECONFIG" \
        -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
    [[ "$ready" == "true" ]] && break
    sleep 1
done

[[ "$ready" == "true" ]] || { echo "FAIL: resource never became ready" >&2; exit 1; }
echo "PASS"
```

---

### Go test with `go_test`

```python
# BUILD.bazel
load("@io_bazel_rules_go//go:def.bzl", "go_test")
load("@rules_kubernetes//:defs.bzl", "kubernetes_manifest", "kubernetes_controller", "kubernetes_test")

kubernetes_manifest(
    name = "crds",
    srcs = glob(["testdata/crd/*.yaml"]),
)

kubernetes_controller(
    name              = "controller",
    controller_binary = "//cmd/controller",
    manifests         = ":crds",
    ready_probe       = "env_file",
)

kubernetes_test(
    name       = "reconciler_go_test",
    srcs       = ["reconciler_test.go"],
    deps       = [
        "//internal/controller",
        "@io_k8s_client_go//kubernetes:go_default_library",
    ],
    controller = ":controller",
    test_rule  = go_test,
    size       = "medium",
)
```

```go
// reconciler_test.go
package controller_test

import (
    "os"
    "testing"

    "k8s.io/client-go/kubernetes"
    "k8s.io/client-go/tools/clientcmd"
)

func TestReconciler(t *testing.T) {
    kubeconfig := os.Getenv("KUBECONFIG")
    namespace  := os.Getenv("KUBE_NAMESPACE")

    cfg, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
    if err != nil {
        t.Fatalf("build config: %v", err)
    }
    client, err := kubernetes.NewForConfig(cfg)
    if err != nil {
        t.Fatalf("new client: %v", err)
    }

    // Test runs against a real API server in namespace.
    _ = client
    _ = namespace
}
```

---

### Shared server for multi-service integration tests (`rules_itest`)

```python
# BUILD.bazel
load("@rules_kubernetes//:defs.bzl", "kubernetes_manifest", "kubernetes_server", "kubernetes_health_check")
load("@rules_itest//:defs.bzl", "itest_service", "service_test")

kubernetes_manifest(
    name = "crds",
    srcs = glob(["config/crd/*.yaml"]),
)

kubernetes_server(
    name      = "k8s",
    manifests = ":crds",
)

kubernetes_health_check(
    name   = "k8s_health",
    server = ":k8s",
)

itest_service(
    name         = "k8s_svc",
    exe          = ":k8s",
    health_check = ":k8s_health",
)

itest_service(
    name = "api_svc",
    exe  = "//cmd/api",
    deps = [":k8s_svc"],
    http_health_check_address = "http://127.0.0.1:${PORT}/healthz",
    autoassign_port = True,
)

service_test(
    name     = "api_integration_test",
    test     = ":api_test_bin",
    services = [":k8s_svc", ":api_svc"],
)
```

```bash
# api_test.sh — both services are running before this executes.
set -euo pipefail

# Source the kubernetes_server env file to get KUBECONFIG and KUBECTL.
source "$TEST_TMPDIR/k8s.env"

API_PORT=$(echo "$ASSIGNED_PORTS" | python3 -c "
import json, sys
print(json.load(sys.stdin)['//myapp:api_svc'])
")

# Verify the API can reach the database (which talks to the k8s cluster).
curl -sf "http://127.0.0.1:${API_PORT}/healthz" | grep -q '"status":"ok"'
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
- **Target name uniqueness** — two `kubernetes_server` targets with the same
  local name in different packages write to the same `$TEST_TMPDIR/<name>.env`.
