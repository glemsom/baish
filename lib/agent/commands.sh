#!/usr/bin/env bash
# BAISH — Slash command dispatch
# Routes slash commands to their respective handlers.

# Dispatch a slash command. Returns 0 on success, 1 on unknown command.
baish_dispatch_command() {
    local cmd="$1"

    case "${cmd}" in
        /quit|/exit)
            BAISH_SESSION_EXIT_REQUESTED=1
            ;;
        /new)
            baish_session_reset_context_window
            baish_output_info "Conversation cleared."
            ;;
        /help)
            baish_usage
            ;;
        /connect)
            if baish_provider_auth; then
                baish_output_info "Authenticated with ${BAISH_CURRENT_PROVIDER}."
                if baish_model_select_interactive; then
                    baish_state_write "${BAISH_CURRENT_PROVIDER}" "${BAISH_CURRENT_MODEL}"
                    baish_output_info "Model set to: ${BAISH_CURRENT_MODEL}"
                fi
            else
                baish_output_error "Authentication failed for ${BAISH_CURRENT_PROVIDER}"
            fi
            ;;
        /provider)
            baish_provider_select_interactive
            if [[ -n "${BAISH_CURRENT_PROVIDER}" ]]; then
                if baish_provider_auth; then
                    baish_model_select_interactive
                    baish_state_write "${BAISH_CURRENT_PROVIDER}" "${BAISH_CURRENT_MODEL}"
                    baish_output_info "Switched to ${BAISH_CURRENT_PROVIDER}/${BAISH_CURRENT_MODEL}"
                else
                    baish_output_error "Authentication failed for ${BAISH_CURRENT_PROVIDER}"
                fi
            fi
            ;;
        /model)
            baish_model_select_interactive
            if [[ -n "${BAISH_CURRENT_MODEL}" ]]; then
                baish_state_write "${BAISH_CURRENT_PROVIDER}" "${BAISH_CURRENT_MODEL}"
                baish_output_info "Model set to: ${BAISH_CURRENT_MODEL}"
            fi
            ;;
        /skill:*)
            local skill_name="${cmd#/skill:}"
            if baish_skill_load "${skill_name}"; then
                baish_output_info "Skill loaded: ${skill_name}"
            fi
            ;;
        *)
            baish_output_error "Unknown command: ${cmd}"
            return 1
            ;;
    esac
    return 0
}

# Emoji command palette — triggered by Ctrl+G.
# Uses gum choose to show an interactive menu mapping to slash commands.
# Falls back silently when gum is not installed.
baish_command_palette() {
    # Guard: gum must be installed
    if ! command -v gum &>/dev/null; then
        return 0
    fi

    # Define palette entries: emoji, label, description, mapped command
    local entries=(
        "🔄  New Session"
        "🔌  Connect Provider"
        "🧠  Switch Model"
        "📚  Load Skill"
        "📋  Show Skills"
        "❓  Help"
        "🚪  Quit"
    )

    # Build the display strings from entries
    local display=""
    local entry
    for entry in "${entries[@]}"; do
        if [[ -z "${display}" ]]; then
            display="${entry}"
        else
            display="${display}
${entry}"
        fi
    done

    # Show the gum choose menu
    # --height=10 ensures enough room, prompt shows hint
    local selection
    selection=$(echo -e "${display}" | gum choose --height=10 --header="Ctrl+G Palette — pick an action" 2>/dev/null)

    # If user cancelled (empty selection), re-display prompt and return
    if [[ -z "${selection}" ]]; then
        baish_output_prompt "${BAISH_CURRENT_PROVIDER}" "${BAISH_CURRENT_MODEL}"
        return 0
    fi

    # Map selection to slash command and dispatch
    case "${selection}" in
        *"New Session"*)
            baish_dispatch_command "/new"
            ;;
        *"Connect Provider"*)
            baish_dispatch_command "/connect"
            ;;
        *"Switch Model"*)
            baish_dispatch_command "/model"
            ;;
        *"Load Skill"*)
            # Build a list of available skills: loaded skills + discovered skill dirs
            local skill_options=()
            local s
            for s in "${BAISH_SESSION_SKILL_NAMES[@]}"; do
                skill_options+=("${s} (loaded)")
            done

            # Check project-local and user-global skill directories
            local launch_dir="${BAISH_LAUNCH_DIR:-$(pwd)}"
            local home_dir="${HOME}"
            local dirs=("${launch_dir}/.baish/skills/" "${home_dir}/.baish/skills/")
            local d
            for d in "${dirs[@]}"; do
                if [[ -d "${d}" ]]; then
                    local skill_dir
                    for skill_dir in "${d}"*/; do
                        if [[ -d "${skill_dir}" && -f "${skill_dir}SKILL.md" ]]; then
                            local name
                            name=$(basename "${skill_dir}")
                            # Check if already in options
                            local already=false
                            local opt
                            for opt in "${skill_options[@]}"; do
                                if [[ "${opt}" == "${name}"* ]]; then
                                    already=true
                                    break
                                fi
                            done
                            if [[ "${already}" == "false" ]]; then
                                skill_options+=("${name}")
                            fi
                        fi
                    done
                fi
            done

            if [[ ${#skill_options[@]} -eq 0 ]]; then
                baish_output_info "No skills found."
            else
                # Build display string for gum filter
                local skill_display=""
                for s in "${skill_options[@]}"; do
                    if [[ -z "${skill_display}" ]]; then
                        skill_display="${s}"
                    else
                        skill_display="${skill_display}
${s}"
                    fi
                done

                local skill_selection
                skill_selection=$(echo -e "${skill_display}" | gum filter --placeholder="Search skills…" 2>/dev/null)

                if [[ -n "${skill_selection}" ]]; then
                    # Extract skill name (strip " (loaded)" suffix if present)
                    local skill_name
                    skill_name="${skill_selection% (loaded)}"
                    baish_dispatch_command "/skill:${skill_name}"
                fi
            fi
            ;;
        *"Show Skills"*)
            if [[ ${#BAISH_SESSION_SKILL_NAMES[@]} -eq 0 ]]; then
                baish_output_info "No skills loaded. Use 📚 Load Skill to add one."
            else
                baish_output_info "Loaded skills:"
                local s
                for s in "${BAISH_SESSION_SKILL_NAMES[@]}"; do
                    baish_output_info "  • ${s}"
                done
            fi
            ;;
        *"Help"*)
            baish_dispatch_command "/help"
            ;;
        *"Quit"*)
            baish_dispatch_command "/quit"
            ;;
    esac

    # Re-display prompt so the user sees immediate feedback
    baish_output_prompt "${BAISH_CURRENT_PROVIDER}" "${BAISH_CURRENT_MODEL}"
}
