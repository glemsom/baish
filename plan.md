# Implementation plan: phase-based tool round rendering

## Goal
Replace the current generic `Tools` header with a compact, more transparent phase summary:

```text
╭─ Phase: Inspect core runtime flow
│ Files: README.md, lib/main.sh, lib/agent.sh, ...
╰─ ✅ completed
```

The new layout should:
- expose the agent's current intent as a short phase line
- list all files actually read during the round
- keep the display compact by rendering files as a wrapped comma-separated list rather than one file per line
- preserve the existing per-tool result details for non-read tools when useful

## Non-goals
- Do not expose hidden chain-of-thought or raw internal reasoning.
- Do not redesign the full transcript format.
- Do not remove the structured tool results stored in session history.
- Do not change tool execution semantics.

## Proposed UX

### Read-only round
If a tool round contains only `read` calls, render one grouped phase block:

```text
╭─ Phase: Inspect core runtime flow
│ Files: README.md, lib/main.sh, lib/agent.sh, lib/context.sh, lib/tools.sh
╰─ ✅ completed
```

### Mixed round
If a round mixes `read` with `bash`, `edit`, or `write`, keep the existing per-tool rows for the mutating/output-producing tools, but group the read calls into a single files line near the top:

```text
╭─ Phase: Compare implementation with tests
│ Files: lib/agent.sh, test/context_agent.bats, test/tools.bats
│ ⚙️ bash  bats test/context_agent.bats
│   ↳ completed with output
╰─ ✅ completed
```

### Fallback when no phase text is available
Use a deterministic default instead of blank text:
- read-only rounds: `Inspect files`
- mixed rounds: `Use tools`

## Design decisions

### 1. Source of phase text
Prefer a short, explicit phase string from the assistant response instead of trying to infer intent from filenames alone.

Recommended response shape extension:
- add an optional top-level `phase` string to provider chat responses
- validate and persist it alongside `assistant_text` and `tool_calls`

Why:
- the provider already decides the next tool batch
- the UI should display an explicit intent label, not a heuristic guess
- this avoids inventing reasoning text after the fact

Fallback if the provider does not send `phase`:
- render a deterministic default label as described above

### 2. Group reads at render time, not at execution time
Do not change how tool calls are executed or stored. Instead, aggregate consecutive read calls inside the current round only for display.

Why:
- lowest-risk change
- preserves existing session/tool-result structure
- avoids changing provider contracts beyond the optional `phase` field

### 3. List files exactly as read
For the grouped `Files:` line:
- include every read target path in encounter order
- deduplicate exact duplicate paths within the same round to reduce noise
- do not show line ranges in the compact default view
- keep line ranges available in a verbose/debug mode later if needed

Why:
- matches the transparency requirement
- keeps the default layout compact
- leaves room for future expansion without blocking this change

## Implementation steps

### Step 1: Extend the provider response contract
Update chat-response validation in `/workspace/lib/agent.sh`:
- extend `baish_provider_chat_response_valid()` to allow optional `.phase` when present as a non-empty string
- extend `baish_agent_append_assistant_response()` to persist `.phase` in the assistant session message

Also update any mock/provider helpers that construct chat responses so tests can exercise the new field.

### Step 2: Add read-round aggregation helpers
Add new helper functions in `/workspace/lib/agent.sh` for round rendering:
- collect read tool calls from the current response
- extract their `.arguments.path` values safely
- deduplicate paths while preserving first-seen order
- join them into a comma-separated wrapped `Files:` line
- decide whether the round is `read-only` or `mixed`
- choose the phase label: response `.phase` if present, otherwise fallback text

Suggested helper names:
- `baish_agent_phase_label()`
- `baish_agent_collect_read_paths_json()`
- `baish_agent_join_paths_for_display()`
- `baish_agent_round_is_read_only()`

### Step 3: Replace the round header/footer rendering API
Refactor the current rendering entry points in `/workspace/lib/agent.sh`:
- replace `baish_agent_print_tool_round_start()` with a phase-aware header printer
- add a dedicated printer for the grouped files line
- keep `baish_agent_print_tool_round_end()` mostly as-is

Suggested rendering API:
- `baish_agent_print_phase_round_start "$phase_label"`
- `baish_agent_print_phase_round_files "$joined_paths"`
- `baish_agent_print_tool_round_item ...` for non-read tools that still deserve row-by-row display

### Step 4: Update round rendering flow in `baish_agent_run_user_message()`
In the main tool-round loop:
- inspect the response's tool calls before executing them
- compute phase label and grouped read paths once per round
- always print the phase header first
- if there are read calls, print a single `Files:` line
- suppress individual `read` rows in the default compact view
- continue printing individual rows for `bash`, `edit`, and `write`
- preserve result summaries/details for non-read tools
- preserve round status behavior (`✅ completed`, `❌ ...`)

Important behavior choice:
- in a read-only round, the grouped `Files:` line is the only body content
- in mixed rounds, `Files:` appears once, then non-read tool rows follow

### Step 5: Update mock provider scenarios for tests
Update `/workspace/lib/providers/mock.sh` so mock chat responses can include a `phase` value.

Add or adjust scenarios used by `/workspace/test/context_agent.bats` to cover:
- read-only rounds with a phase label
- mixed rounds with both grouped files and non-read tool rows
- fallback rendering when no phase is provided

## Test plan

### Unit-style tests in `/workspace/test/context_agent.bats`
Add tests for:

1. **response validation accepts optional phase**
- valid when `.phase` is absent
- valid when `.phase` is a non-empty string
- invalid when `.phase` is not a string or is empty

2. **read path collection preserves order and deduplicates**
- multiple read calls become one ordered path list
- duplicate reads of the same path appear once in `Files:`

3. **phase fallback selection**
- read-only round without `.phase` => `Phase: Inspect files`
- mixed round without `.phase` => `Phase: Use tools`

4. **read-only round rendering**
Assert compact output contains:
- `╭─ Phase: ...`
- `│ Files: ...`
- no per-read `📖 read` rows
- `╰─ ✅ completed`

5. **mixed round rendering**
Assert output contains:
- grouped `Files:` line for reads
- per-tool rows for `bash`/`edit`/`write`
- existing output preview behavior remains intact

6. **existing non-read rendering still works**
Keep or adjust current tests so bash failure/success rendering remains covered.

## File-level change list
- `/workspace/lib/agent.sh`
  - response validation
  - assistant message persistence
  - new phase/files render helpers
  - main round rendering changes
- `/workspace/lib/providers/mock.sh`
  - mock response shape and scenarios
- `/workspace/test/context_agent.bats`
  - new coverage for phase/files rendering

## Rollout order
1. Add validation + mock support for optional `phase`
2. Add helper functions for phase label and read-path grouping
3. Refactor round rendering to use phase/files blocks
4. Update and expand tests
5. Run targeted bats tests

## Verification commands
Run at least:

```bash
bats test/context_agent.bats
```

Optionally run the full suite if the targeted test passes:

```bash
bats test/*.bats
```

## Open question
Should grouped `Files:` output include repeated reads as `path ×N` instead of deduplicating?

Recommendation for this change:
- start with deduplicated paths only
- add counts later only if debugging shows repeated reads matter to users
