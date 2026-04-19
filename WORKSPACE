workspace(name = "rules_kubernetes")

# Bzlmod (MODULE.bazel) is the preferred way to use rules_kubernetes.
# This WORKSPACE file exists only as a compatibility shim for projects
# that have not yet migrated to Bzlmod.
#
# WORKSPACE usage:
#   load("@rules_kubernetes//:repositories.bzl", "kubernetes_system_dependencies")
#   kubernetes_system_dependencies(versions = ["1.29"])

load("//:repositories.bzl", "kubernetes_system_dependencies")

kubernetes_system_dependencies(versions = ["1.29"])
