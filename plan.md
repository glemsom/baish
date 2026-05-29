# Rich tool-output modernization plan

## Goal

Replace BAISH's current raw tool-call and tool-result terminal output with a rich, emoji-based presentation that looks modern in terminals like Ghostty and Kitty.

This change affects only the human-facing terminal rendering. The full tool arguments and full tool results must remain unchanged in the conversation state sent back to the model.

## Explicit product decision

We will support **rich terminals only** for this feature.

That means:

- use emoji and UTF-8 box-drawing characters by default
- use ANSI color and text styling by default
- do **not** add ASCII fallback mode
- do **not** add a separate plain/compact style switch in this iteration

## Current behavior

In `lib/agent.sh`, BAISH currently prints raw tool payloads directly:

- `tool> <tool-name> <full-json-arguments>`
- `tool_result> <full-json-result>`

This is functionally transparent but visually noisy, especially for:

- `edit` calls with large replacement payloads
- `read` calls with multiple range parameters
- `bash` calls with long shell commands
- successful tool results that do not need full JSON on screen

## Desired terminal UX

### Tool activity block

Render each tool round as a grouped block:

```text
╭─ Tools
│ 📖 read   lib/agent.sh:220-260
│ ✏️ edit   lib/agent.sh (2 replacements)
│ ⚙️ bash   bats test/*.bats
╰─ ✅ completed
```

### Failure example

```text
╭─ Tools
│ ⚙️ bash   bats test/*.bats
╰─ ❌ failed (exit 1)
   ↳ stderr: test/tools.bats:19 ...
```

### Symbol set

Use the following symbols consistently:

- `📖` read
- `✏️` edit
- `📝` write
- `⚙️` bash
- `✅` success
- `❌` failure
- `⚠️` warning
- `↳` detail
- `╭─`, `│`, `╰─` for grouped blocks

## Scope

### In scope

- rich terminal rendering for tool calls
- rich terminal rendering for tool results
- grouped display for one tool round containing one or more tool calls
- concise summaries instead of raw JSON
- short failure details for actionable debugging
- ANSI styling to improve readability

### Out of scope

- changing tool execution semantics
- changing the JSON stored in session messages
- changing provider request/response structure
- changing `docs/adr/0010-untruncated-tool-results.md`
- adding terminal capability detection
- adding fallback modes
- implementing streaming/spinners
- redesigning assistant/user message rendering

## File-level implementation plan

### 1. Add render helpers in `lib/agent.sh` or a small new helper file

Introduce a small set of terminal-rendering functions, for example:

- `baish_agent_style_*` helpers for ANSI formatting
- `baish_agent_tool_icon()`
- `baish_agent_render_tool_call_summary()`
- `baish_agent_render_tool_result_summary()`
- `baish_agent_print_tool_round_start()`
- `baish_agent_print_tool_round_item()`
- `baish_agent_print_tool_round_end()`

Keep these helpers presentation-only.

### 2. Summarize tool-call arguments by tool type

Render only the fields users care about.

#### `read`
Input JSON:
- `path`
- optional `offset`
- optional `limit`

Display:
- `📖 read   <path>`
- if offset/limit are present, show a human-readable line range

Examples:
- `📖 read   lib/agent.sh`
- `📖 read   lib/agent.sh:220-260`
- `📖 read   README.md:1-120`

Range rule:
- if `offset` and `limit` are present and `limit > 0`, render `start-end`
- if only `offset` is present, render `start+`
- if `limit == 0`, render `start+`

#### `edit`
Input JSON:
- `path`
- `edits[]`

Display:
- `✏️ edit   <path> (<n> replacements)`

Do not print `oldText`/`newText` inline.

#### `write`
Input JSON:
- `path`
- `content`

Display:
- `📝 write  <path>`

Do not print content inline.

#### `bash`
Input JSON:
- `command`

Display:
- `⚙️ bash   <command-preview>`

Rules:
- normalize newlines in preview to spaces
- trim leading/trailing whitespace
- truncate long commands to a reasonable width, e.g. around 100 visible chars
- append ellipsis when truncated

## Result rendering rules

### Success cases

Show short summaries only.

#### `read` success
Use result fields like:
- `data.path`
- `data.line_count`
- optional `data.offset`
- optional `data.limit`

Display example:
- `↳ 41 lines`

#### `edit` success
Use:
- `data.path`
- `data.replacements`
- `data.bytes`

Display example:
- `↳ updated (2 replacements, 913 bytes)`

#### `write` success
Use:
- `data.path`
- `data.created`
- `data.overwritten`
- `data.bytes`

Display examples:
- `↳ created (481 bytes)`
- `↳ overwritten (913 bytes)`

#### `bash` success
Use:
- `data.exit_code`
- `data.timed_out`
- optionally detect presence of stdout/stderr

Display examples:
- `↳ completed (exit 0)`
- `↳ completed with output`

Do not dump full stdout/stderr on success.

### Failure cases

When `result.ok == false`, show:
- tool name
- error code
- short message

