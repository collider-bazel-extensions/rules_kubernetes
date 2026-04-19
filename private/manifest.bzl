"""KubernetesManifestInfo provider and kubernetes_manifest rule."""

KubernetesManifestInfo = provider(
    doc = "Ordered set of YAML manifest files to apply to the API server.",
    fields = {
        "manifest_files": "depset: YAML/YML files in application order",
    },
)

def _kubernetes_manifest_impl(ctx):
    if not ctx.files.srcs:
        fail("kubernetes_manifest: 'srcs' must not be empty")

    for src in ctx.files.srcs:
        if not (src.basename.endswith(".yaml") or src.basename.endswith(".yml")):
            fail("kubernetes_manifest: all srcs must be .yaml or .yml files, got: " + src.path)

    return [
        KubernetesManifestInfo(
            manifest_files = depset(ctx.files.srcs),
        ),
        DefaultInfo(files = depset(ctx.files.srcs)),
    ]

kubernetes_manifest = rule(
    doc = """\
Declares a set of YAML manifest files (CRDs, ClusterRoles, etc.) to apply to
the Kubernetes API server before a test runs.  Files are applied in the order
listed via 'kubectl apply -f'.  Use numeric prefixes for deterministic ordering:
001_crd.yaml, 002_rbac.yaml.

Validated at analysis time:
  - srcs must be non-empty.
  - All files must have a .yaml or .yml extension.
""",
    implementation = _kubernetes_manifest_impl,
    attrs = {
        "srcs": attr.label_list(
            doc       = "YAML manifest files to apply, in order.",
            allow_files = [".yaml", ".yml"],
            mandatory   = True,
        ),
    },
)
