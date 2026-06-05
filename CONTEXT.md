# BAISH — Context Glossary

## Project

**BAISH** — A Bash-first terminal AI coding agent for GNU/Linux. Provides multi-provider LLM support, file/shell tool execution, slash commands, and a skills system — all in pure Bash.

## Core Concepts

**Provider** — A pluggable LLM backend (e.g., GitHub Copilot, Kilo Gateway). Discovers via `lib/providers/*.sh` files. Each implements a standard interface: metadata, auth, list_models, chat, and optional has_env_auth.

**Provider ID** — A unique string identifier for a provider (e.g., `copilot`, `kilo`). Collisions error loudly.

**Session** — An in-memory conversation context held in Bash arrays. Contains message history, loaded skills, and provider/model selection. Cleared by `/new`.

**Skill** — A domain-specific instruction set defined by a `SKILL.md` file. Loaded into the session via `/skill:<name>`. Project-local (`./.baish/skills/`) overrides user-global (`~/.baish/skills/`). Prepended as system messages.

**Tool** — A capability the LLM can invoke: `read`, `write`, `edit`, `bash`. All return standardized JSON. Executed sequentially.

**State** — Persisted configuration in `~/.baish/state.json`. Tracks selected provider and model.

**Auth** — Credentials stored in `~/.baish/auth/`. Format varies by provider: Copilot persists long-lived GitHub token; Kilo persists API key.

**Slash Command** — A user-facing command prefixed with `/` that triggers system behavior (e.g., `/connect`, `/provider`, `/model`, `/new`, `/skill:<name>`, `/quit`).

**Launch Directory** — The working directory where BAISH was invoked. All tool paths are relative to this.

## Error Types

**Context Overflow** — When the message history exceeds the model's context window limit. Handled by showing guidance to use `/new`.

**Chat Parser** — A shared module (`lib/providers/chat-parser.sh`) that builds Chat Completions payloads and parses HTTP responses from LLM provider chat APIs. Handles error detection (context overflow, auth failure, generic errors) and normalizes successful responses into the standard `{assistant_text, tool_calls}` format. Used by provider adapters to reduce duplication.

**Token Expiry** — When a Copilot runtime token (`ghc_*`) expires. Handled by automatic silent refresh.

**Auth Failure** — When credentials are invalid (bad key, denied OAuth). Handled by failing loudly and prompting the user.
