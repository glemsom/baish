# BAISH — BASH + AI

A multi-turn AI coding assistant in pure Bash, running inside a Docker-in-Docker container.

## Quick Start

```bash
# 1. Build the image
docker build -t baish .

# 2. Run (mount your workspace + config)
docker run --rm -it \
  -v "$(pwd)":/workspace \
  -v ~/.baish:/root/.baish:ro \
  -e BAISH_API_KEY="$BAISH_API_KEY" \
  baish
```

## Configuration

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `BAISH_PROVIDER` | `kilo` | Provider name (`github` or `kilo`) |
| `BAISH_MODEL` | _(auto)_ | Model name (resolved from provider) |
| `BAISH_API_KEY` | _(auto)_ | API key (or use `GITHUB_TOKEN` / `KILO_API_KEY`) |
| `BAISH_BASE_URL` | _(auto)_ | API base URL (resolved from provider) |
| `BAISH_MAX_CONTEXT` | `32000` | Token budget fallback |
| `BAISH_SKILLS_DIR` | `/root/.baish/skills` | Skills directory |

### Config File

Create `~/.baish/config` (key=value format, `#` for comments):

```ini
BAISH_PROVIDER=kilo
BAISH_MODEL=gpt-5-mini
# BAISH_API_KEY=sk-...
```

Config loading order: **defaults → config file → env vars** (env wins).

### Provider Profiles

| Provider | Base URL | API Key Source | Default Model |
|----------|----------|----------------|---------------|
| `github` | `https://api.githubcopilot.com` | `GITHUB_TOKEN` | `gpt-4o-mini` |
| `kilo` | `https://gateway.kilocode.ai` | `KILO_API_KEY` | `gpt-4o-mini` |

## Tools

BAISH provides the following tools to the AI assistant:

| Tool | Description |
|------|-------------|
| `shell` | Run shell commands (output auto-compressed) |
| `read` | Read file contents (smart mode selection) |
| `write` | Write content to a file (auto-creates directories) |
| `edit` | Targeted text replacement (requires unique match) |
| `load_skill` | Load a skill's full instructions |

## Skills

Skills are agent skill definitions stored as `SKILL.md` files in `~/.baish/skills/<name>/`.

### Installing a Skill

```bash
mkdir -p ~/.baish/skills/my-skill
cat > ~/.baish/skills/my-skill/SKILL.md << 'EOF'
---
name: my-skill
description: A skill that does something useful
---

## Instructions

Step-by-step instructions for the AI...
EOF
```

BAISH discovers skills at startup and shows them in the system prompt. The AI can load a skill's full instructions on demand using `load_skill`.

## Architecture

- **Pure Bash** — No Python, no Node.js. Just `curl` + `jq` + `bash`.
- **DinD** — Docker-in-Docker for containerized tool execution.
- **OpenAI-compatible** — Works with any provider supporting the Chat Completions API.
- **Context management** — Automatic context window detection, token estimation, and message trimming.
- **TUI** — Colored prompts, `glow` markdown rendering.
- **Ephemeral** — Container is disposable; no state persists beyond the session.

## Dependencies (inside container)

| Package | Purpose |
|---------|---------|
| `lean-ctx` | Context compression for shell output |
| `jq` | JSON parsing |
| `glow` | Markdown rendering |
| `docker-ce-cli` + `dockerd` | DinD support |
| `curl`, `bash`, `shellcheck` | Core utilities |

## Bashrc Helper

Add this to your `~/.bashrc` for quick access:

```bash
baish() {
  docker run --rm -it \
    -v "$(pwd)":/workspace \
    -v ~/.baish:/root/.baish:ro \
    -e BAISH_API_KEY="${BAISH_API_KEY:-}" \
    -e BAISH_PROVIDER="${BAISH_PROVIDER:-kilo}" \
    baish "$@"
}
```

## Version

Current: **v0.2.0**
