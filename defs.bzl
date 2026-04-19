"""Public API for rules_kubernetes.

Load all public symbols from this file:

    load("@rules_kubernetes//:defs.bzl",
        "kubernetes_manifest",
        "kubernetes_controller",
        "kubernetes_test",
        "kubernetes_server",
        "kubernetes_health_check",
    )
"""

load("//private:binary.bzl",
    _KubernetesBinaryInfo = "KubernetesBinaryInfo",
)
load("//private:manifest.bzl",
    _KubernetesManifestInfo = "KubernetesManifestInfo",
    _kubernetes_manifest    = "kubernetes_manifest",
)
load("//private:controller.bzl",
    _KubernetesControllerInfo = "KubernetesControllerInfo",
    _kubernetes_controller    = "kubernetes_controller",
)
load("//private:test.bzl",
    _kubernetes_test = "kubernetes_test",
)
load("//private:server.bzl",
    _kubernetes_server       = "kubernetes_server",
    _kubernetes_health_check = "kubernetes_health_check",
)

# Re-export providers.
KubernetesBinaryInfo     = _KubernetesBinaryInfo
KubernetesManifestInfo   = _KubernetesManifestInfo
KubernetesControllerInfo = _KubernetesControllerInfo

# Re-export rules and macros.
kubernetes_manifest    = _kubernetes_manifest
kubernetes_controller  = _kubernetes_controller
kubernetes_test        = _kubernetes_test
kubernetes_server      = _kubernetes_server
kubernetes_health_check = _kubernetes_health_check
