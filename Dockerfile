FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# ── Base packages ──────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash curl jq shellcheck ca-certificates gnupg fzf \
    && rm -rf /var/lib/apt/lists/*

# ── lean-ctx ───────────────────────────────────────────────────────
RUN curl -fsSL https://leanctx.com/install.sh | sh

# ── glow (Charm markdown renderer) ─────────────────────────────────
RUN curl -fsSL https://github.com/charmbracelet/glow/releases/download/v2.1.2/glow_2.1.2_Linux_x86_64.tar.gz \
    | tar xz --strip-components=1 -C /usr/local/bin glow_2.1.2_Linux_x86_64/glow

# ── Docker CE (DinD) ───────────────────────────────────────────────
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list && \
    apt-get update && apt-get install -y --no-install-recommends \
        docker-ce-cli docker-ce \
    && rm -rf /var/lib/apt/lists/*

# ── Copy BAISH files ───────────────────────────────────────────────
COPY . /opt/baish/
RUN chmod +x /opt/baish/entrypoint.sh /opt/baish/baish

ENV PATH="/opt/baish:${PATH}"

ENTRYPOINT ["/opt/baish/entrypoint.sh"]
