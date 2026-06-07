# PRD: Implement BAISH — Bash-first terminal AI coding agent

**Status:** ready-for-agent
**Created:** 2026-06-05
**Source:** Grilling session with 19 resolved design decisions

## Problem Statement

As a developer working on GNU/Linux, I want a terminal-native AI coding agent that lets me interact with LLMs, read/write/edit files, and execute shell commands — all without leaving my terminal. Existing tools either require a GUI, are tightly coupled to a specific LLM provider, or are heavy IDE integrations. I need something lightweight, provider-agnostic, and built entirely in Bash so I can inspect, modify, and extend it with tools I already have.

## Solution

BAISH — a Bash-first terminal AI coding agent. It provides a readline-style terminal interface with multi-provider LLM support (GitHub Copilot, Kilo Gateway, and a Mock Provider for testing), slash commands for session management, file/shell tool execution via LLM tool calls, a skills system for extending agent behavior, and path completion for file references. Everything runs in Bash with standard GNU coreutils, curl, jq, and gum.

## User Stories

1. As a developer, I want to start BAISH from any project directory so that the agent operates in the correct workspace context
2. As a developer, I want to select an LLM provider interactively so that I can switch between GitHub Copilot and Kilo Gateway
3. As a developer, I want to authenticate with GitHub Copilot via OAuth device flow so that I can use my Copilot subscription without sharing tokens manually
4. As a developer, I want to authenticate with Kilo Gateway using an API key so that I can access hundreds of models through a single endpoint
5. As a developer, I want to select an LLM model from a filtered, grouped list so that I can choose the right model without being overwhelmed by hundreds of options
6. As a developer, I want to type natural language instructions into a readline prompt so that I can communicate with the AI agent conversationally
7. As a developer, I want to enter multi-line input using Alt+Enter so that I can compose complex instructions spanning multiple lines
8. As a developer, I want TAB-completion for file paths (starting with `@`) so that I can reference files quickly without typos
9. As a developer, I want TAB-completion for slash commands (starting with `/`) so that I can discover and invoke commands efficiently
10. As a developer, I want to use the `/connect` command so that I can authenticate the current provider and pick a model
11. As a developer, I want to use the `/provider` command so that I can switch providers using an interactive picker
12. As a developer, I want to use the `/model` command so that I can switch models using an interactive picker
13. As a developer, I want to use the `/new` command so that I can clear conversation history while keeping my provider, model, and loaded skills
14. As a developer, I want to use the `/skill:<name>` command so that I can load project-local or user-global skills into the current session
15. As a developer, I want to use the `/quit` or `/exit` command so that I can cleanly exit the agent
16. As a developer, I want the agent to read files on my behalf so that I can ask it about existing code
17. As a developer, I want the agent to write files on my behalf so that I can create new code
18. As a developer, I want the agent to edit files on my behalf using exact text replacement so that I can modify existing code safely
19. As a developer, I want the agent to execute shell commands on my behalf so that I can run builds, tests, or git operations
20. As a developer, I want to see tool execution results with colored output and icons so that I can track what the agent is doing at a glance
21. As a developer, I want to see a thinking spinner during LLM calls so that I know the agent is working
22. As a developer, I want the agent to execute shell commands with a configurable timeout so that runaway processes do not hang my session
23. As a developer, I want tool calls to execute sequentially so that dependent operations happen in the correct order
24. As a developer, I want the edit tool to validate that oldText appears exactly once so that I avoid accidental mass replacements
25. As a developer, I want the edit tool to detect overlapping edits and reject them so that file corruption is prevented
26. As a developer, I want edit validation errors to tell me exactly why an edit failed so that the LLM can self-correct
27. As a developer, I want file writes to be atomic (temp file + rename) so that I never get partial writes
28. As a developer, I want the agent to automatically handle Copilot token refresh so that I do not need to re-authenticate every hour
29. As a developer, I want the agent to detect context window overflow and guide me to use `/new` so that I can recover gracefully
30. As a developer, I want the agent to auto-reconnect when a Copilot runtime token expires so that the conversation continues uninterrupted
31. As a developer, I want the agent to fail loudly with a prompt when credentials are invalid so that I know to fix my auth
32. As a developer, I want project-local skills to override user-global skills so that I can customize agent behavior per project
33. As a developer, I want skills to persist across `/new` resets so that I do not need to reload them for each conversation
34. As a developer, I want the agent to remember my selected provider and model between sessions so that I do not need to reconfigure each time
35. As a developer, I want BAISH to detect if I already have environment-based auth so that I can skip the interactive auth flow
36. As a developer, I want to configure tool loop limits and timeouts via environment variables so that I can tune the agent for different workflows
37. As a developer, I want to enable debug logging via `BAISH_DEBUG` so that I can troubleshoot issues
38. As a contributor, I want to add new LLM providers by dropping a `.sh` file into `lib/providers/` so that the system is extensible
39. As a contributor, I want the system to detect provider ID collisions and error loudly so that silent overwrites do not cause bugs
40. As a contributor, I want providers to encapsulate their own model-family routing and response normalization so that the shared agent loop stays provider-agnostic
41. As a contributor, I want tool definitions to be passed as parameters to `provider_chat()` so that the agent loop controls which tools are active
42. As a contributor, I want the mock provider available for bats tests so that I can test the agent loop without real LLM calls
43. As a contributor, I want all JSON construction to use `jq -n` so that special characters are handled correctly

