"""Bzlmod module extension: fetch or symlink kube-apiserver + etcd + kubectl."""

# Kubernetes versions and their envtest-bins tarball SHA-256 checksums.
# Tarballs from: https://storage.googleapis.com/kubebuilder-tools/
# linux_amd64 checksums are real; darwin values are placeholders.
_K8S_VERSIONS = {
    "1.29": {
        "linux_amd64": {
            "url":          "https://github.com/kubernetes-sigs/controller-tools/releases/download/envtest-v1.29.0/envtest-v1.29.0-linux-amd64.tar.gz",
            "sha256":       "3757f353a7e60e726c60ea461b91a660fc909e80b687eecee7a7f7a606e68da5",
            "strip_prefix": "controller-tools/envtest",
        },
        "darwin_arm64": {
            "url":          "https://github.com/kubernetes-sigs/controller-tools/releases/download/envtest-v1.29.0/envtest-v1.29.0-darwin-arm64.tar.gz",
            "sha256":       "",  # placeholder: run tools/update_checksums.sh
            "strip_prefix": "controller-tools/envtest",
        },
        "darwin_amd64": {
            "url":          "https://github.com/kubernetes-sigs/controller-tools/releases/download/envtest-v1.29.0/envtest-v1.29.0-darwin-amd64.tar.gz",
            "sha256":       "",  # placeholder: run tools/update_checksums.sh
            "strip_prefix": "controller-tools/envtest",
        },
    },
}

PLATFORMS = ["linux_amd64", "darwin_arm64", "darwin_amd64"]

# BUILD file injected into every binary repo.
# The tarball extracts to kubebuilder/bin/; we use strip_prefix="kubebuilder"
# so the bin/ directory sits at the repo root.
_BINARY_REPO_BUILD = """\
filegroup(
    name = "kube_apiserver",
    srcs = ["kube-apiserver"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "etcd_bin",
    srcs = glob(["etcd"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "kubectl_bin",
    srcs = glob(["kubectl"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "all_files",
    srcs = [":kube_apiserver", ":etcd_bin", ":kubectl_bin"],
    visibility = ["//visibility:public"],
)
"""

def _k8s_binary_repo_impl(rctx):
    version  = rctx.attr.version
    platform = rctx.attr.platform

    if version not in _K8S_VERSIONS:
        fail("Unsupported Kubernetes version: {}. Supported: {}".format(
            version, ", ".join(_K8S_VERSIONS.keys())))

    info = _K8S_VERSIONS[version].get(platform)
    if not info:
        fail("No tarball for kubernetes {} on {}".format(version, platform))

    sha256 = info["sha256"]
    if not sha256:
        fail(
            "SHA-256 checksum for kubernetes {} on {} is a placeholder. " +
            "Run tools/update_checksums.sh to pin real values before using " +
            "kubernetes.version() on this platform.".format(version, platform),
        )

    rctx.download_and_extract(
        url        = info["url"],
        sha256     = sha256,
        stripPrefix = "kubebuilder",
    )
    rctx.file("BUILD.bazel", _BINARY_REPO_BUILD)

k8s_binary_repo = repository_rule(
    implementation = _k8s_binary_repo_impl,
    attrs = {
        "version":  attr.string(mandatory = True),
        "platform": attr.string(mandatory = True),
    },
)

# Common paths to probe when auto-detecting binaries.
_SEARCH_PATHS = [
    "/usr/local/kubebuilder/bin",
    "/usr/local/bin",
    "/usr/bin",
]

_PLATFORM_OS_MAP = {
    "linux_amd64":  "linux",
    "darwin_arm64": "mac os x",
    "darwin_amd64": "mac os x",
}

_STUB_BUILD = """\
# Stub repo for a non-host platform.  This repo is never selected at build time
# because the platform config_setting for this platform won't match the host.
filegroup(name = "kube_apiserver", srcs = [], visibility = ["//visibility:public"])
filegroup(name = "etcd_bin",       srcs = [], visibility = ["//visibility:public"])
filegroup(name = "kubectl_bin",    srcs = [], visibility = ["//visibility:public"])
filegroup(name = "all_files",      srcs = [], visibility = ["//visibility:public"])
"""

