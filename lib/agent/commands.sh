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
            baish_print_info "Conversation cleared."
            ;;
        /help)
            baish_usage
            ;;
        /connect)
            if baish_provider_auth; then
                baish_print_info "Authenticated with ${BAISH_CURRENT_PROVIDER}."
                if baish_model_select_interactive; then
                    baish_state_write "${BAISH_CURRENT_PROVIDER}" "${BAISH_CURRENT_MODEL}"
                    baish_print_info "Model set to: ${BAISH_CURRENT_MODEL}"
                fi
            else
                baish_print_error "Authentication failed for ${BAISH_CURRENT_PROVIDER}"
            fi
            ;;
        /provider)
            baish_provider_select_interactive
            if [[ -n "${BAISH_CURRENT_PROVIDER}" ]]; then
                if baish_provider_auth; then
                    baish_model_select_interactive
                    baish_state_write "${BAISH_CURRENT_PROVIDER}" "${BAISH_CURRENT_MODEL}"
                    baish_print_info "Switched to ${BAISH_CURRENT_PROVIDER}/${BAISH_CURRENT_MODEL}"
                else
                    baish_print_error "Authentication failed for ${BAISH_CURRENT_PROVIDER}"
                fi
            fi
            ;;
        /model)
            baish_model_select_interactive
            if [[ -n "${BAISH_CURRENT_MODEL}" ]]; then
                baish_state_write "${BAISH_CURRENT_PROVIDER}" "${BAISH_CURRENT_MODEL}"
                baish_print_info "Model set to: ${BAISH_CURRENT_MODEL}"
            fi
            ;;
        /skill:*)
            local skill_name="${cmd#/skill:}"
            if baish_skill_load "${skill_name}"; then
                baish_print_info "Skill loaded: ${skill_name}"
            fi
            ;;
        *)
            baish_print_error "Unknown command: ${cmd}"
            return 1
            ;;
    esac
    return 0
}
