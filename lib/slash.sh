#!/usr/bin/env bash
# ── lib/slash.sh — Slash command framework ──────────────────────────
# Extensible slash command system with tab completion,
# dispatch, and built-in commands.

# ── Command registry ────────────────────────────────────────────────
declare -A _SLASH_COMMANDS=()   # name → description
declare -A _SLASH_HANDLERS=()   # name → handler function name
_slash_exit=false               # set true by handler to break main loop

# ── Register a slash command ────────────────────────────────────────
# Args: name  description  handler_function_name
slash_register() {
    local name="$1" desc="$2" handler="$3"
    _SLASH_COMMANDS["$name"]="$desc"
    _SLASH_HANDLERS["$name"]="$handler"
}

# ── List all registered command names ──────────────────────────────
slash_list() {
    for cmd in "${!_SLASH_COMMANDS[@]}"; do
        echo "$cmd"
    done
}

# ── Dispatch a slash command ───────────────────────────────────────
# Args: full_input (e.g. "/models" or "/quit")
slash_dispatch() {
    local input="$1"
    local cmd="${input%% *}"  # first word

    if [[ -z "${_SLASH_HANDLERS[$cmd]+_}" ]]; then
        echo -e "  ${_tui_red}Unknown slash command: ${cmd}${_tui_reset}"
        echo -e "  ${_tui_dim}Type /help to see available commands.${_tui_reset}"
        return 1
    fi

    "${_SLASH_HANDLERS[$cmd]}" "${input#"$cmd"}"
}

# ── Built-in: /help ────────────────────────────────────────────────
_slash_handler_help() {
    echo ""
    echo -e "  ${_tui_bold}Available slash commands:${_tui_reset}"
    for cmd in $(echo "${!_SLASH_COMMANDS[@]}" | tr ' ' '\n' | sort); do
        local desc="${_SLASH_COMMANDS[$cmd]}"
        echo -e "  ${_tui_cyan}${cmd}${_tui_reset}  ${_tui_dim}${desc}${_tui_reset}"
    done
    echo ""
}

# ── Built-in: /quit ────────────────────────────────────────────────
_slash_handler_quit() {
    echo -e "  ${_tui_bold}Goodbye!${_tui_reset}"
    _slash_exit=true
}

# ── Built-in: /models ──────────────────────────────────────────────
_slash_handler_models() {
    local models_json models_err
    models_json=$(api_fetch_models 2>/tmp/baish_models_err)
    local status=$?
    models_err=$(cat /tmp/baish_models_err 2>/dev/null)
    rm -f /tmp/baish_models_err

    if [[ $status -ne 0 ]] || [[ -z "$models_json" ]]; then
        echo -e "  ${_tui_red}Error: Could not fetch models from provider.${_tui_reset}"
        echo -e "  ${_tui_dim}${models_err:-$models_json}${_tui_reset}"
        return 1
    fi

    # Validate JSON
    local jq_err
    jq_err=$(echo "$models_json" | jq empty 2>&1 >/dev/null)
    if [[ $? -ne 0 ]]; then
        echo -e "  ${_tui_red}Error: Invalid response from /models endpoint.${_tui_reset}"
        echo -e "  ${_tui_dim}Response: ${models_json:0:200}${_tui_reset}"
        if [[ -n "$jq_err" ]]; then
            echo -e "  ${_tui_dim}jq error: ${jq_err}${_tui_reset}"
        fi
        return 1
    fi

    # Extract model IDs
    # 1. OpenAI format: {"data":[{"id":"model-name"}...]}
    # 2. GitHub Models format: [{"name":"model-name","task":"chat-completion"}...]
    #    (GitHub's .id is an Azure URI, not a usable model name)
    local model_list
    model_list=$(echo "$models_json" | jq -r 'if type == "array" then empty else .data[].id // empty end' 2>/dev/null | sort)

    # If not OpenAI format, try flat array with .name (GitHub Models format)
    if [[ -z "$model_list" ]]; then
        model_list=$(echo "$models_json" | jq -r 'if type == "array" then .[] | select(.task == "chat-completion") | .name // empty else empty end' 2>/dev/null | sort)
    fi

    # Last resort: try .id from flat array (may return Azure URIs or similar)
    if [[ -z "$model_list" ]]; then
        model_list=$(echo "$models_json" | jq -r 'if type == "array" then .[].id // empty else .data[] | .id // empty end' 2>/dev/null | sort)
    fi

    if [[ -z "$model_list" ]]; then
        echo -e "  ${_tui_red}No models found from provider.${_tui_reset}"
        echo -e "  ${_tui_dim}Provider may not support the /models endpoint.${_tui_reset}"
        return 1
    fi

    local total
    total=$(echo "$model_list" | wc -l)
    echo -e "  ${_tui_dim}Found ${total} models.${_tui_reset}"

    local selected=""

    if command -v fzf &>/dev/null; then
        # Use fzf for interactive selection
        echo ""
        selected=$(echo "$model_list" | fzf \
            --prompt="Select model: " \
            --height=40% \
            --reverse \
            --header "Current: ${BAISH_MODEL}" \
            --exit-0 2>/dev/null)
    else
        # Fallback: numbered list
        echo ""
        local i=1
        while IFS= read -r model; do
            if [[ "$model" == "$BAISH_MODEL" ]]; then
                echo -e "  ${_tui_green}▶${_tui_reset} ${_tui_bold}${i}) ${model}${_tui_reset} ${_tui_dim}(current)${_tui_reset}"
            else
                echo "  ${_tui_dim}${i})${_tui_reset} ${model}"
            fi
            i=$((i + 1))
        done <<< "$model_list"
        echo ""
        read -r choice
        if [[ -n "$choice" ]]; then
            selected=$(echo "$model_list" | sed -n "${choice}p")
        fi
    fi

    if [[ -z "$selected" ]]; then
        echo -e "  ${_tui_dim}No model selected.${_tui_reset}"
        return 0
    fi

    # Switch model
    BAISH_MODEL="$selected"
    config_set "BAISH_MODEL" "$selected"

    # Try to resolve context window for new model
    local new_context
    new_context=$(api_lookup_model_context)
    if [[ "$new_context" != "$BAISH_MAX_CONTEXT" ]]; then
        BAISH_MAX_CONTEXT="$new_context"
    fi

    echo -e "  ${_tui_green}✓ Switched to model: ${_tui_bold}${selected}${_tui_reset}"
}

# ── Initialize: register built-in commands ─────────────────────────
slash_init() {
    slash_register "/help"   "Show available slash commands"  "_slash_handler_help"
    slash_register "/quit"   "Exit BAISH"                     "_slash_handler_quit"
    slash_register "/models" "List and switch models"         "_slash_handler_models"
}