def _k8s_system_binary_repo_impl(rctx):
    version  = rctx.attr.version
    bin_dir  = rctx.attr.bin_dir
    platform = rctx.attr.platform

    # If this repo's platform doesn't match the host OS, emit a stub.
    # The select() in BUILD.bazel will never pick this repo on the wrong host.
    expected_os = _PLATFORM_OS_MAP.get(platform, "")
    if expected_os and rctx.os.name.lower() != expected_os:
        rctx.file("BUILD.bazel", _STUB_BUILD)
        return

    # Auto-detect kube-apiserver location.
    if not bin_dir:
        result = rctx.execute(["sh", "-c", "command -v kube-apiserver 2>/dev/null || true"])
        if result.return_code == 0 and result.stdout.strip():
            bin_dir = result.stdout.strip().rsplit("/", 1)[0]

    if not bin_dir:
        home = rctx.os.environ.get("HOME", "")
        search_paths = _SEARCH_PATHS + (
            [home + "/.local/kubebuilder/bin"] if home else []
        )
        for path in search_paths:
            result = rctx.execute(["test", "-f", path + "/kube-apiserver"])
            if result.return_code == 0:
                bin_dir = path
                break

    if not bin_dir:
        fail(
            "kube-apiserver not found in PATH or common locations.\n" +
            "Install with: setup-envtest use {}\n".format(version) +
            "Or pass bin_dir explicitly: kubernetes.system(versions=[...], bin_dir='/path/to/bin')",
        )

    # Verify kube-apiserver and etcd are present.
    for binary in ["kube-apiserver", "etcd"]:
        result = rctx.execute(["test", "-f", bin_dir + "/" + binary])
        if result.return_code != 0:
            fail("{} not found in {}. Install with: setup-envtest use {}".format(
                binary, bin_dir, version))

    # Locate kubectl: prefer bin_dir, fall back to PATH.
    kubectl_path = ""
    if rctx.execute(["test", "-f", bin_dir + "/kubectl"]).return_code == 0:
        kubectl_path = bin_dir + "/kubectl"
    else:
        result = rctx.execute(["sh", "-c", "command -v kubectl 2>/dev/null || true"])
        if result.return_code == 0 and result.stdout.strip():
            kubectl_path = result.stdout.strip()
        else:
            for path in _SEARCH_PATHS:
                if rctx.execute(["test", "-f", path + "/kubectl"]).return_code == 0:
                    kubectl_path = path + "/kubectl"
                    break

    if not kubectl_path:
        fail(
            "kubectl not found. Install it or add it to PATH.\n" +
            "Hint: if kube-apiserver is at {}, kubectl should be nearby.".format(bin_dir),
        )

    rctx.symlink(bin_dir + "/kube-apiserver", "kube-apiserver")
    rctx.symlink(bin_dir + "/etcd",           "etcd")
    rctx.symlink(kubectl_path,                "kubectl")
    rctx.file("BUILD.bazel", _BINARY_REPO_BUILD)

k8s_system_binary_repo = repository_rule(
    implementation = _k8s_system_binary_repo_impl,
    attrs = {
        "version":  attr.string(mandatory = True),
        "bin_dir":  attr.string(default = ""),
        "platform": attr.string(default = ""),
    },
)

# ---------------------------------------------------------------------------
# Module extension
# ---------------------------------------------------------------------------

_version_tag = tag_class(
    doc = "Download pre-built kube-apiserver + etcd tarballs from GCS.",
    attrs = {
        "versions": attr.string_list(
            doc     = "Kubernetes minor versions to download (e.g. ['1.29']).",
            mandatory = True,
        ),
    },
)

_system_tag = tag_class(
    doc = "Use the host-installed kube-apiserver + etcd binaries.",
    attrs = {
        "versions": attr.string_list(
            doc     = "Kubernetes minor versions to register (e.g. ['1.29']).",
            mandatory = True,
        ),
        "bin_dir": attr.string(
            doc     = "Directory containing kube-apiserver and etcd. " +
                      "Omit to auto-detect from PATH and common locations.",
            default = "",
        ),
    },
)

def _kubernetes_extension(module_ctx):
    for mod in module_ctx.modules:
        for tag in mod.tags.version:
            for version in tag.versions:
                for platform in PLATFORMS:
                    repo_name = "k8s_{}_{}".format(
                        version.replace(".", "_"), platform)
                    k8s_binary_repo(
                        name     = repo_name,
                        version  = version,
                        platform = platform,
                    )

        for tag in mod.tags.system:
            for version in tag.versions:
                for platform in PLATFORMS:
                    repo_name = "k8s_{}_{}".format(
                        version.replace(".", "_"), platform)
                    k8s_system_binary_repo(
                        name     = repo_name,
                        version  = version,
                        bin_dir  = tag.bin_dir,
                        platform = platform,
                    )

kubernetes = module_extension(
    implementation = _kubernetes_extension,
    tag_classes    = {
        "version": _version_tag,
        "system":  _system_tag,
    },
)
