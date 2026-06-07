# BAISH — Docker image for blast-radius reduction
FROM ubuntu:22.04

# Prevent interactive prompts during apt
ENV DEBIAN_FRONTEND=noninteractive

# Install common development toolchains
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    coreutils \
    curl \
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

# Create baish user (UID will be overridden at runtime via --user)
RUN useradd -m -s /bin/bash baish

# Install BAISH
COPY . /opt/baish/
RUN chmod +x /opt/baish/bin/baish && ln -s /opt/baish/bin/baish /usr/local/bin/baish

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["baish"]
