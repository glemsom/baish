#!/usr/bin/env bash

# ── Start Docker daemon (DinD) ─────────────────────────────────────
if [ -S /var/run/docker.sock ]; then
    echo "▸ Docker socket already available — skipping dockerd start"
else
    echo "▸ Starting dockerd…"
    dockerd &>/var/log/dockerd.log &
    DOCKERD_PID=$!

    # Wait for docker to become responsive
    for i in $(seq 1 30); do
        if docker info &>/dev/null; then
            echo "▸ dockerd ready (${i}s)"
            break
        fi
        if [ "$i" -eq 30 ]; then
            echo "✗ dockerd failed to start after 30s" >&2
            echo "--- dockerd log ---" >&2
            cat /var/log/dockerd.log >&2
            exit 1
        fi
        sleep 1
    done

    # If the user exits, stop dockerd cleanly
    trap 'kill $DOCKERD_PID 2>/dev/null; wait $DOCKERD_PID 2>/dev/null' EXIT
fi

# ── Hand off to baish ──────────────────────────────────────────────
exec baish "$@"
