"""kubernetes_tool: a runnable wrapper over one binary of a kubernetes_binary."""

load(":binary.bzl", "KubernetesBinaryInfo")

# Tool name → KubernetesBinaryInfo field.
_FIELDS = {
    "kubectl":        "kubectl",
    "kube-apiserver": "kube_apiserver",
    "etcd":           "etcd",
}

def _rlocation(ctx, f):
    if f.short_path.startswith("../"):
        return f.short_path[len("../"):]
    return ctx.workspace_name + "/" + f.short_path

def _kubernetes_tool_impl(ctx):
    info = ctx.attr.binary[KubernetesBinaryInfo]
    f = getattr(info, _FIELDS[ctx.attr.tool])
    if f == None:
        fail("kubernetes_tool: {} has no {} for this platform".format(ctx.attr.binary.label, ctx.attr.tool))

    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.expand_template(
        template = ctx.file._template,
        output = out,
        substitutions = {
            "{TOOL}":      "{} {}".format(ctx.attr.tool, info.version),
            "{TARGET}":    str(ctx.label),
            "{RLOCATION}": _rlocation(ctx, f),
        },
        is_executable = True,
    )
    return [DefaultInfo(
        executable = out,
        files = depset([out]),
        runfiles = ctx.runfiles(files = [f]),
    )]

kubernetes_tool = rule(
    doc = """\
Runs one binary of a kubernetes_binary target (`bazel run`, or as `data`).

Arguments are forwarded. Under `bazel run` the tool runs from the caller's
directory (`$BUILD_WORKING_DIRECTORY`), so relative paths resolve there.
""",
    implementation = _kubernetes_tool_impl,
    executable = True,
    attrs = {
        "binary": attr.label(
            doc       = "kubernetes_binary target (e.g. //:k8s_1_35).",
            mandatory = True,
            providers = [KubernetesBinaryInfo],
        ),
        "tool": attr.string(
            doc    = "Which binary to run.",
            values = sorted(_FIELDS.keys()),
            default = "kubectl",
        ),
        "_template": attr.label(
            default = ":tool.sh.tmpl",
            allow_single_file = True,
        ),
    },
)
