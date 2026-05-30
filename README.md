# BAISH

BAISH is a Bash-first terminal AI coding agent for GNU/Linux.

V1 is a readline-style terminal app, not a full-screen TUI. It supports provider-backed chat, slash commands, explicit skills, and autonomous file/shell tools.

Tool activity is rendered in rich terminal blocks with emoji, box-drawing characters, ANSI styling, and concise per-tool summaries instead of raw tool JSON dumps.

## V1 scope

- GNU/Linux only
- Bash-first implementation
- Readline-style prompt
- Dynamic multi-provider discovery from `lib/providers/*.sh`
- GitHub Copilot, Kilo Gateway, and Mock providers
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

In an interactive terminal you should see the startup header, then the idle prompt with the Status Footer:

```text
BAISH ready. Use /quit to exit.
❯
───────────────────────────────────────────────────
~/project · GitHub Copilot · gpt-5
```

Typical first-run flow:

1. Start BAISH.
2. Run `/provider` to choose a provider, or keep the default provider.
3. Run `/connect`.
4. Pick a model through `fzf`.
5. Enter a normal prompt.

Copilot auth details:

- If `COPILOT_GITHUB_TOKEN` is set, BAISH uses it as the GitHub token input to the normal Copilot token-exchange flow.
- Otherwise, BAISH falls back to `GH_TOKEN`, then `GITHUB_TOKEN`, with the same exchange flow.
- If no env token is set, follow the device-flow instructions in the terminal.

Example:

```text
❯ /connect
❯ Inspect this repository and summarize the current tool support.
```

### Status Footer

The interactive idle screen shows a one-line Status Footer below the active input line.

It contains:

- Launch Directory
- Provider Label
- Model ID

Behavior:

- interactive-only; non-interactive mode stays footer-free
- redraws whenever BAISH returns to the idle prompt
- reflows on terminal resize
- uses explicit fallbacks when values cannot be resolved:
  - launch directory: `?`
  - provider label: `unknown provider`
  - model: `no model`
- stays one line by truncating Launch Directory first, then Model ID, then Provider Label

### Multiline drafts

BAISH composes a message draft, not just a single physical line.

- `Enter` submits the current draft.
- A dedicated newline-insert key continues the draft onto the next physical line without sending it yet.
- Embedded newlines and trailing whitespace/newlines are preserved when the draft is sent.
- Whitespace-only drafts are ignored.

First-release multiline support is currently targeted at:

- Kitty
- Ghostty

In interactive mode BAISH requests the Kitty keyboard protocol and binds common newline-insert sequences used by those terminals, including Ghostty's CSI-u `Shift+Enter` sequence.

Because terminal key handling varies, use the manual verification harness to confirm your setup:

```bash
./scripts/verify-multiline-key.sh observe
./scripts/verify-multiline-key.sh poc
```

Unsupported terminals still work, but multiline newline-insert behavior is not guaranteed there.

Exit with:

```text
/quit
```

`/exit` is an alias for `/quit`.

## Providers

BAISH discovers providers dynamically from `lib/providers/*.sh` at startup and fails fast if a provider contract is invalid.

### GitHub Copilot

Use the default provider or set it explicitly:

```bash
BAISH_PROVIDER=copilot ./bin/baish
```

### Kilo Gateway

Kilo Gateway is a first-class provider with OpenAI-compatible model listing, chat completions, and tool calling.

```bash
BAISH_PROVIDER=kilo ./bin/baish
```

Auth behavior:

- `KILO_API_KEY` overrides saved Kilo auth for the current BAISH process.
- Otherwise BAISH uses `~/.baish/auth/kilo.json` when available.
- If no saved key exists, BAISH prompts with hidden input.

### Offline mock provider

For offline demos and tests, run BAISH with the mock provider:

```bash
BAISH_PROVIDER=mock ./bin/baish
```

Then connect and chat as usual:

```text
❯ /connect
❯ List the current skills behavior.
```

The mock provider is intended for local development, Bats coverage, and agent-loop work without network access.

## Slash commands

Supported slash commands:

- `/connect` — authenticate/connect the active provider and choose a model
- `/provider` — choose a provider interactively with `fzf`
- `/new` — start a fresh chat by clearing the current conversation messages while keeping the current connection, model, and loaded skills
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
/new /skill:tdd /skill:pirate Fix the auth error handling.
```

The slash-command prefix is parsed only from the start of the submitted draft. The separator between the slash-command prefix and the remaining chat text may contain spaces or newlines, and that separator is trimmed before the chat text is sent.

Examples:

```text
/new Fix bug
/new
Fix bug
/skill:tdd

Investigate auth
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
❯ /skill:tdd Implement the next failing test.
```

## Configuration

BAISH uses environment variables for configuration in V1.

- `BAISH_PROVIDER` — startup default provider, default `copilot`
- `BAISH_MODEL` — startup model override; wins over the persisted model until an interactive choice overrides it for the current process
- `COPILOT_GITHUB_TOKEN` — preferred GitHub token input for Copilot `/connect`, `/model`, and chat; BAISH exchanges it for a runtime Copilot token
- `GH_TOKEN` — fallback GitHub token input when `COPILOT_GITHUB_TOKEN` is unset
- `GITHUB_TOKEN` — fallback GitHub token input when `COPILOT_GITHUB_TOKEN` and `GH_TOKEN` are unset
- `KILO_API_KEY` — Kilo Gateway API key for the current process
- `BAISH_MAX_TOOL_ROUNDS` — max tool rounds per request, default `20`
- `BAISH_MAX_TOOL_CALLS` — max tool calls per request, default `100`
- `BAISH_BASH_TIMEOUT` — shell tool timeout in seconds, default `120`
- `BAISH_DEBUG` — set to `1` to enable metadata-only debug logging

Examples:

```bash
BAISH_PROVIDER=mock ./bin/baish
BAISH_MODEL=gpt-4.1 ./bin/baish
COPILOT_GITHUB_TOKEN=... ./bin/baish
BAISH_DEBUG=1 ./bin/baish
```

Interactive `/provider`, `/connect`, and `/model` choices update persisted selection and override startup env defaults for the current BAISH process.

## State and logs

BAISH stores its state under `~/.baish/`:

```text
~/.baish/
  auth/
    copilot.json
    kilo.json
  state.json
  logs/
  skills/
```

Notes:

- Provider auth files are plain JSON.
- Auth/token files are written with restrictive permissions.
- In env-token Copilot mode, BAISH persists metadata-only auth state and does not store `COPILOT_GITHUB_TOKEN`, `GH_TOKEN`, `GITHUB_TOKEN`, or the exchanged Copilot bearer token in `~/.baish/auth/copilot.json`.
- In env-token Kilo mode, BAISH does not overwrite `~/.baish/auth/kilo.json`.
- `logs/` is only created when `BAISH_DEBUG=1`.
- Debug logs are metadata-only and do not persist full transcripts by default.

## Testing

Run the shell test suite with Bats:

```bash
bats test/*.bats
```

Focused multiline/parser coverage:

```bash
bats test/readline_slash.bats
```

Useful syntax check:

```bash
bash -n bin/baish lib/*.sh lib/providers/*.sh test/test_helper.bash
```

## Copilot status

Copilot support in V1 follows the research documented in `docs/copilot-research.md`:

- GitHub device flow or env-supplied GitHub token input, both followed by `/copilot_internal/v2/token`
- runtime Copilot API base derived from the exchanged token
- persisted auth state under `~/.baish/auth/`
- interactive model selection through `fzf`
- model-family routing across `/chat/completions`, `/responses`, and `/v1/messages`
- best-effort model policy enablement before chat
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
