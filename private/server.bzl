"""kubernetes_server rule and kubernetes_health_check rule."""

load(":binary.bzl", "KubernetesBinaryInfo")
load(":manifest.bzl", "KubernetesManifestInfo")

# ---------------------------------------------------------------------------
# JSON serialisation helpers
# ---------------------------------------------------------------------------

def _json_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

def _json_str_list(lst):
    return "[" + ", ".join([_json_str(s) for s in lst]) + "]"

# ---------------------------------------------------------------------------
# kubernetes_server
# ---------------------------------------------------------------------------

def _kubernetes_server_impl(ctx):
    binary_info = ctx.attr._binary[KubernetesBinaryInfo]

    manifest_short_paths = []
    manifest_info = ctx.attr.manifests
    if manifest_info:
        mi = manifest_info[KubernetesManifestInfo]
        manifest_short_paths = [f.short_path for f in mi.manifest_files.to_list()]

    # Build the server manifest JSON.
    fields = [
        '  "workspace":          ' + _json_str(ctx.workspace_name),
        '  "kube_apiserver_bin": ' + _json_str(binary_info.kube_apiserver.short_path),
        '  "etcd_bin":           ' + _json_str(binary_info.etcd.short_path),
        '  "kubectl_bin":        ' + _json_str(binary_info.kubectl.short_path),
    ]
    if manifest_short_paths:
        fields.append(
            '  "manifest_files":     ' + _json_str_list(manifest_short_paths))

    manifest_content = "{\n" + ",\n".join(fields) + "\n}\n"

    manifest_file = ctx.actions.declare_file(ctx.label.name + "_k8s_server_manifest.json")
    ctx.actions.write(manifest_file, manifest_content)

    # Generate the wrapper script.
    server_name    = ctx.label.name
    launcher_short = ctx.file._launcher.short_path
    manifest_short = manifest_file.short_path
    workspace      = ctx.workspace_name

    wrapper_content = """\
#!/usr/bin/env bash
set -euo pipefail
RUNFILES_ROOT="${{TEST_SRCDIR:-${{RUNFILES_DIR:-}}}}"
if [[ -z "$RUNFILES_ROOT" ]]; then
  RUNFILES_ROOT="${{BASH_SOURCE[0]}}.runfiles"
fi
export RULES_K8S_MODE=server
export RULES_K8S_MANIFEST="$RUNFILES_ROOT/{workspace}/{manifest_short}"
export RULES_K8S_OUTPUT_ENV_FILE="${{TEST_TMPDIR}}/{server_name}.env"
exec python3 "$RUNFILES_ROOT/{workspace}/{launcher_short}" "$@"
""".format(
        workspace      = workspace,
        manifest_short = manifest_short,
        launcher_short = launcher_short,
        server_name    = server_name,
    )

    wrapper = ctx.actions.declare_file(ctx.label.name + "_k8s_server.sh")
    ctx.actions.write(wrapper, wrapper_content, is_executable = True)

    # Assemble runfiles.
    rf = ctx.runfiles(files = [
        manifest_file,
        ctx.file._launcher,
        binary_info.kube_apiserver,
        binary_info.etcd,
        binary_info.kubectl,
    ])
    if manifest_info:
        mi = manifest_info[KubernetesManifestInfo]
        rf = rf.merge(ctx.runfiles(transitive_files = mi.manifest_files))

    return [DefaultInfo(
        executable = wrapper,
        runfiles   = rf,
    )]

kubernetes_server = rule(
    doc = """\
Long-running Kubernetes API server for multi-service integration tests.

Starts etcd and kube-apiserver on dynamically allocated ports, applies any
declared manifests, creates a UUID namespace, then writes
$TEST_TMPDIR/<name>.env atomically and blocks until SIGTERM.

Use with rules_itest:
    itest_service(name = "k8s_svc", exe = ":my_server",
                  health_check = ":my_server_health")
""",
    implementation = _kubernetes_server_impl,
    executable = True,
    attrs = {
        "manifests": attr.label(
            doc       = "Optional kubernetes_manifest to apply after the server starts.",
            providers = [KubernetesManifestInfo],
        ),
        "_binary": attr.label(
            doc       = "Platform-selected Kubernetes binary.",
            default   = Label("//:k8s_default"),
            providers = [KubernetesBinaryInfo],
        ),
        "_launcher": attr.label(
            doc               = "The launcher.py script.",
            default           = Label("//private:launcher.py"),
            allow_single_file = True,
        ),
    },
)

# ---------------------------------------------------------------------------
# kubernetes_health_check
# ---------------------------------------------------------------------------

def _kubernetes_health_check_impl(ctx):
    server_name = ctx.attr.server.label.name
    env_file    = "${{TEST_TMPDIR}}/{}.env".format(server_name)

    script_content = """\
#!/usr/bin/env bash
set -euo pipefail
env_file="{env_file}"
if [[ -f "$env_file" ]]; then
    exit 0
fi
echo "[rules_kubernetes] kubernetes_server env file not yet present: $env_file" >&2
exit 1
""".format(env_file = env_file)

    script = ctx.actions.declare_file(ctx.label.name + "_health_check.sh")
    ctx.actions.write(script, script_content, is_executable = True)

    return [DefaultInfo(
        executable = script,
        runfiles   = ctx.runfiles(files = [script]),
    )]

kubernetes_health_check = rule(
    doc = """\
Health-check binary for a kubernetes_server target.

Exits 0 if and only if $TEST_TMPDIR/<server-name>.env exists (i.e. the server
is fully ready).  Used as the health_check attribute of an itest_service.
""",
    implementation = _kubernetes_health_check_impl,
    executable = True,
    attrs = {
        "server": attr.label(
            doc      = "The kubernetes_server target to check.",
            mandatory = True,
        ),
    },
)
