# BAISH

BAISH is a Bash-first terminal AI coding agent for GNU/Linux.

V1 is a readline-style terminal app, not a full-screen TUI. It supports provider-backed chat, slash commands, explicit skills, and autonomous file/shell tools.

## V1 scope

- GNU/Linux only
- Bash-first implementation
- Readline-style prompt
- GitHub Copilot as the real provider
- Mock provider for offline demos/tests
- Autonomous tool execution with no approval loop
- No session persistence between runs
- No transcript logging by default
- No automatic tests/builds/verification unless the developer explicitly asks

## Runtime dependencies

BAISH checks these at startup and fails fast if any are missing or unsupported:

- GNU/Linux
- `bash >= 4`
- GNU `coreutils`
- GNU `sed`
- GNU `awk` or `gawk`
- GNU `grep`
- `curl`
- `jq`
- `fzf`
- `bat`

Development/test dependency:

- `bats`

`bats` is only needed for tests, not for runtime.

## Quick start

```bash
./bin/baish
```

You should see:

```text
BAISH ready. Use /quit to exit.
```

Typical first-run flow with Copilot:

1. Start BAISH.
2. Run `/connect`.
3. If `GH_TOKEN` or `GITHUB_TOKEN` is set, BAISH uses it directly for Copilot auth.
4. Otherwise, follow the device-flow instructions in the terminal.
5. Pick a model through `fzf`.
6. Enter a normal prompt.

Example:

```text
baish> /connect
baish> Inspect this repository and summarize the current tool support.
```

Exit with:

```text
/quit
```

`/exit` is an alias for `/quit`.

## Offline mock provider

For offline demos and tests, run BAISH with the mock provider:

```bash
BAISH_PROVIDER=mock ./bin/baish
```

Then connect and chat as usual:

```text
baish> /connect
baish> List the current skills behavior.
```

The mock provider is intended for local development, Bats coverage, and agent-loop work without network access.

## Slash commands

Supported slash commands:

- `/connect` — authenticate/connect the active provider and choose a model
- `/model` — choose a model interactively with `fzf`
- `/skill:<name>` — load a skill into the current BAISH process
- `/quit` — exit BAISH
- `/exit` — alias for `/quit`

V1 uses colon syntax for slash-command arguments.

Valid:

```text
/skill:tdd
```

Not supported in V1:

```text
/skill tdd
```

Multiple slash commands can prefix one chat message:

```text
/skill:tdd /skill:pirate Fix the auth error handling.
```

BAISH processes slash commands from left to right, then sends any remaining text as the user message.

## Skills

Skill lookup order:

1. `./.baish/skills/<name>.md`
2. `~/.baish/skills/<name>.md`

Rules:

- Project-local skills override user-global skills.
- Loaded skills are session-only for the current BAISH process.
- Loading the same skill twice is idempotent.
- Skills stay in the order they were loaded.

Example skill files:

```text
./.baish/skills/tdd.md
~/.baish/skills/reviewer.md
```

Example usage:

```text
baish> /skill:tdd Implement the next failing test.
```

## Configuration

BAISH uses environment variables for configuration in V1.

- `BAISH_PROVIDER` — active provider, default `copilot`
- `BAISH_MODEL` — process-local model override; wins over the persisted model
- `GH_TOKEN` — preferred direct GitHub Copilot bearer token for `/connect`, `/model`, and chat
- `GITHUB_TOKEN` — fallback direct GitHub Copilot bearer token when `GH_TOKEN` is unset
- `BAISH_MAX_TOOL_ROUNDS` — max tool rounds per request, default `20`
- `BAISH_MAX_TOOL_CALLS` — max tool calls per request, default `100`
- `BAISH_BASH_TIMEOUT` — shell tool timeout in seconds, default `120`
- `BAISH_DEBUG` — set to `1` to enable metadata-only debug logging

Examples:

```bash
BAISH_PROVIDER=mock ./bin/baish
BAISH_MODEL=gpt-4.1 ./bin/baish
GH_TOKEN=... ./bin/baish
BAISH_DEBUG=1 ./bin/baish
```

If `BAISH_MODEL` is set, it stays active for the current process even if `/model` updates the persisted model selection.

## State and logs

BAISH stores its state under `~/.baish/`:

```text
~/.baish/
  auth/
    copilot.json
  state.json
  logs/
  skills/
```

Notes:

- Provider auth files are plain JSON.
- Auth/token files are written with restrictive permissions.
- In env-token Copilot mode, BAISH persists metadata-only auth state and does not store `GH_TOKEN` or `GITHUB_TOKEN` in `~/.baish/auth/copilot.json`.
- `logs/` is only created when `BAISH_DEBUG=1`.
- Debug logs are metadata-only and do not persist full transcripts by default.

## Testing

Run the shell test suite with Bats:

```bash
bats test/*.bats
```

Useful syntax check:

```bash
bash -n bin/baish lib/*.sh lib/providers/*.sh test/test_helper.bash
```

## Copilot status

Copilot support in V1 follows the research documented in `docs/copilot-research.md`:

- direct env-token auth via `GH_TOKEN` or `GITHUB_TOKEN`
- interactive device-flow auth when env tokens are absent
- persisted auth state under `~/.baish/auth/`
- interactive model selection through `fzf`
- non-streaming chat
- provider-native tool/function calling

The repository includes shell-level tests for the Copilot provider wiring, but the research notes an important caveat: live authenticated end-to-end validation depends on access to a real Copilot account.

## V1 limitations

- GNU/Linux only
- No full-screen TUI
- No approval prompts for tool execution
- File and shell tools can operate anywhere the launching user account has permission
- No session persistence between runs
- No transcript logging by default
- No streaming responses
- No automatic repository indexing/summarization
- No automatic verification unless explicitly requested
- No binary file read/write support in V1
