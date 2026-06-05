# BAISH Implementation Document

This document captures the architecture, flows, and key implementation details of BAISH - a Bash-first terminal AI coding agent.

## Overview

BAISH is an interactive readline-style terminal AI coding agent for GNU/Linux. It provides:
- Multi-provider LLM support (GitHub Copilot, Kilo Gateway and a Mock Provider for tests)
- Slash commands
- File/shell tool execution via LLM tool calls
- Skills system for extending agent behavior
- Path completion for file references


## Provider Interface Contract

All providers must implement these functions:

```bash
provider_<id>_metadata()    # Returns JSON: {id, label, desc, selectable, auth_env_var?}
provider_<id>_auth()        # Authenticates and persists credentials
provider_<id>_list_models() # Returns JSON array of models
provider_<id>_chat()        # Sends chat request, returns {assistant_text, tool_calls}
provider_<id>_has_env_auth() # Optional: checks for env-based auth
```

### Provider Discovery Mechanism

- Scans a "providers" folder for `.sh` files
- Sources each file in temporary context
- Detects newly-declared `provider_<id>_*` functions
- Validates required actions exist
- Registers providers in `BAISH_PROVIDER_IDS` array


**Completion (Tab key):**
- Token starts with `@` → path completion (delegates to bash filesystem)
- Token starts with `/` → slash command completion
- Cycles through multiple candidates

## Slash Commands

| Command | Handler | Behavior |
|---------|---------|----------|
| `/connect` | baish_slash_connect_current_provider | Auth current provider, pick model |
| `/provider` | baish_slash_select_provider | fzf provider picker, then connect |
| `/model` | baish_slash_model_select_interactive | fzf model picker |
| `/new` | baish_session_reset_context_window | Clear messages |
| `/skill:<name>` | baish_skill_load | Load skill into session |
| `/quit` / `/exit` | Sets BAISH_SESSION_EXIT_REQUESTED=1 | Exit loop |

**Skill Loading:**
1. Check `./.baish/skills/<name>/SKILL.md`
2. Check `~/.baish/skills/<name>/SKILL.md`
3. Load content into session arrays: `BAISH_SESSION_SKILL_NAMES`, `BAISH_SESSION_SKILL_CONTENTS`
4. Skills are prepended as system messages in requests

## Agent Conversation Loop (lib/agent/run-loop.sh)

```
baish_agent_run_user_message(user_text)
    ├── baish_agent_ensure_connection() - ensure auth exists
    ├── baish_agent_append_user_message() - add to session
    └── While tool_calls exist:
            ├── baish_context_build_request_json() - assemble payload
            ├── baish_agent_provider_chat_capture() - call provider
            ├── baish_agent_append_assistant_response() - save response
            ├── Print assistant_text via gum format
            └── For each tool_call:
                    ├── baish_tool_execute_json() - run tool
                    ├── baish_agent_append_tool_result() - save result
                    └── Print tool result (summary only for read/tools)
```

**Limits:**
- `BAISH_MAX_TOOL_ROUNDS` (default: 20) - max conversation rounds
- `BAISH_MAX_TOOL_CALLS` (default: 100) - max total tool calls
- `BAISH_BASH_TIMEOUT` (default: 120s) - shell command timeout

## Tools Implementation

All tools return standardized JSON via `baish_tool_success_json()` or `baish_tool_error_json()`:

```json
// Success
{ok: true, tool: "<name>", data: {...}}

// Error
{ok: false, tool: "<name>", error: {code: "<string>", message: "<string>"}}
```

### Tools

| Tool | Arguments | Implementation |
|------|-----------|----------------|
| `read` | `{path, offset?, limit?}` | Read file with optional line range |
| `write` | `{path, content}` | Atomic write (temp file + rename) |
| `edit` | `{path, edits: [{oldText, newText}]}` | Exact unique text replacement |
| `bash` | `{command, env?}` | Execute in launch directory with timeout |

**Tool Execution:**
- Called from agent loop after LLM response
- Results stored in session messages with role=tool
- Subsequent requests include previous tool results

## State Management (lib/state.sh)

**Directory Structure:**
```
~/.baish/
├── state.json           # selected_provider, selected_model
├── auth/
│   ├── copilot.json     # (metadata only, no raw tokens)
│   └── kilo.json        # api_key
└── skills/              # user-global skills
```


## Display/UI (lib/agent/display.sh)

- Colored output via ANSI codes
- Unicode icons for tools (📖 read, ✏️ edit, 📝 write, ⚙️ bash)
- Unicode icons for phases (📖 inspect, 🔧 use)
- Gum markdown rendering for assistant responses
- Thinking spinner during LLM calls

## Configuration

| Variable | Default | Purpose |
|----------|---------|---------|
| `BAISH_MAX_TOOL_ROUNDS` | `20` | Tool loop limit |
| `BAISH_MAX_TOOL_CALLS` | `100` | Total tool calls limit |
| `BAISH_BASH_TIMEOUT` | `120` | Shell execution timeout |
| `BAISH_DEBUG` | `0` | Enable debug logs |

## Dependencies

- **Runtime:** bash >= 5, GNU coreutils, sed, awk/gawk, grep, curl, jq, fzf, gum
- **Dev/Test:** bats

## Error Handling Patterns

1. **Auth errors:** Detect via stderr patterns, auto-reconnect on first request
2. **Context overflow:** Detect via stderr patterns, show guidance message
3. **Tool errors:** Return structured error JSON, continue execution
4. **HTTP errors:** Extract message, include status code

## Key Implementation Details

### Multiline Drafts
- Continuation marker inserted via configured key combo
- Stored in `draft` variable until Enter submits
- Common escape sequences handled for various terminals

### Path Completion
- Triggered by token starting with `@`
- Uses glob patterns for matching
- Directories append `/`, files append space
- Joins paths for display in tool round footer

### Session-Only Skills
- Skills loaded into process memory (arrays)
- Not persisted to disk
- Idempotent loading (skip if already loaded)

### Atomic File Writes
- Temp file in same directory as target
- Preserve existing file permissions (mode)
- Rename for atomicity

### Edit Uniqueness Check
- `baish_tool_edit_plan_json()` validates:
  - `oldText` appears exactly once
  - No overlapping edits
  - Valid JSON structure