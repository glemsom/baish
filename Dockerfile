# BAISH — Docker image for blast-radius reduction
FROM ubuntu:26.04

# Prevent interactive prompts during apt
ENV DEBIAN_FRONTEND=noninteractive

# Install common development toolchains
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    coreutils \
    curl \
    fzf \
    gcc \
    git \
    jq \
    make \
    pkg-config \
    python3 \
    python3-pip \
    ruby \
    ssh-client \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js (LTS via nodesource)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install Go
RUN curl -fsSL https://go.dev/dl/go1.22.2.linux-amd64.tar.gz | tar -C /usr/local -xz \
    && ln -s /usr/local/go/bin/go /usr/local/bin/go

# Install Rust
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y \
    && ln -s /root/.cargo/bin/cargo /usr/local/bin/cargo \
    && ln -s /root/.cargo/bin/rustc /usr/local/bin/rustc

# Install Docker CLI
RUN apt-get update && apt-get install -y --no-install-recommends \
    docker.io \
    && rm -rf /var/lib/apt/lists/*

# Install Docker Compose v2 (standalone binary) so the agent can run
# docker-compose up for projects that use it.
RUN curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose \
    && chmod +x /usr/local/bin/docker-compose

# Install gum (charmbracelet/gum) — download .deb from GitHub releases
ARG GUM_VERSION=v0.17.0
RUN curl -fsSL "https://github.com/charmbracelet/gum/releases/download/${GUM_VERSION}/gum_${GUM_VERSION#v}_amd64.deb" -o /tmp/gum.deb \
    && dpkg -i /tmp/gum.deb \
    && rm -f /tmp/gum.deb

# Remove the base image's default ubuntu user (UID 1000) and create the
# baish user at UID 1000 instead. Most Linux systems have their first
# real user at UID 1000, so matching that UID ensures bind-mounted host
# files (like ~/.baish, ~/.gitconfig, ~/.ssh) have the same owner inside
# the container as the process itself when --user $(id -u):$(id -g) is
# passed at runtime.
RUN userdel -r ubuntu && \
    useradd -u 1000 -m -s /bin/bash baish && \
    chmod 755 /home/baish

# Pre-create package manager cache directories so named Docker volume
# mount points inherit world-writable permissions (issue #55). Without
# this, Docker creates volume mount points as root-owned and the
# non-root runtime user cannot write to them. Also make intermediate
# parent directories (.cache, .cargo) world-writable so tools can
# create sibling files/dirs next to the volume mount points.
RUN mkdir -p /home/baish/.npm /home/baish/.cache/pip /home/baish/.cargo/registry && \
    chmod 777 /home/baish/.npm /home/baish/.cache /home/baish/.cache/pip \
             /home/baish/.cargo /home/baish/.cargo/registry

# Install BAISH
COPY . /opt/baish/
RUN chmod +x /opt/baish/bin/baish && ln -s /opt/baish/bin/baish /usr/local/bin/baish

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER baish

ENTRYPOINT ["/entrypoint.sh"]
CMD ["baish"]
