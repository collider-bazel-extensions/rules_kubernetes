#!/usr/bin/env python3
"""
echo_controller

Watches ConfigMaps labelled 'echo-input=true' in KUBE_NAMESPACE.
For each one, creates a mirrored ConfigMap named '<source>-echo' with the
same data.

Readiness: writes $RULES_K8S_READY_FILE after the first successful list call
so the launcher knows the controller is connected to the API server.
"""

import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.request


# ---------------------------------------------------------------------------
# kubeconfig parsing
# ---------------------------------------------------------------------------

def _parse_kubeconfig(path):
    """Extract server URL and cert paths from the launcher-generated kubeconfig.

    The launcher writes a fixed YAML structure; we parse it with regex rather
    than pulling in a YAML library.
    """
    with open(path) as f:
        content = f.read()

    def _get(pattern):
        m = re.search(pattern, content)
        if not m:
            raise ValueError(f"kubeconfig field not found: {pattern!r}")
        return m.group(1).strip()

    server      = _get(r"server:\s*(\S+)")
    ca_cert     = _get(r"certificate-authority:\s*(\S+)")
    client_cert = _get(r"client-certificate:\s*(\S+)")
    client_key  = _get(r"client-key:\s*(\S+)")
    return server, ca_cert, client_cert, client_key


def _make_ssl_ctx(ca_cert, client_cert, client_key):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.load_verify_locations(ca_cert)
    ctx.load_cert_chain(client_cert, client_key)
    return ctx


# ---------------------------------------------------------------------------
# Kubernetes API helpers
# ---------------------------------------------------------------------------

def _api(ctx, base_url, path, method="GET", body=None):
    url  = base_url.rstrip("/") + path
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Accept": "application/json"}
    if data:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        resp = urllib.request.urlopen(req, context=ctx, timeout=5)
        return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        if e.code == 409:   # Conflict — object already exists
            return None
        body_bytes = e.read()
        raise RuntimeError(
            f"API {method} {path} returned HTTP {e.code}: {body_bytes.decode()[:200]}")


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def main():
    kubeconfig  = os.environ.get("KUBECONFIG", "")
    namespace   = os.environ.get("KUBE_NAMESPACE", "")
    ready_file  = os.environ.get("RULES_K8S_READY_FILE", "")

    if not kubeconfig or not namespace:
        print("[echo_controller] ERROR: KUBECONFIG and KUBE_NAMESPACE must be set",
              file=sys.stderr, flush=True)
        sys.exit(1)

    server, ca_cert, client_cert, client_key = _parse_kubeconfig(kubeconfig)
    ssl_ctx  = _make_ssl_ctx(ca_cert, client_cert, client_key)
    ns_path  = f"/api/v1/namespaces/{namespace}"

    print(f"[echo_controller] watching ConfigMaps in namespace {namespace!r}",
          flush=True)

    processed      = set()
    ready_signaled = False

    while True:
        try:
            result = _api(
                ssl_ctx, server,
                f"{ns_path}/configmaps?labelSelector=echo-input%3Dtrue")

            # Signal readiness on the first successful list.
            if not ready_signaled:
                if ready_file:
                    with open(ready_file, "w") as f:
                        f.write("ready\n")
                ready_signaled = True
                print("[echo_controller] ready", flush=True)

            for item in result.get("items", []):
                name = item["metadata"]["name"]
                if name in processed:
                    continue

                echo_name = f"{name}-echo"
                data      = item.get("data", {})

                created = _api(ssl_ctx, server, f"{ns_path}/configmaps",
                    method = "POST",
                    body   = {
                        "apiVersion": "v1",
                        "kind":       "ConfigMap",
                        "metadata":   {
                            "name":      echo_name,
                            "namespace": namespace,
                        },
                        "data": data,
                    })
                if created is not None:
                    print(f"[echo_controller] mirrored {name!r} → {echo_name!r}",
                          flush=True)
                processed.add(name)

        except Exception as e:
            print(f"[echo_controller] error: {e}", file=sys.stderr, flush=True)

        time.sleep(0.5)


if __name__ == "__main__":
    main()
