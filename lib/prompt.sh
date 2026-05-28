#!/usr/bin/env bash
# ── lib/prompt.sh — System prompt composition ──────────────────────
# Assembles the full system prompt from base + optional AGENTS.md files

# ── Base system prompt ─────────────────────────────────────────────
_PROMPT_BASE='You are BAISH (BASH + AI), a multi-turn AI coding assistant running in a Debian container.

You have access to the following tools:
- shell: Run shell commands
- read: Read file contents
- write: Write content to a file
- edit: Make targeted edits to a file
- load_skill: Load a skill for specialized instructions

Guidelines:
- Always read files before editing them
- Make surgical, minimal changes
- Preserve existing code style and structure
- Remove imports or code made unused by your changes
- Use lean-ctx tools when available (ctx_read, ctx_ls, ctx_find, ctx_grep, ctx_shell)
- Prefer the simplest solution that fully solves the task
- Ask for clarification when requirements are ambiguous
- Be concise in your responses

File operations use paths relative to /workspace.'

# ── Build the full system prompt ────────────────────────────────────
prompt_build() {
    local prompt="$_PROMPT_BASE"

    # Append tool usage hints
    if command -v tools_build_prompt_text &>/dev/null; then
        local tool_text
        tool_text="$(tools_build_prompt_text)"
        if [[ -n "$tool_text" ]]; then
            prompt+=$'\n\n--- Available Tools ---\n\n'
            prompt+="$tool_text"
        fi
    fi

    # Append skills discovery (name + description only, not full content)
    if command -v skills_build_discovery_prompt &>/dev/null; then
        local skills_text
        skills_text="$(skills_build_discovery_prompt)"
        if [[ -n "$skills_text" ]]; then
            prompt+=$'\n\n'
            prompt+="$skills_text"
        fi
    fi

    # Append ~/.baish/AGENTS.md if it exists
    if [[ -f /root/.baish/AGENTS.md ]]; then
        prompt+=$'\n\n'"--- User instructions (~/.baish/AGENTS.md) ---"$'\n\n'
        prompt+="$(cat /root/.baish/AGENTS.md)"
    fi

    # Append /workspace/AGENTS.md if it exists
    if [[ -f /workspace/AGENTS.md ]]; then
        prompt+=$'\n\n'"--- Project instructions (/workspace/AGENTS.md) ---"$'\n\n'
        prompt+="$(cat /workspace/AGENTS.md)"
    fi

    printf '%s' "$prompt"
}
