# BAISH

BAISH is a Bash-first terminal AI coding agent for GNU/Linux.

V1 is a readline-style terminal application (not a full-screen TUI) that supports provider-backed chat, slash commands, explicit skills, and autonomous file/shell tools. Tool activity is rendered in compact, styled terminal blocks rather than raw JSON.

## At a glance (V1)

- Platform: GNU/Linux only
- Interface: readline-style prompt
- Providers discovered from: lib/providers/*.sh
- Built-in providers: GitHub Copilot, Kilo Gateway, Mock
- Autonomous tool execution (no approval prompts)
- Streaming LLM responses (real-time thinking and text)
- No session persistence or transcript logging by default

## Runtime dependencies

BAISH checks these at startup and exits with an error if any are missing:

- bash >= 4
- GNU coreutils, sed, awk/gawk, grep
- curl, jq, fzf, bat

Dev/test dependency:

- bats (only required for running tests)

## Quick start

Run BAISH:

```bash
./bin/baish
```

In an interactive terminal you'll see the startup header and the idle prompt with a one-line Status Footer (launch directory · provider · model).

Typical first-run flow:

1. Start BAISH
2. Optionally run `/provider` to pick a provider
3. Run `/connect`
4. Pick a model via fzf
5. Enter chat prompts or use slash commands

Copilot auth:

- COPILOT_GITHUB_TOKEN is preferred for Copilot; fallback order: GH_TOKEN, GITHUB_TOKEN.
- If no env token is set, follow the device-flow instructions shown by BAISH.

Example:

```text
❯ /connect
❯ Inspect this repository and summarize the current tool support.
```

### Docker

A Dockerfile is included that installs BAISH and common Bash tooling (bats, git, make, gh). The image runs BAISH as a non-root "baish" user.

Build aligned to your host UID/GID so bind mounts remain writable:

```bash
docker build \
  --build-arg BAISH_UID="$(id -u)" \
  --build-arg BAISH_GID="$(id -g)" \
  -t baish .
```

If you use Ghostty and want the container to recognize `TERM=xterm-ghostty`, export the host terminfo entry and inject it at build time:

```bash
GHOSTTY_TERMINFO_B64="$(infocmp -x xterm-ghostty | base64 -w0)"
docker build \
  --build-arg BAISH_UID="$(id -u)" \
  --build-arg BAISH_GID="$(id -g)" \
  --build-arg GHOSTTY_TERMINFO_B64="$GHOSTTY_TERMINFO_B64" \
  -t baish .
```

This compiles the Ghostty terminfo into the image via `tic`, so the container can safely run with `TERM=xterm-ghostty`.

Launch helper:

```bash
baishc() {
  mkdir -p "$HOME/.baish"
  docker run --rm -it \
    -v "$PWD:/workspace" \
    -v "$HOME/.baish:/home/baish/.baish" \
    baish
}
```

This mounts the current directory at /workspace and your BAISH state at /home/baish/.baish.

For Ghostty, pass the matching terminal type through to the container:

```bash
docker run --rm -it \
  -v "$PWD:/workspace" \
  -v "$HOME/.baish:/home/baish/.baish" \
  -e TERM=xterm-ghostty \
  -e COLORTERM=truecolor \
  baish
```

## Status Footer

The interactive idle screen shows a single-line Status Footer with:

- launch directory
- provider label
- model id

Behavior: interactive-only, redraws on prompt/resize, and uses fallbacks when values cannot be resolved (e.g. `?`, `unknown provider`, `no model`). The footer truncates fields left-to-right to remain one line.

## Multiline drafts

BAISH builds a message draft (not a single physical line):

- Enter submits the current draft
- A configured newline-insert key adds a physical newline without sending
- Embedded newlines and trailing whitespace are preserved
- Whitespace-only drafts are ignored

First-release multiline support targets Kitty and Ghostty. In Docker, Ghostty support requires the `xterm-ghostty` terminfo entry to be installed in the image as described above. Use the manual verifier if needed:

```bash
./scripts/verify-multiline-key.sh observe
./scripts/verify-multiline-key.sh poc
```

Exit with `/quit` (alias: `/exit`).

## Providers

Providers are discovered from lib/providers/*.sh and validated at startup.

- GitHub Copilot (default)
  - Use BAISH_PROVIDER=copilot to set explicitly
  - Auth via COPILOT_GITHUB_TOKEN / GH_TOKEN / GITHUB_TOKEN or device flow

- Kilo Gateway
  - BAISH_PROVIDER=kilo to use
  - KILO_API_KEY overrides saved auth; otherwise ~./baish/auth/kilo.json is used

- Mock (offline)
  - BAISH_PROVIDER=mock for local development, tests, and demos

## Slash commands

Supported commands (colon syntax for arguments):

- /connect — authenticate/connect and choose a model
- /provider — choose provider via fzf
- /model — choose model via fzf
- /new — clear conversation (keeps connection/model/skills)
- /skill:<name> — load a skill file into the session
- /quit, /exit — exit BAISH

Examples:

```text
/skill:tdd
/new /skill:tdd Fix the auth error handling.
```

Slash-command prefixes are parsed from the start of the draft, processed left-to-right, and any remaining text is sent as the user message.

## Skills

Lookup order for a skill named <name>:

1. ./.baish/skills/<name>.md (project-local)
2. ~/.baish/skills/<name>.md (user-global)

Rules:

- Project-local overrides user-global
- Loading is session-only and idempotent
- Skills preserve their loaded order

Example usage:

```text
❯ /skill:tdd Implement the next failing test.
```

## Configuration (env vars)

- BAISH_PROVIDER — startup default provider (default: copilot)
- BAISH_MODEL — startup model override
- COPILOT_GITHUB_TOKEN, GH_TOKEN, GITHUB_TOKEN — Copilot token inputs
- KILO_API_KEY — Kilo Gateway API key for the current process
- BAISH_MAX_TOOL_ROUNDS — max tool rounds per request (default: 20)
- BAISH_MAX_TOOL_CALLS — max tool calls per request (default: 100)
- BAISH_BASH_TIMEOUT — shell tool timeout seconds (default: 120)
- BAISH_DEBUG — set to 1 to enable metadata-only debug logs
- BAISH_STREAMING — set to 0 to disable streaming and force synchronous mode (default: 1)

Examples:

```bash
BAISH_PROVIDER=mock ./bin/baish
BAISH_MODEL=gpt-4.1 ./bin/baish
COPILOT_GITHUB_TOKEN=... ./bin/baish
BAISH_DEBUG=1 ./bin/baish
```

Interactive /provider, /connect, and /model choices update persisted state and override startup env defaults for the running process.

## State and logs

State is stored under ~/.baish/:

- auth/ (copilot.json, kilo.json)
- state.json
- logs/ (created only when BAISH_DEBUG=1)
- skills/

Notes:

- Auth files are JSON and written with restrictive permissions
- In env-token Copilot mode BAISH persists metadata-only auth state and does not store raw env tokens or exchanged bearer tokens
- In env-token Kilo mode BAISH avoids overwriting ~/.baish/auth/kilo.json
- Debug logs are metadata-only; full transcripts are not persisted by default

## Testing

Run tests with Bats:

```bash
bats test/*.bats
```

Useful syntax check:

```bash
bash -n bin/baish lib/*.sh lib/providers/*.sh test/test_helper.bash
```

## Copilot status

See docs/copilot-research.md for implementation notes. Key points:

- Supports GitHub device flow or env-supplied token followed by /copilot_internal/v2/token
- Derives runtime Copilot API base from exchanged token
- Persists minimal auth state under ~/.baish/auth/
- Interactive model selection via fzf
- Routes across multiple Copilot model-family endpoints
- Streaming chat with real-time thinking and text output (copilot, kilo, mock)

Live end-to-end validation requires access to a real Copilot account.

## Limitations (V1)

- GNU/Linux only
- Readline-style UI (no full-screen TUI)
- No approval prompts for tool execution
- No session persistence or transcript logging by default
- No automatic repo indexing
- No binary file read/write support in V1
