# rules_kubernetes — Design Document

## Goals

`rules_kubernetes` provides hermetic, parallel-safe Kubernetes API servers for
Bazel test targets. The design is driven by three constraints:

1. **No Docker, no root.** The package must work in standard CI sandboxes where
   neither Docker nor elevated privileges are available. This rules out kind and
   vanilla k3s and scopes the target to `kube-apiserver` + `etcd`.
2. **Full `--jobs` parallelism.** Each test must own an independent API server
   on a unique port with a UUID-based namespace — no shared state between tests.
3. **Zero test-code changes.** Tests receive a standard `KUBECONFIG` path and
   `KUBE_NAMESPACE` name; they connect as if to any Kubernetes cluster.

---

## Scope

`rules_kubernetes` targets **controller and operator authors** — the dominant
Bazel+Kubernetes use case. Tests exercise code that talks to the Kubernetes API:
custom controllers, admission webhooks, CRD validation, RBAC, operator
reconciliation loops.

It does **not** target full end-to-end cluster tests where actual containers must
run. That workload requires a kubelet and a container runtime; it is better
served by dedicated e2e tools (Chainsaw, kuttl, Testkube) that assume a
pre-existing cluster.

### What you can test

- Controllers and operators (reconcile loops, watches, finalizers)
- Admission webhooks (validating, mutating)
- CRD validation (structural schemas, CEL rules)
- RBAC policies (impersonation, SubjectAccessReview)
- Any code that calls `client-go`, `controller-runtime`, or `k8s.io/client-go`

### What you cannot test

- Pod scheduling or actual container execution
- Node lifecycle, kubelet, CNI plugins
- Services routing real traffic to pods
- Anything that requires a running kubelet

---

## High-level architecture

```
MODULE.bazel / WORKSPACE
        │
        ▼
  extensions.bzl / repositories.bzl     ← fetch or symlink kube-apiserver + etcd
        │
        ▼
  kubernetes_binary  (private/binary.bzl)   ← platform-agnostic binary target
        │                                       carries kube-apiserver + etcd paths
        ▼
  kubernetes_manifest  (private/manifest.bzl)  ← validated YAML manifests (CRDs, RBAC)
        │
        ▼
  kubernetes_controller  (private/controller.bzl)  ← controller binary + manifest
        │
        ├────────────────────────────────────────────────┐
        ▼                                                ▼
  kubernetes_test macro  (private/test.bzl)    kubernetes_server rule  (private/server.bzl)
    ├── <name>_inner — real test binary          long-running server binary
    └── <name>       — _k8s_launcher_test               │
              │                                         ▼
              └──────────────┐             kubernetes_health_check (private/server.bzl)
                             │               file-exists health probe
                             ▼
                        launcher.py
                  ┌──────────┴──────────┐
       RULES_K8S_MODE=test   RULES_K8S_MODE=server
                  │                     │
          _start_apiserver()    _start_apiserver()
                  │                     │
        _start_controller()    write kubeconfig + env file
                  │                     │
          os.execve(test)       signal.pause()
                                SIGTERM → stop
```

---

## Provider chain

```
KubernetesBinaryInfo          paths to kube-apiserver and etcd; all_files depset
  │
  └─► KubernetesManifestInfo  YAML files to apply (CRDs, RBAC, etc.);
        │                     ordered depset; carries KubernetesBinaryInfo
        │
        └─► KubernetesControllerInfo   controller executable + runfiles;
                                       carries KubernetesManifestInfo
```

`kubernetes_test` and `kubernetes_server` both accept a `controller` label and
receive the full binary+manifest chain transitively. `controller` is optional —
a test that only needs the API server (e.g., to test a client library) can omit
it and pass the binary directly.

---

## Binary acquisition

Two binaries are required: `kube-apiserver` and `etcd`. Both are acquired via
the same two-mode interface as rules_pg and rules_temporal.

### Downloaded tarballs (`kubernetes.version()`)

`_k8s_binary_repo` calls `rctx.download_and_extract` to fetch versioned
`kube-apiserver` and `etcd` binaries. The canonical download source is the
`envtest-bins` tarballs published by `kubernetes-sigs/controller-tools` at:

```
https://github.com/kubernetes-sigs/controller-tools/releases/download/
    envtest-v<version>/envtest-v<version>-<os>-<arch>.tar.gz
```

The tarball extracts to `controller-tools/envtest/` — `strip_prefix` is set to
`"controller-tools/envtest"` so the binaries (`kube-apiserver`, `etcd`,
`kubectl`) land at the repo root.

SHA-256 checksums are stored in `_K8S_VERSIONS` in `extensions.bzl`.

### System binaries (`kubernetes.system()`)

`_k8s_system_binary_repo` symlinks host-installed binaries into an external
repo. Auto-detection at `bazel fetch` time:

