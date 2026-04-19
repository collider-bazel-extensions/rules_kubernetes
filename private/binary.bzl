"""KubernetesBinaryInfo provider and kubernetes_binary rule."""

KubernetesBinaryInfo = provider(
    doc = "Paths to the kube-apiserver, etcd, and kubectl binaries.",
    fields = {
        "kube_apiserver": "File: kube-apiserver binary",
        "etcd":           "File: etcd binary",
        "kubectl":        "File: kubectl binary",
        "version":        "string: Kubernetes minor version (e.g. '1.29')",
        "all_files":      "depset: all three binaries (for runfiles)",
    },
)

def _kubernetes_binary_files_impl(ctx):
    """Find kube-apiserver, etcd, and kubectl in a flat list of binary files.

    When bins is empty the target is a non-host-platform stub repo; return an
    empty provider rather than failing — the select() in BUILD.bazel will never
    choose this target on the wrong platform.
    """
    bins = {f.basename: f for f in ctx.files.bins}

    # Empty bins = stub repo for a non-host platform.  Return a harmless stub.
    if not bins:
        return [
            KubernetesBinaryInfo(
                kube_apiserver = None,
                etcd           = None,
                kubectl        = None,
                version        = ctx.attr.version,
                all_files      = depset([]),
            ),
            DefaultInfo(files = depset([])),
        ]

    kube_apiserver = bins.get("kube-apiserver")
    etcd           = bins.get("etcd")
    kubectl        = bins.get("kubectl")

    for name, f in [("kube-apiserver", kube_apiserver), ("etcd", etcd), ("kubectl", kubectl)]:
        if f == None:
            fail("kubernetes_binary_files: '{}' not found in bins. Available: {}".format(
                name, sorted(bins.keys())))

    return [
        KubernetesBinaryInfo(
            kube_apiserver = kube_apiserver,
            etcd           = etcd,
            kubectl        = kubectl,
            version        = ctx.attr.version,
            all_files      = depset([kube_apiserver, etcd, kubectl]),
        ),
        DefaultInfo(files = depset([kube_apiserver, etcd, kubectl])),
    ]

kubernetes_binary_files = rule(
    doc = """\
Internal rule injected into each binary repo's BUILD file.
Finds kube-apiserver, etcd, and kubectl by basename and exposes them
via KubernetesBinaryInfo.
""",
    implementation = _kubernetes_binary_files_impl,
    attrs = {
        "bins":    attr.label_list(allow_files = True, mandatory = True),
        "version": attr.string(mandatory = True),
    },
)

def _kubernetes_binary_impl(ctx):
    """Pass-through: wraps a platform-selected kubernetes_binary_files target."""
    info = ctx.attr.binary[KubernetesBinaryInfo]
    return [
        info,
        DefaultInfo(files = info.all_files),
    ]

kubernetes_binary = rule(
    doc = """\
Platform-agnostic Kubernetes binary target. Wraps a select() over
platform-specific kubernetes_binary_files targets and re-exposes
KubernetesBinaryInfo so consuming rules see a single label regardless
of platform.
""",
    implementation = _kubernetes_binary_impl,
    attrs = {
        "binary": attr.label(
            doc       = "Platform-selected kubernetes_binary_files target.",
            mandatory = True,
            providers = [KubernetesBinaryInfo],
        ),
    },
)
