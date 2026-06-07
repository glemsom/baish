# Docker containerization for blast-radius reduction

BAISH ships a `Dockerfile` and shell wrapper function so users can run the agent inside a container instead of directly on the host. The primary goal is **blast-radius reduction**: if the LLM issues an accidental destructive command (`rm -rf /`), damage is confined to the container's filesystem and mounted volumes, not the host rootfs.

## Decisions

**Kitchen-sink Ubuntu image.** The image bundles bash, coreutils, jq, curl, git, ssh-client, python3+pip, nodejs+npm, go, rust+cargo, ruby, make, gcc, and pkg-config so the agent's `bash` tool can run common project commands without missing toolchains. Users rebuild the image locally when they need specific versions (no pre-built image is pushed to a registry).

**User UID/GID matching.** The wrapper passes `--user $(id -u):$(id -g)` and sets `HOME=/home/baish`. The entrypoint script creates `/home/baish` at container start so file ownership on bind-mounted volumes matches the host user.

**Bind mounts.** `~/.baish` (state, auth, skills), `$PWD` (the workspace), `~/.gitconfig`, `~/.ssh`, and `$SSH_AUTH_SOCK` are mounted into the container. Environment variables prefixed `BAISH_` are forwarded from the host. Package manager caches use named Docker volumes for persistence across runs.

**`--init` for signal handling.** The wrapper passes `--init` so Docker's built-in `tini` runs as PID 1, forwarding signals cleanly to the BAISH process.

**Docker-in-Docker with `--privileged`.** The image includes the Docker CLI and the wrapper passes `--privileged` so the agent can run `docker-compose` and other container-based project tooling. This deliberately trades some isolation (the Docker socket enables host escape) for development workflow compatibility.

## Considered Options

- **Pre-built distributed image.** Rejected in favor of local builds to keep the image coupled to the repo and avoid maintaining a CI pipeline.
- **User-provided base image.** Rejected because it shifts toolchain management burden to every user. The kitchen-sink covers most projects out of the box.
- **No Docker-in-Docker.** Rejected because many projects' test suites depend on Docker. Without `--privileged`, the agent is missing a core development tool.
- **SSH agent forwarding via macOS/Windows.** Rejected — the wrapper only supports Linux hosts where Unix socket bind-mounting works.