Display example:
- `╰─ ❌ edit failed`
- `   ↳ old_text_not_found: edit entry 0 oldText was not found exactly once.`

### `bash` non-zero exit
A `bash` tool call may still return `ok: true` while containing `exit_code != 0` inside `data`.
Treat that as a visible failure in terminal rendering.

Display example:
- `╰─ ❌ bash failed (exit 1)`
- `   ↳ stderr: test/tools.bats:19 ...`

Rules:
- show the first non-empty stderr line if available
- otherwise show the first non-empty stdout line
- trim and truncate preview lines

## Rendering structure in the agent loop

Update `baish_agent_run_user_message()` in `lib/agent.sh`.

Current flow:
- print assistant text
- iterate tool calls
- print raw `tool>` line
- execute tool
- print raw `tool_result>` line

New flow:

1. When a response contains tool calls, print a tool-round header once:
   - `╭─ Tools`
2. For each tool call:
   - print one summarized item line:
     - `│ 📖 read   lib/agent.sh:220-260`
   - execute the tool
   - accumulate success/failure state for round summary
   - optionally capture one short detail line for failures
3. After all tool calls in the round finish, print one footer:
   - success: `╰─ ✅ completed`
   - failure: `╰─ ❌ failed`
4. Print up to one or a few detail lines under the footer when useful:
   - stderr preview
   - validation error message
   - timeout note

Important: keep `baish_agent_append_tool_result()` unchanged in behavior.

## ANSI styling plan

Use ANSI styling to visually separate the block.

Suggested styles:

- box-drawing characters: dim
- tool icon + tool name: cyan or bright blue
- path/command preview: bold white
- success footer: green
- failure footer: red
- warning footer: yellow
- detail lines: dim foreground

Keep the styling centralized in helpers so the agent loop remains readable.

## Suggested helper behavior

### `baish_agent_tool_icon(tool_name)`
Returns the emoji icon for a known tool.

### `baish_agent_summarize_tool_call(tool_name, tool_arguments_json)`
Returns the human-facing one-line summary text for the call.

### `baish_agent_summarize_tool_result(tool_name, tool_result_json)`
Returns structured rendering metadata, for example:
- round status: success/failure/warning
- footer text
- optional detail lines

This can return JSON internally if that makes shell composition easier.

### `baish_agent_truncate_preview(text, max_width)`
Utility for command previews and stderr/stdout snippets.

### `baish_agent_first_non_empty_line(text)`
Utility for extracting an actionable error preview.

## Edge cases

### Empty or malformed arguments
If summarization cannot parse arguments cleanly, fall back to a safe generic line:

- `│ ⚙️ bash   [invalid arguments]`
- `│ ✏️ edit   [invalid arguments]`

Do not let presentation failures break tool execution.

### Unknown tool names
If a new tool appears later, render:
- `│ 🛠️ <tool-name>`

### Long paths
Allow long paths, but consider truncating only if they become visually disruptive. Keep the first implementation simple and avoid complex width calculations unless needed.

### Multi-line shell commands
Flatten newlines to spaces in the preview.

### Large failure messages
Show only the first useful line in the terminal summary.

## Documentation updates

Update `README.md` after implementation to reflect the richer tool rendering behavior.

Suggested note:
- BAISH renders tool activity in a rich, emoji-based terminal format instead of dumping raw tool JSON to the screen.

Do not change ADRs unless the implementation introduces a real product-level decision beyond presentation.

## Testing plan

Add or update tests in `test/context_agent.bats` or `test/tools.bats` if those are the best fit after inspecting existing coverage.

Test cases should cover at least:

1. `read` tool call renders a summarized path/range line
2. `edit` tool call renders replacement count, not raw payload
3. `write` tool call renders path only, not content
4. `bash` tool call renders command preview
5. successful tool round prints `╭─ Tools` and `╰─ ✅ completed`
6. failing `edit` prints `╰─ ❌ failed` with detail line
7. `bash` with non-zero exit prints failure footer and stderr preview
8. session message storage remains unchanged and still contains full JSON tool results

Prefer tests that assert stdout rendering from the agent loop, not just helper internals.

## Verification steps

After implementation:

1. run shell syntax checks
2. run focused Bats tests for agent/tool rendering
3. run the full Bats suite if the focused tests pass

Commands:

```bash
bash -n bin/baish lib/*.sh lib/providers/*.sh test/test_helper.bash
bats test/*.bats
```

## Delivery sequence

1. add render/style helper functions
2. replace raw tool printing in `lib/agent.sh`
3. handle success/failure round footers
4. add/update tests
5. update `README.md`
6. run verification commands

## Acceptance criteria

This feature is complete when:

- raw `tool>` and `tool_result>` JSON are no longer printed to the terminal
- tool activity is shown in rich grouped blocks
- emoji, box drawing, and ANSI styling are used by default
- successful tool output is concise
- failures are short but actionable
- full tool JSON still flows unchanged into the model conversation state
- tests cover the new rendering behavior