## Implementation Decisions

- **Provider interface contract**: All providers implement `provider_<id>_metadata()`, `provider_<id>_auth()`, `provider_<id>_list_models()`, `provider_<id>_chat()`, and optionally `provider_<id>_has_env_auth()`.
- **Provider discovery**: Scans `lib/providers/*.sh` files, sources each, detects newly-declared `provider_<id>_*` functions via `declare -F` before/after diff, validates required functions exist, registers in `BAISH_PROVIDER_IDS` array.
- **Provider ID collision**: If `provider_<id>_metadata` already exists when discovering a new provider with the same ID, the system errors out loudly.
- **Provider encapsulation**: Model-family detection, endpoint routing, and response normalization live entirely inside the provider. The shared agent loop receives a unified `{assistant_text, tool_calls}` shape.
- **Copilot auth model**: Long-lived GitHub token (`gho_*`) is persisted in `~/.baish/auth/copilot.json`. Short-lived Copilot runtime token (`ghc_*`) is held in a process variable, refreshed lazily inside `provider_copilot_chat()` with a 60-second expiry buffer.
- **Kilo Gateway auth model**: API key is prompted, validated, and persisted in `~/.baish/auth/kilo.json`.
- **Model API routing (Copilot)**: All models use Chat Completions (`/chat/completions`). The Responses API endpoint (`/responses`) is not yet confirmed working on `api.githubcopilot.com`. Code for it is preserved but disabled.
- **Model listing (Copilot)**: Fetched dynamically from `GET /models` on `api.githubcopilot.com` using the `gho_*` token when available, falling back to a hardcoded curated list.
- **Model listing (Kilo)**: The `/models` endpoint returns hundreds of models; results are filtered to models with `"chat"` in their features and grouped by provider prefix for interactive display. Full prefixed model IDs (e.g., `anthropic/claude-sonnet-4.5`) are stored and used as-is.
- **Tool calling interface**: Tool calls are normalized to `{"id": "string", "name": "string", "arguments": "string"}` where `arguments` is a raw JSON string. Tool definitions are passed as a JSON array parameter to `provider_chat()`.
- **Streaming**: Non-streaming only.
- **Session state**: Message history is held in Bash arrays (in-memory only).
- **Context overflow**: Detected via provider-specific stderr patterns. Shows guidance to use `/new` and exits the loop gracefully.
- **System prompt ordering**: Base system prompt first, then one system message per skill, then conversation history.
- **`/new` behavior**: Clears only the message history array. Provider, model, and loaded skills persist.
- **Bash tool execution**: Commands execute automatically without confirmation. Run in the launch directory, inherit the agent environment, support optional `env` parameter.
- **Tool execution order**: Sequential.
- **Edit validation**: All edits validated against the original file before any are applied. Checks: `oldText` appears exactly once, no overlapping edits, valid JSON.
- **Atomic file writes**: Temp file in same directory, permissions preserved, `mv` for atomicity.
- **Error handling**: Provider-specific error patterns. Auto-reconnect only for token expiry. Auth failures fail loudly.
- **State management**: `~/.baish/state.json` stores `{"provider": "string", "model": "string"}`.
- **Startup behavior**: Reads `state.json`. If missing or invalid, prompts for provider/model selection.
- **Entry point**: `bin/baish [directory]`. If no directory, uses `$PWD`.
- **Input handling**: Bash `read -e` with custom `COMPREPLY` completion. Alt+Enter for multiline.
- **Skills precedence**: Project-local overrides user-global.
- **Optional auth detection**: `provider_<id>_has_env_auth()` returns exit code (0 = env auth exists).
- **JSON handling**: `jq` exclusively. All construction via `jq -n --arg`.
- **Mock provider**: `lib/providers/mock.sh`, `selectable: false`, for bats tests only.
- **Dependencies**: Bash >= 5, GNU coreutils, sed, awk/gawk, grep, curl, jq, gum. Dev/test: bats.

## Testing Decisions

- **Testing philosophy**: Only test external behavior, not implementation details.
- **Test framework**: `bats`.
- **Test seams** (highest to lowest):
  1. **Agent loop with mock provider** — end-to-end tool call chains and final assistant output.
  2. **Tool execution** — each tool invoked directly, verifying JSON output and side effects.
  3. **Edit validation** — non-unique `oldText`, overlapping edits, valid multi-edit batches.
  4. **Slash command dispatch** — `/` prefix detection and routing.
  5. **Provider interface** — unified `{assistant_text, tool_calls}` output format.
  6. **State management** — `state.json` and `auth/*.json` persistence.
  7. **Session reset** — `/new` clears messages, preserves provider/model/skills.
- **Prior art**: No existing tests — this is the initial implementation. Bats tests will be established alongside the first module.

## Out of Scope

- Streaming responses
- Session persistence to disk
- Context window auto-truncation or summarization
- Bash command confirmation prompts
- Project-level provider overrides
- Anthropic model support via Copilot
- Parallel tool execution
- Multi-session management
- Image/vision support
- Fill-in-the-middle (FIM) completion

## Further Notes

- The Copilot API endpoints are reverse-engineered and not officially documented. They may change without notice.
- Provider files should be side-effect-free (only declare functions) since they are sourced during discovery.
- The mock provider is the primary testing dependency for all agent-loop tests.
