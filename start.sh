#!/bin/bash
# Startup for Ollama + Tailscale on a SaladCloud GPU node.
# Publishes the local Ollama API on the tailnet via `tailscale serve` (HTTPS:443).
#
# Required env:
#   TAILSCALE_AUTH_KEY   Reusable + ephemeral Tailscale auth key (tskey-auth-...).
# Optional env:
#   TS_HOSTNAME          Tailnet node name (default: $SALAD_MACHINE_ID or ollama-gpu).
#   TS_EXTRA_UP_ARGS     Extra flags appended to `tailscale up`.
#   OLLAMA_MODEL         Model to pull at startup if not baked into the image.
set -euo pipefail

: "${TAILSCALE_AUTH_KEY:?TAILSCALE_AUTH_KEY is required}"
HOSTNAME_VALUE="${TS_HOSTNAME:-${SALAD_MACHINE_ID:-ollama-gpu}}"

# 1) Tailscale daemon — userspace networking is REQUIRED on Salad (no NET_ADMIN
#    / /dev/net/tun). The SOCKS5/HTTP proxy on :1055 handles any outbound calls.
echo "[start] Starting tailscaled (userspace networking)..."
tailscaled \
    --tun=userspace-networking \
    --socks5-server=localhost:1055 \
    --outbound-http-proxy-listen=localhost:1055 &
sleep 5
tailscale set --accept-dns=false || true

echo "[start] Joining tailnet as '${HOSTNAME_VALUE}'..."
# shellcheck disable=SC2086
tailscale up \
    --auth-key="${TAILSCALE_AUTH_KEY}" \
    --hostname "${HOSTNAME_VALUE}" \
    ${TS_EXTRA_UP_ARGS:-}

# 2) Ollama (background) — bound to loopback only.
echo "[start] Starting Ollama..."
ollama serve &
OLLAMA_PID=$!
for i in $(seq 1 60); do
    curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1 && break
    sleep 1
done

# Pull the model at runtime if it wasn't baked into the image.
if [ -n "${OLLAMA_MODEL:-}" ]; then
    echo "[start] Ensuring model '${OLLAMA_MODEL}' is present..."
    ollama pull "${OLLAMA_MODEL}" || true
fi

# 3) Publish Ollama on the tailnet over HTTPS (port 443 -> local 11434).
#    Works in userspace mode because tailscaled itself proxies inbound traffic.
echo "[start] Publishing via 'tailscale serve'..."
tailscale serve --bg --https=443 http://127.0.0.1:11434
tailscale serve status || true
echo "[start] Ollama is served at: https://${HOSTNAME_VALUE}.<your-tailnet>.ts.net/"

# 4) Keep Ollama in the foreground. If it dies, the container exits and Salad
#    reschedules the node.
wait "${OLLAMA_PID}"