1. `command -v kube-apiserver` — PATH lookup.
2. Common locations: `/usr/local/kubebuilder/bin`, `/usr/local/bin`,
   `/usr/bin`, and `$HOME/.local/kubebuilder/bin` (read from the repository
   rule environment at fetch time).

If either binary cannot be found, the build fails immediately with a clear error
and a suggested install command (`setup-envtest use <version>`).

Both modes produce a repo named `k8s_<version>_<platform>` (e.g.,
`k8s_1_29_linux_amd64`) exposing `kube-apiserver` and `etcd` as runfiles.

---

## TLS bootstrap

`kube-apiserver` requires TLS. The launcher generates ephemeral credentials at
test runtime — no pre-baked certs in the repository:

```
_bootstrap_tls(test_tmpdir)
  ├── generate CA key + self-signed cert           (ca.key, ca.crt)
  ├── generate server key + CSR                    (server.key, server.csr)
  ├── sign server cert with CA                     (server.crt)
  ├── generate client key + CSR                    (client.key, client.csr)
  └── sign client cert with CA                     (client.crt)
```

All files written to `$TEST_TMPDIR/pki/`. The launcher uses `openssl`
subprocess calls. The generated kubeconfig references these paths and is
written to `$TEST_TMPDIR/kubeconfig`.

`kube-apiserver` is started with:

```
--tls-cert-file     $TEST_TMPDIR/pki/server.crt
--tls-private-key-file $TEST_TMPDIR/pki/server.key
--client-ca-file    $TEST_TMPDIR/pki/ca.crt
```

The client cert is written into the kubeconfig as `client-certificate` /
`client-key` with the CA as `certificate-authority`.

---

## `kubernetes_manifest` rule

The `postgres_schema` analogue for Kubernetes. Declares YAML manifest files
(CRDs, RBAC, Namespaces, ConfigMaps) to apply to the API server before the
controller starts and before the test binary runs.

```python
kubernetes_manifest(
    name = "my_crds",
    srcs = glob(["config/crd/*.yaml"]),
    # Files applied in listed order via `kubectl apply -f`.
    # Use numeric prefixes for deterministic ordering: 001_crd.yaml, 002_rbac.yaml.
)
```

The launcher applies manifests in order via `kubectl apply -f <file>` after the
API server is ready and before starting the controller. Failures surface
immediately with the full `kubectl` output printed.

### Analysis-time validation

`kubernetes_manifest` validates at analysis time:
- `srcs` must not be empty.
- All files must have a `.yaml` or `.yml` extension.

Runtime YAML parse errors surface from `kubectl apply` output.

---

## `kubernetes_controller` rule

Declares a controller binary and links it to a manifest set. Produces a
`KubernetesControllerInfo` provider.

```python
kubernetes_controller(
    name              = "my_controller",
    controller_binary = "//cmd/controller",   # required: a *_binary target
    manifests         = ":my_crds",           # optional: kubernetes_manifest
)
```

Analysis-time validation:
- `controller_binary` must be present (label, not a string).

The controller is started by the launcher after manifests are applied and before
the worker-ready poll. It inherits `KUBECONFIG`, `KUBE_NAMESPACE`, and any
extra env vars declared in the `kubernetes_test` target.

---

## `kubernetes_test` macro

Expands into two targets, identical in structure to `temporal_test`:

- **`<name>_inner`** — the bare test binary. Tagged `manual`.
- **`<name>`** — a `_k8s_launcher_test` rule that wraps the inner binary.

### Launcher lifecycle (test mode)

```
read K8S_MANIFEST (JSON)
  ↓
resolve runfile paths
  ↓
ensure execute bits on kube-apiserver, etcd, kubectl, controller binary
  ↓
allocate TCP ports for kube-apiserver (API) and etcd (peer + client)
  ↓
generate UUID namespace  (k8s-test-<12-hex>)
  ↓
_bootstrap_tls()  → $TEST_TMPDIR/pki/ + $TEST_TMPDIR/kubeconfig
  ↓
start etcd  [retry on port conflict, up to 5 attempts]
  ↓
_wait_etcd_ready: TCP open + etcd health endpoint (15 s timeout)
  ↓
start kube-apiserver  [retry on port conflict]
  ↓
_wait_apiserver_ready: TCP open + /readyz HTTP check (30 s timeout)
  ↓
kubectl apply manifests in order (if kubernetes_manifest provided)
  ↓
kubectl create namespace <uuid-namespace>
  ↓
start controller subprocess (KUBECONFIG + KUBE_NAMESPACE set)  [if controller provided]
  ↓
_wait_controller_ready: poll until controller's leader-election lease appears
  or configurable readiness probe passes
  ↓
os.execve(test_binary, env={KUBECONFIG, KUBE_NAMESPACE, KUBE_API_SERVER})
```

Cleanup is handled by `atexit` handlers for `etcd_proc`, `apiserver_proc`, and
`controller_proc`. Bazel removes `$TEST_TMPDIR` after each test run.

### Environment variables injected

