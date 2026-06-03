# syntax=docker/dockerfile:1
#
# Single-file image: serves an Ollama model on a SaladCloud GPU node and
# publishes it on your tailnet via `tailscale serve` (HTTPS on the node's
# MagicDNS name).
#
# ── Prerequisites (one time) ────────────────────────────────────────────────
#   * Tailscale: enable MagicDNS + HTTPS certificates
#       https://login.tailscale.com/admin/dns  (toggle "HTTPS Certificates")
#     `tailscale serve` needs this to mint the TLS cert.
#   * Generate a REUSABLE + EPHEMERAL auth key:
#       https://login.tailscale.com/admin/settings/keys
#
# ── Build ───────────────────────────────────────────────────────────────────
#   docker build -t <registry>/ollama-tailscale:0.0.1 \
#       --build-arg OLLAMA_PRELOAD_MODEL=llama3.2 .
#   docker push <registry>/ollama-tailscale:0.0.1
#   (Pre-baking the model is recommended: Salad nodes are ephemeral and lose
#    local storage on reallocation, so this avoids re-downloading weights.)
#
# ── Deploy on SaladCloud ────────────────────────────────────────────────────
#   Image:  <registry>/ollama-tailscale:0.0.1
#   GPU:    any GPU with enough VRAM for your model
#   Env:    TAILSCALE_AUTH_KEY = tskey-auth-...
#           OLLAMA_MODEL       = llama3.2   (optional; pulled at startup if not baked)
#   (No Container Gateway needed — access is over the tailnet.)
#
# ── Use it (from any device on your tailnet) ────────────────────────────────
#   The node registers under its SALAD_MACHINE_ID. `tailscale serve` exposes it at
#       https://<machine-id>.<your-tailnet>.ts.net/
#   so:
#       OLLAMA_HOST=https://<machine-id>.<tailnet>.ts.net ollama run llama3.2
#       curl https://<machine-id>.<tailnet>.ts.net/api/generate \
#            -d '{"model":"llama3.2","prompt":"hi"}'
# ----------------------------------------------------------------------------

ARG CUDA_VERSION=12.6.2
ARG UBUNTU_VERSION=22.04
FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive

# --- Utilities, Tailscale, Ollama -------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL https://tailscale.com/install.sh | sh \
    && curl -fsSL https://ollama.com/install.sh | sh

# Ollama listens only on loopback; the tailnet sees it solely via `tailscale serve`.
ENV OLLAMA_HOST=127.0.0.1:11434
ENV OLLAMA_MODELS=/root/.ollama/models
# Allow browser-based clients (e.g. Open WebUI) hitting the HTTPS endpoint.
ENV OLLAMA_ORIGINS=*

# --- Optional: bake a model into the image at build time ---------------------
#   docker build --build-arg OLLAMA_PRELOAD_MODEL=llama3.2 .
ARG OLLAMA_PRELOAD_MODEL=""
RUN if [ -n "$OLLAMA_PRELOAD_MODEL" ]; then \
        ollama serve & srv=$!; \
        for i in $(seq 1 30); do \
            curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1 && break; \
            sleep 1; \
        done; \
        ollama pull "$OLLAMA_PRELOAD_MODEL"; \
        kill "$srv" 2>/dev/null || true; wait "$srv" 2>/dev/null || true; \
    fi

# --- Startup script (Salad needs a long-running foreground process) ----------
COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

CMD ["/usr/local/bin/start.sh"]
