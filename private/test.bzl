"""kubernetes_test macro and _k8s_launcher_test rule."""

load(":binary.bzl", "KubernetesBinaryInfo")
load(":manifest.bzl", "KubernetesManifestInfo")
load(":controller.bzl", "KubernetesControllerInfo")

# ---------------------------------------------------------------------------
# JSON serialisation helpers (Bazel 6 has no json.encode)
# ---------------------------------------------------------------------------

def _json_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

def _json_str_list(lst):
    return "[" + ", ".join([_json_str(s) for s in lst]) + "]"

# ---------------------------------------------------------------------------
# _k8s_launcher_test rule
# ---------------------------------------------------------------------------

def _k8s_launcher_impl(ctx):
    binary_info = ctx.attr._binary[KubernetesBinaryInfo]

    # Resolve optional controller and manifests.
    controller_info = None
    if ctx.attr.controller:
        controller_info = ctx.attr.controller[KubernetesControllerInfo]

    manifest_info = None
    if ctx.attr.manifests:
        manifest_info = ctx.attr.manifests[KubernetesManifestInfo]
    elif controller_info and controller_info.manifest_info:
        manifest_info = controller_info.manifest_info

    # Collect manifest file short_paths (preserving depset order).
    manifest_short_paths = []
    if manifest_info:
        manifest_short_paths = [f.short_path for f in manifest_info.manifest_files.to_list()]

    # Resolve the inner test binary.
    inner_exe = ctx.attr.test[DefaultInfo].files_to_run.executable

    # Build the JSON manifest.
    fields = [
        '  "workspace":          ' + _json_str(ctx.workspace_name),
        '  "kube_apiserver_bin": ' + _json_str(binary_info.kube_apiserver.short_path),
        '  "etcd_bin":           ' + _json_str(binary_info.etcd.short_path),
        '  "kubectl_bin":        ' + _json_str(binary_info.kubectl.short_path),
    ]
    if controller_info:
        fields.append(
            '  "controller_binary":  ' + _json_str(controller_info.binary.short_path))
        fields.append(
            '  "ready_probe":        ' + _json_str(controller_info.ready_probe))
    if manifest_short_paths:
        fields.append(
            '  "manifest_files":     ' + _json_str_list(manifest_short_paths))

    manifest_content = "{\n" + ",\n".join(fields) + "\n}\n"

    manifest_file = ctx.actions.declare_file(ctx.label.name + "_k8s_manifest.json")
    ctx.actions.write(manifest_file, manifest_content)

    # Generate the wrapper shell script.
    launcher_short = ctx.file._launcher.short_path
    manifest_short = manifest_file.short_path
    inner_short    = inner_exe.short_path

    workspace = ctx.workspace_name

    wrapper_content = """\
#!/usr/bin/env bash
set -euo pipefail
RUNFILES_ROOT="${{TEST_SRCDIR:-${{RUNFILES_DIR:-}}}}"
if [[ -z "$RUNFILES_ROOT" ]]; then
  RUNFILES_ROOT="${{BASH_SOURCE[0]}}.runfiles"
fi
export K8S_MANIFEST="$RUNFILES_ROOT/{workspace}/{manifest_short}"
export K8S_TEST_BINARY="$RUNFILES_ROOT/{workspace}/{inner_short}"
exec python3 "$RUNFILES_ROOT/{workspace}/{launcher_short}" "$@"
""".format(
        workspace      = workspace,
        manifest_short = manifest_short,
        inner_short    = inner_short,
        launcher_short = launcher_short,
    )

    wrapper = ctx.actions.declare_file(ctx.label.name + "_k8s_launcher.sh")
    ctx.actions.write(wrapper, wrapper_content, is_executable = True)

    # Assemble runfiles.
    rf = ctx.runfiles(files = [
        manifest_file,
        ctx.file._launcher,
        binary_info.kube_apiserver,
        binary_info.etcd,
        binary_info.kubectl,
    ])

    # Inner test binary runfiles.
    rf = rf.merge(ctx.attr.test[DefaultInfo].default_runfiles)

    # Controller runfiles.
    if controller_info:
        rf = rf.merge(controller_info.runfiles)

    # Manifest file runfiles.
    if manifest_info:
        rf = rf.merge(ctx.runfiles(transitive_files = manifest_info.manifest_files))

    return [DefaultInfo(
        executable = wrapper,
        runfiles   = rf,
    )]

_k8s_launcher_test = rule(
    doc = "Internal rule: wraps a test binary with an ephemeral Kubernetes API server.",
    implementation = _k8s_launcher_impl,
    test = True,
    attrs = {
        "test": attr.label(
            doc      = "The inner test binary (tagged manual).",
            mandatory = True,
        ),
        "controller": attr.label(
            doc       = "Optional kubernetes_controller target.",
            providers = [KubernetesControllerInfo],
        ),
        "manifests": attr.label(
            doc       = "Optional kubernetes_manifest target (used when no controller is set).",
            providers = [KubernetesManifestInfo],
        ),
        "_binary": attr.label(
            doc      = "Platform-selected Kubernetes binary (kube-apiserver + etcd + kubectl).",
            default  = Label("//:k8s_default"),
            providers = [KubernetesBinaryInfo],
        ),
        "_launcher": attr.label(
            doc            = "The launcher.py script.",
            default        = Label("//private:launcher.py"),
            allow_single_file = True,
        ),
    },
)

# ---------------------------------------------------------------------------
# kubernetes_test macro
# ---------------------------------------------------------------------------

def kubernetes_test(
        name,
        srcs,
        controller = None,
        manifests  = None,
        deps       = [],
        size       = "medium",
        timeout    = None,
        tags       = [],
        test_rule  = None,
        **kwargs):
    """Run an isolated test against an ephemeral Kubernetes API server.

    Every invocation gets:
    - Its own etcd + kube-apiserver on dynamically allocated ports.
    - Ephemeral TLS credentials generated at runtime.
    - A UUID namespace (k8s-test-<12-hex-chars>).
    - KUBECONFIG, KUBE_NAMESPACE, KUBE_API_SERVER injected into the test.

    Args:
        name:       Target name.  The launcher wrapper is registered as this name;
                    the inner test binary is '<name>_inner' (tagged manual).
        srcs:       Source files forwarded to test_rule.
        controller: Optional kubernetes_controller target.
        manifests:  Optional kubernetes_manifest target (ignored when controller
                    provides its own manifests).
        deps:       Deps forwarded to test_rule.
        size:       Test size (default "medium").
        timeout:    Test timeout.
        tags:       Tags forwarded to test_rule.
        test_rule:  The Bazel test rule to use for the inner binary
                    (default native.sh_test).
        **kwargs:   Additional kwargs forwarded to test_rule.
    """
    if test_rule == None:
        test_rule = native.sh_test

    inner_name = name + "_inner"

    # Build the inner test target (tagged manual — never run directly).
    inner_tags = list(tags) + ["manual"]
    test_rule(
        name = inner_name,
        srcs = srcs,
        deps = deps,
        tags = inner_tags,
        **kwargs
    )

    # Build the launcher wrapper.
    launcher_kwargs = {}
    if timeout:
        launcher_kwargs["timeout"] = timeout

    _k8s_launcher_test(
        name       = name,
        test       = ":" + inner_name,
        controller = controller,
        manifests  = manifests,
        size       = size,
        tags       = tags,
        **launcher_kwargs
    )