| Variable           | Example value                    | Description                        |
|--------------------|----------------------------------|------------------------------------|
| `KUBECONFIG`       | `$TEST_TMPDIR/kubeconfig`        | Path to per-test kubeconfig        |
| `KUBE_NAMESPACE`   | `k8s-test-abc123def456`          | Isolated per-test namespace        |
| `KUBE_API_SERVER`  | `https://127.0.0.1:54321`        | API server address                 |
| `KUBECTL`          | `/path/to/kubectl`               | Absolute path to kubectl binary    |

`KUBECTL` is set because `kubectl` is not on `$PATH` in the Bazel sandbox;
test scripts must use `"$KUBECTL"` rather than relying on PATH.

---

## Port allocation

Three ports are needed per test: one for `kube-apiserver`, two for `etcd`
(client and peer). All three are allocated via `socket.bind(('127.0.0.1', 0))`
before any process starts. Sockets are closed just before the processes start.
Up to five retries handle the rare TOCTOU race; only port-binding conflicts
trigger a retry.

---

## Namespace isolation

Each `kubernetes_test` creates a UUID namespace (`k8s-test-<12 hex chars>`) at
runtime via `kubectl create namespace`. This guarantees:

- No resource bleeds between tests even with identical resource names.
- Tests are safe to run in parallel with `--jobs`.

The namespace name is injected as `KUBE_NAMESPACE`. Tests should scope all
resource creation to this namespace.

---

## `kubernetes_server` rule

Long-running API server for use as an `itest_service` in `rules_itest`. Uses
the same launcher with `RULES_K8S_MODE=server`. In server mode:

```
allocate ports → _bootstrap_tls → start etcd → start kube-apiserver
  ↓
kubectl apply manifests (if provided)
  ↓
kubectl create namespace <uuid>
  ↓
write $TEST_TMPDIR/<name>.env atomically   ← readiness signal
  ↓
install SIGTERM + SIGINT handlers
  ↓
signal.pause()
```

### Server env file format

```
KUBECONFIG=/tmp/.../kubeconfig
KUBE_NAMESPACE=k8s-test-abc123def456
KUBE_API_SERVER=https://127.0.0.1:54321
KUBECTL=/path/to/kubectl
```

`KUBECTL` is the absolute path to the kubectl binary used by the server. Tests
that source this env file can use `"$KUBECTL"` directly without kubectl being
in `$PATH`.

### `kubernetes_health_check`

Exits 0 iff `$TEST_TMPDIR/<server-name>.env` exists. Identical pattern to
`temporal_health_check` and `pg_health_check`.

---

## `kubernetes_test` vs `kubernetes_server` — when to use which

| Scenario | Use |
|---|---|
| Unit / integration test for a single controller | `kubernetes_test` |
| Multi-service test (HTTP API + controller + K8s) | `kubernetes_server` + `itest_service` |
| `bazel test` with per-target isolation | `kubernetes_test` |
| Shared API server across multiple services | `kubernetes_server` |

---

## Analysis-time validation

`kubernetes_controller` validates at Bazel analysis time:
- `controller_binary` is a label (not a string).

`kubernetes_manifest` validates at Bazel analysis time:
- `srcs` is non-empty.
- All files have `.yaml` or `.yml` extension.

Failures surface as `bazel build` errors, never as flaky test failures.

---

## Combined test manifest

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

---

## Phase 2 — kwok integration

A `kubernetes_node_sim` optional extension adds `kwok` as a fourth binary,
enabling simulated node and pod lifecycle:

```python
kubernetes_node_sim(
    name    = "my_nodes",
    server  = ":my_apiserver",   # kubernetes_server or kubernetes_test worker
    count   = 10,                # number of simulated nodes
)
```

The launcher starts `kwok` after `kube-apiserver` is ready. Tests that need
to observe pod scheduling or node conditions wire in this extension.

This is intentionally deferred to Phase 2 — it adds a third binary and a more
complex readiness protocol. The base rules are useful without it.

---

## Known limitations and non-goals

- **No actual pod execution.** There is no kubelet. Pods never transition to
  `Running` unless kwok (Phase 2) is used to simulate the transition.
- **`kubernetes_test` stays independent** of `kubernetes_server`. The tight
  server+controller+exec coupling is its key value.
- **Target name collision.** Two `kubernetes_server` targets with the same local
  name in different packages write to the same `$TEST_TMPDIR/<name>.env`. Use
  unique target names within a test run.
- **TLS cert generation.** The launcher requires `openssl` in `PATH`. It is
  present on all supported Linux and macOS platforms.
- **Windows not supported.** No pre-built binary source; PRs welcome.
- **darwin tarball checksums are placeholders** until real SHA-256 values are
  pinned in `extensions.bzl`.
- **Controller readiness** is heuristic: the launcher polls for a
  leader-election lease by default. Controllers that do not use leader election
  need a custom readiness probe (configurable via the `ready_probe` attribute
  of `kubernetes_controller`).
