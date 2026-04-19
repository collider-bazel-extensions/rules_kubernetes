"""Toolchain type and registration helpers for rules_kubernetes."""

load("//private:binary.bzl", "KubernetesBinaryInfo")

# The toolchain type URL.  Referenced in BUILD files and by rules that
# declare toolchain dependencies.
K8S_TOOLCHAIN_TYPE = "@rules_kubernetes//toolchain:kubernetes"

def _kubernetes_toolchain_impl(ctx):
    binary_info = ctx.attr.kubernetes_binary[KubernetesBinaryInfo]
    toolchain_info = platform_common.ToolchainInfo(
        kubernetes_binary_info = binary_info,
    )
    return [toolchain_info]

kubernetes_toolchain = rule(
    doc = "Declares a Kubernetes toolchain carrying kube-apiserver, etcd, and kubectl.",
    implementation = _kubernetes_toolchain_impl,
    attrs = {
        "kubernetes_binary": attr.label(
            doc = "A kubernetes_binary target.",
            mandatory = True,
            providers = [KubernetesBinaryInfo],
        ),
    },
)

def register_kubernetes_toolchains():
    """Register the default rules_kubernetes toolchains.

    Call this from WORKSPACE after loading repositories.bzl.
    Not required when using Bzlmod — toolchains are registered automatically
    via the module extension in extensions.bzl.
    """
    native.register_toolchains("@rules_kubernetes//:k8s_toolchain")
