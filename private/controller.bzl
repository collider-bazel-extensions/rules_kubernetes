"""KubernetesControllerInfo provider and kubernetes_controller rule."""

load(":manifest.bzl", "KubernetesManifestInfo")

KubernetesControllerInfo = provider(
    doc = "A controller binary and its associated manifest and readiness configuration.",
    fields = {
        "binary":        "File: the controller executable",
        "runfiles":      "runfiles: runfiles needed by the controller",
        "manifest_info": "KubernetesManifestInfo or None: manifests to apply before the controller starts",
        "ready_probe":   "string: readiness probe mode — 'lease' (default) or 'env_file'",
    },
)

def _kubernetes_controller_impl(ctx):
    binary = ctx.executable.controller_binary

    # Collect runfiles: the controller binary plus everything it declared.
    controller_runfiles = ctx.runfiles(files = [binary])
    controller_runfiles = controller_runfiles.merge(
        ctx.attr.controller_binary[DefaultInfo].default_runfiles)

    manifest_info = None
    if ctx.attr.manifests:
        manifest_info = ctx.attr.manifests[KubernetesManifestInfo]

    ready_probe = ctx.attr.ready_probe
    if ready_probe not in ("lease", "env_file"):
        fail("kubernetes_controller: ready_probe must be 'lease' or 'env_file', got: " +
             repr(ready_probe))

    return [
        KubernetesControllerInfo(
            binary        = binary,
            runfiles      = controller_runfiles,
            manifest_info = manifest_info,
            ready_probe   = ready_probe,
        ),
        DefaultInfo(runfiles = controller_runfiles),
    ]

kubernetes_controller = rule(
    doc = """\
Declares a Kubernetes controller binary to run during a kubernetes_test.

The controller is started after manifests are applied and the API server is
ready.  The launcher waits for the controller to signal readiness before
execve-ing the test binary.

Readiness modes (ready_probe):
  'lease'    (default) — poll for a leader-election Lease in the test
             namespace.  Works for any controller that uses leader election.
  'env_file' — the controller writes the path in $RULES_K8S_READY_FILE when
             ready.  Use this for controllers that do not use leader election.
""",
    implementation = _kubernetes_controller_impl,
    attrs = {
        "controller_binary": attr.label(
            doc        = "The controller binary target.",
            mandatory  = True,
            executable = True,
            cfg        = "target",
        ),
        "manifests": attr.label(
            doc       = "Optional kubernetes_manifest to apply before the controller starts.",
            providers = [KubernetesManifestInfo],
        ),
        "ready_probe": attr.string(
            doc     = "Readiness probe mode: 'lease' (default) or 'env_file'.",
            default = "lease",
        ),
    },
)
