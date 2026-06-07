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
- **`--privileged`** — Docker-in-Docker support (the agent can run `docker-compose`)
- **Bind mounts:**
  - `~/.baish` → state, auth tokens, and skills persist across restarts
  - `$PWD` → mounted as `/workspace`
  - `~/.gitconfig` → Git config available for commits
  - `~/.ssh` → SSH keys for private repo access
  - `$SSH_AUTH_SOCK` → SSH agent forwarding for git push/pull
- **Environment forwarding:**
  - All `BAISH_*` environment variables (e.g., `BAISH_DEBUG`, `BAISH_MAX_TOOL_ROUNDS`)
  - `TERM`, `COLUMNS`, `LINES` for correct terminal rendering
- **Named volumes** for package manager caches (npm, pip, cargo) — dependencies persist across runs

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
