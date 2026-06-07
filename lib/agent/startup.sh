#!/usr/bin/env bash
# BAISH — Agent startup module
# One interface: baish_startup(). Sets BAISH_CURRENT_PROVIDER and
# BAISH_CURRENT_MODEL globals. Returns 0 on success, non-zero on failure.
#
# Injectable pickers for testing. Override before calling baish_startup:
#   BAISH_STARTUP_PROVIDER_PICKER — function name for provider selection
#   BAISH_STARTUP_MODEL_PICKER   — function name for model selection
# Defaults to the interactive pickers from discovery.sh.

# Injection points. Tests set these to non-interactive mock functions.
BAISH_STARTUP_PROVIDER_PICKER="${BAISH_STARTUP_PROVIDER_PICKER:-baish_provider_select_interactive}"
BAISH_STARTUP_MODEL_PICKER="${BAISH_STARTUP_MODEL_PICKER:-baish_model_select_interactive}"

baish_startup() {
    # Try restoring from state
    if baish_state_read; then
        local state_provider="${BAISH_STATE_PROVIDER}"
        local state_model="${BAISH_STATE_MODEL}"

        # Check if the state provider is still available
        local found=0
        for pid in "${BAISH_PROVIDER_IDS[@]}"; do
            if [[ "${pid}" == "${state_provider}" ]]; then
                found=1
                break
            fi
        done

        if (( found )); then
            # Check for env-based auth or existing auth file
            BAISH_CURRENT_PROVIDER="${state_provider}"
            if baish_provider_has_env_auth; then
                BAISH_CURRENT_MODEL="${state_model}"
                baish_debug "State restored with env auth: ${BAISH_CURRENT_PROVIDER}/${BAISH_CURRENT_MODEL}"
                return 0
            fi

            # Check if auth file exists for this provider
            case "${state_provider}" in
                copilot)
                    if [[ -f "${BAISH_AUTH_DIR}/copilot.json" ]]; then
                        BAISH_CURRENT_MODEL="${state_model}"
                        baish_debug "State restored from file auth: ${BAISH_CURRENT_PROVIDER}/${BAISH_CURRENT_MODEL}"
                        return 0
                    fi
                    ;;
                kilo)
                    if [[ -f "${BAISH_AUTH_DIR}/kilo.json" ]]; then
                        BAISH_CURRENT_MODEL="${state_model}"
                        baish_debug "State restored from file auth: ${BAISH_CURRENT_PROVIDER}/${BAISH_CURRENT_MODEL}"
                        return 0
                    fi
                    ;;
                mock)
                    # Mock doesn't need auth
                    BAISH_CURRENT_MODEL="${state_model}"
                    baish_debug "State restored (mock): ${BAISH_CURRENT_PROVIDER}/${BAISH_CURRENT_MODEL}"
                    return 0
                    ;;
            esac

            baish_debug "State provider '${state_provider}' found but needs re-auth"
        fi
    fi

    # Need to select a provider interactively
    # Filter to only selectable providers
    local selectable_count=0
    local selectable_ids=()
    for pid in "${BAISH_PROVIDER_IDS[@]}"; do
        local metadata
        metadata=$(baish_provider_metadata "${pid}")
        local selectable
        selectable=$(echo "${metadata}" | jq -r '.selectable // false')
        if [[ "${selectable}" == "true" ]]; then
            selectable_ids+=("${pid}")
            selectable_count=$((selectable_count + 1))
        fi
    done

    # If only mock is available, use it
    if (( selectable_count == 0 )); then
        for pid in "${BAISH_PROVIDER_IDS[@]}"; do
            if [[ "${pid}" == "mock" ]]; then
                BAISH_CURRENT_PROVIDER="mock"
                local models
                models=$(provider_mock_list_models)
                BAISH_CURRENT_MODEL=$(echo "${models}" | jq -r '.[0].id')
                baish_state_write "${BAISH_CURRENT_PROVIDER}" "${BAISH_CURRENT_MODEL}"
                baish_debug "Defaulted to mock provider (no selectable providers)"
                return 0
            fi
        done
        baish_output_error "No providers available"
        return 1
    fi

    # Show provider picker (injectable for testing)
    if ! "${BAISH_STARTUP_PROVIDER_PICKER}"; then
        baish_output_error "No provider selected"
        return 1
    fi

    if [[ -z "${BAISH_CURRENT_PROVIDER}" ]]; then
        baish_output_error "No provider selected"
        return 1
    fi

    # Authenticate
    if ! baish_provider_auth; then
        baish_output_error "Authentication failed for ${BAISH_CURRENT_PROVIDER}"
        return 1
    fi

    # Select model (injectable for testing)
    if ! "${BAISH_STARTUP_MODEL_PICKER}"; then
        baish_output_error "No model selected"
        return 1
    fi

    if [[ -z "${BAISH_CURRENT_MODEL}" ]]; then
        baish_output_error "No model selected"
        return 1
    fi

    # Persist state
    baish_state_write "${BAISH_CURRENT_PROVIDER}" "${BAISH_CURRENT_MODEL}"
}
