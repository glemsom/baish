FROM debian:trixie-slim

ARG BAISH_UID=1000
ARG BAISH_GID=1000

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      bash \
      bat \
      bats \
      ca-certificates \
      coreutils \
      curl \
      fzf \
      gawk \
      gh \
      git \
      grep \
      jq \
      make \
      sed \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh -o /tmp/rtk-install.sh \
    && RTK_INSTALL_DIR=/usr/local/bin bash /tmp/rtk-install.sh \
    && rm -f /tmp/rtk-install.sh

RUN if [[ ! -e /usr/bin/bat && -x /usr/bin/batcat ]]; then \
      ln -s /usr/bin/batcat /usr/bin/bat; \
    fi

RUN groupadd --gid "$BAISH_GID" baish \
    && useradd --uid "$BAISH_UID" --gid "$BAISH_GID" --create-home --shell /bin/bash baish \
    && mkdir -p /workspace /home/baish/.baish /opt/baish \
    && chown -R baish:baish /workspace /home/baish /opt/baish

COPY --chown=baish:baish . /opt/baish

ENV HOME=/home/baish
WORKDIR /workspace
USER baish

ENTRYPOINT ["/opt/baish/bin/baish"]
