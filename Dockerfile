FROM debian:trixie-slim

ARG BAISH_UID=1000
ARG BAISH_GID=1000
ARG GHOSTTY_TERMINFO_B64=

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      bash \
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
      ncurses-bin \
      sed \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh -o /tmp/rtk-install.sh \
    && RTK_INSTALL_DIR=/usr/local/bin bash /tmp/rtk-install.sh \
    && rm -f /tmp/rtk-install.sh


RUN groupadd --gid "$BAISH_GID" baish \
    && useradd --uid "$BAISH_UID" --gid "$BAISH_GID" --create-home --shell /bin/bash baish \
    && mkdir -p /workspace /home/baish/.baish /opt/baish \
    && chown -R baish:baish /workspace /home/baish /opt/baish

RUN apt-get update \
    && apt-get install -y --no-install-recommends sudo \
    && rm -rf /var/lib/apt/lists/* \
    && echo "baish ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/baish \
    && chmod 440 /etc/sudoers.d/baish \
    && usermod -aG sudo baish

COPY --chown=baish:baish . /opt/baish

RUN if [[ -n "$GHOSTTY_TERMINFO_B64" ]]; then \
      printf '%s' "$GHOSTTY_TERMINFO_B64" | base64 --decode >/tmp/xterm-ghostty.src \
      && tic -x -o /usr/share/terminfo /tmp/xterm-ghostty.src \
      && rm -f /tmp/xterm-ghostty.src; \
    fi

ENV HOME=/home/baish
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
WORKDIR /workspace
USER baish

ENTRYPOINT ["/opt/baish/bin/baish"]
