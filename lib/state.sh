#!/usr/bin/env bash
# BAISH — State persistence
# Persists provider and model selection in ~/.baish/state.json

BAISH_STATE_DIR="${BAISH_STATE_DIR:-${HOME}/.baish}"
BAISH_STATE_FILE="${BAISH_STATE_DIR}/state.json"
BAISH_AUTH_DIR="${BAISH_STATE_DIR}/auth"

# Initialize state directory structure
baish_state_init() {
    mkdir -p "${BAISH_STATE_DIR}" "${BAISH_AUTH_DIR}"
}

# Read state from disk. Sets BAISH_STATE_PROVIDER and BAISH_STATE_MODEL.
# Returns 0 if state was read successfully, 1 if missing or invalid.
baish_state_read() {
    if [[ ! -f "${BAISH_STATE_FILE}" ]]; then
        baish_debug "State file not found: ${BAISH_STATE_FILE}"
        return 1
    fi

    local provider model
    provider=$(jq -r '.provider // empty' "${BAISH_STATE_FILE}" 2>/dev/null)
    model=$(jq -r '.model // empty' "${BAISH_STATE_FILE}" 2>/dev/null)

    if [[ -z "${provider}" || -z "${model}" ]]; then
        baish_debug "State file is invalid or missing required fields"
        return 1
    fi

    BAISH_STATE_PROVIDER="${provider}"
    BAISH_STATE_MODEL="${model}"
    baish_debug "State loaded: provider=${BAISH_STATE_PROVIDER}, model=${BAISH_STATE_MODEL}"
    return 0
}

# Write current state to disk
baish_state_write() {
    local provider="$1"
    local model="$2"

    if [[ -z "${provider}" || -z "${model}" ]]; then
        baish_debug "Cannot write state: provider and model are required"
        return 1
    fi

    jq -n --arg provider "${provider}" --arg model "${model}" \
        '{"provider": $provider, "model": $model}' \
        > "${BAISH_STATE_FILE}"

    baish_debug "State written: provider=${provider}, model=${model}"
    return 0
}
