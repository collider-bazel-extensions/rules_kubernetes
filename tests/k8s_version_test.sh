#!/usr/bin/env bash
# k8s_version_test.sh <expected server gitVersion>
#
# Verifies that kubernetes_test(k8s_version = ...) runs the API server and
# kubectl of that version: the server reports the expected gitVersion and
# the injected kubectl has the same minor.

set -euo pipefail

want="$1"                         # e.g. v1.35.0
want_minor="${want#v}"; want_minor="${want_minor#*.}"; want_minor="${want_minor%%.*}"

version_json="$("$KUBECTL" version --kubeconfig "$KUBECONFIG" -o json)"
field() {  # field <serverVersion|clientVersion> <key>
    python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]][sys.argv[2]])' "$1" "$2" <<<"$version_json"
}

server="$(field serverVersion gitVersion)"
client_minor="$(field clientVersion minor)"
echo "server gitVersion: $server (want $want)"
echo "kubectl minor:     $client_minor (want $want_minor)"

if [[ "$server" != "$want" ]]; then
    echo "FAIL: server is $server, want $want" >&2
    exit 1
fi
if [[ "${client_minor%+}" != "$want_minor" ]]; then
    echo "FAIL: kubectl minor is $client_minor, want $want_minor" >&2
    exit 1
fi

# A namespaced write, so the version is not only reachable but usable.
"$KUBECTL" --kubeconfig "$KUBECONFIG" -n "$KUBE_NAMESPACE" \
    create configmap version-probe --from-literal=v="$server" >/dev/null
echo "OK"
