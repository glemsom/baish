# BAISH — Bash-first terminal AI coding agent

BAISH is a Bash-first terminal AI coding agent for GNU/Linux. It provides multi-provider LLM support, file/shell tool execution, slash commands, and a skills system — all in pure Bash.

## Quick Start

```bash
cd /path/to/baish
./bin/baish
```

## Docker Containerization

BAISH can run inside a Docker container for blast-radius reduction — accidental destructive commands from the LLM are confined to the container instead of your host machine.

### Prerequisites

- Docker
- Linux host (SSH agent socket forwarding only works on Linux)

### Build the image

```bash
docker build -t baish:latest .
```

### Sourcing the wrapper

Source the wrapper function to get a `baish` shell command that launches the container with all necessary bind mounts, environment forwarding, and UID/GID matching:

```bash
source docker/baish-wrapper.sh
```

Then use it like native BAISH:

```bash
cd /path/to/your/project
baish
```

Or pass a directory:

```bash
baish /path/to/your/project
```

### What the wrapper does

The `baish` wrapper function orchestrates `docker run` with:

- **`--user $(id -u):$(id -g)`** — files created inside `/workspace` have your UID/GID
- **`-e HOME=/home/baish`** — UID/GID matching for the container's `baish` user
- **`--init`** — clean signal handling via tini
- **`--privileged`** — grants the container full access to the host kernel, needed for Docker-in-Docker via the host socket
- **`--group-add <docker-gid>`** — adds the Docker socket's group as a supplementary group so the non-root user can access the socket
- **`-e DOCKER_API_VERSION=<version>`** — forwards the host daemon's API version to prevent client/daemon version mismatch
- **Bind mounts:**
  - `~/.baish` → state, auth tokens, and skills persist across restarts
  - `$PWD` → mounted as `/workspace`
  - `~/.gitconfig` → Git config available for commits
  - `~/.ssh` → SSH keys for private repo access
  - `$SSH_AUTH_SOCK` → SSH agent forwarding for git push/pull
  - `/var/run/docker.sock` → host Docker daemon socket for Docker-in-Docker
- **Environment forwarding:**
  - All `BAISH_*` environment variables (e.g., `BAISH_DEBUG`, `BAISH_MAX_TOOL_ROUNDS`)
  - `TERM`, `COLUMNS`, `LINES` for correct terminal rendering
  - `DOCKER_API_VERSION` — matched to the host daemon for compatible API negotiation
- **Named volumes** for package manager caches (npm, pip, cargo) — dependencies persist across runs

### Docker-in-Docker

The BAISH container can run Docker commands (`docker`, `docker-compose`) by mounting the host's Docker socket (`/var/run/docker.sock`) inside the container and passing `--privileged` for the necessary capabilities. This allows the AI agent to execute container-based project tooling (e.g., `docker compose up`, `docker build`) directly from inside its own container.

#### Security implications

**`--privileged` grants the container full access to the host kernel.** Combined with the Docker socket mount, this allows processes inside the container to execute arbitrary commands on the host via the Docker daemon. The container is therefore **not a security sandbox** — this setup provides **blast-radius reduction**, not isolation against a compromised agent.

- A malicious or compromised agent inside the container can escape to the host via `docker run -v /:/host ...` or similar techniques
- Use this setup only in environments where you trust the AI agent's model provider and the code it operates on
- Do not use in multi-tenant environments where container escape would be unacceptable
- The `--privileged` flag is required because the Docker socket needs elevated capabilities (SYS_ADMIN, among others) to function correctly inside a container

### Per-directory sessions

Each `baish` invocation in a different directory creates a separate container with its own workspace bind mount. Concurrent sessions do not interfere with each other.

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `BAISH_MAX_TOOL_ROUNDS` | 50 | Max tool call rounds per message |
| `BAISH_BASH_TIMEOUT` | 120 | Shell command timeout in seconds |
| `BAISH_DEBUG` | 0 | Enable debug logging: 0=off, 1=on |

## Development

### Running tests

```bash
# Unit tests (no dependencies needed)
bats tests/test-docker-wrapper.bats

# Docker integration tests (requires Docker)
bats tests/test-docker-container.bats
```

## License

MIT
