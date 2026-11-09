#!/usr/bin/env bash
# kubectl_run_test.sh <kubectl wrapper> <minor> [<wrapper> <minor> ...]
#
# Verifies the runnable //:kubectl_<v> targets: each runs the kubectl of its
# version, and with BUILD_WORKING_DIRECTORY set (as `bazel run` sets it)
# relative paths resolve from that directory, not from the runfiles tree.

set -euo pipefail

wd="$TEST_TMPDIR/caller"
mkdir -p "$wd"
echo "from-the-caller" > "$wd/payload.txt"

while (($#)); do
    tool="$1" want="$2"; shift 2
    minor="$("$tool" version --client -o json |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["clientVersion"]["minor"])')"
    echo "$tool: kubectl minor $minor (want $want)"
    if [[ "${minor%+}" != "$want" ]]; then
        echo "FAIL: $tool runs kubectl minor $minor, want $want" >&2
        exit 1
    fi

    out="$(BUILD_WORKING_DIRECTORY="$wd" "$tool" create configmap probe \
        --from-file=./payload.txt --dry-run=client -o yaml)"
    if ! grep -q "from-the-caller" <<<"$out"; then
        echo "FAIL: $tool did not read ./payload.txt from BUILD_WORKING_DIRECTORY:" >&2
        echo "$out" >&2
        exit 1
    fi
done
echo "OK"
