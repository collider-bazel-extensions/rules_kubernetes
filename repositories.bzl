"""WORKSPACE equivalents of the Bzlmod extensions in extensions.bzl.

Use these in projects that have not yet migrated to Bzlmod.

Example WORKSPACE usage:

    load("@rules_kubernetes//:repositories.bzl", "kubernetes_system_dependencies")

    # Auto-detect kube-apiserver + etcd from PATH / common locations:
    kubernetes_system_dependencies(versions = ["1.29"])

    # Or specify the directory explicitly:
    # kubernetes_system_dependencies(versions = ["1.29"], bin_dir = "/usr/local/kubebuilder/bin")
"""

load("//:extensions.bzl",
    "k8s_binary_repo",
    "k8s_system_binary_repo",
    "PLATFORMS",
)

def kubernetes_system_dependencies(versions, bin_dir = ""):
    """Symlink host-installed kube-apiserver + etcd + kubectl into external repos.

    Args:
        versions: list of Kubernetes minor version strings, e.g. ["1.29"].
        bin_dir:  directory containing the binaries. Omit to auto-detect.
    """
    for version in versions:
        for platform in PLATFORMS:
            repo_name = "k8s_{}_{}".format(version.replace(".", "_"), platform)
            k8s_system_binary_repo(
                name     = repo_name,
                version  = version,
                bin_dir  = bin_dir,
                platform = platform,
            )

def kubernetes_dependencies(versions):
    """Download kube-apiserver + etcd + kubectl tarballs from GCS.

    Args:
        versions: list of Kubernetes minor version strings, e.g. ["1.29"].
    """
    for version in versions:
        for platform in PLATFORMS:
            repo_name = "k8s_{}_{}".format(version.replace(".", "_"), platform)
            k8s_binary_repo(
                name     = repo_name,
                version  = version,
                platform = platform,
            )
