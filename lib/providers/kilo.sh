#!/usr/bin/env bash
# BAISH — Kilo Gateway provider
#
# API key authentication with validation and persistence in ~/.baish/auth/kilo.json.
# Model listing from /models endpoint, filtered to chat-capable models, grouped by provider prefix.
# Full prefixed model IDs (e.g., anthropic/claude-sonnet-4.5) used as-is in API calls.

KILO_GATEWAY_URL="${KILO_GATEWAY_URL:-https://gateway.kilo.ai}"

# --- Metadata ---
provider_kilo_metadata() {
    jq -n '{
        "id": "kilo",
        "label": "Kilo Gateway",
        "desc": "Access hundreds of models via Kilo Gateway API. Requires an API key.",
        "selectable": true
    }'
}

# --- Environment auth detection ---
provider_kilo_has_env_auth() {
    if [[ -n "${KILO_API_KEY:-}" ]]; then
        return 0
    fi
    return 1
}

# --- Load stored API key ---
_kilo_load_api_key() {
    # Prefer env var
    if [[ -n "${KILO_API_KEY:-}" ]]; then
        echo "${KILO_API_KEY}"
        return 0
    fi

    local auth_file="${BAISH_AUTH_DIR}/kilo.json"
    if [[ -f "${auth_file}" ]]; then
        jq -r '.api_key // empty' "${auth_file}" 2>/dev/null
        return $?
    fi

    echo ""
    return 1
}

# --- Authentication ---
provider_kilo_auth() {
    local auth_file="${BAISH_AUTH_DIR}/kilo.json"

    # Check for existing stored key
    local existing_key
    existing_key=$(jq -r '.api_key // empty' "${auth_file}" 2>/dev/null)
    if [[ -n "${existing_key}" ]]; then
        baish_debug "Kilo: existing API key found, validating..."
        # Validate the existing key
        if _kilo_validate_key "${existing_key}"; then
            baish_debug "Kilo: existing API key is valid"
            return 0
        fi
        baish_debug "Kilo: existing API key is invalid, re-authenticating"
    fi

    # Prompt for API key
    baish_print_info "Enter your Kilo Gateway API key:"
    local api_key
    api_key=$(gum input --placeholder "sk-..." 2>/dev/null || read -r -s -p "API Key: " api_key && echo "${api_key}")

    if [[ -z "${api_key}" ]]; then
        baish_print_error "No API key provided"
        return 1
    fi

    # Validate the key
    if ! _kilo_validate_key "${api_key}"; then
        baish_print_error "Invalid Kilo API key. Please check and try again."
        return 1
    fi

    # Persist the key
    mkdir -p "$(dirname "${auth_file}")"
    jq -n \
        --arg key "${api_key}" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            "api_key": $key,
            "authenticated_at": $ts,
            "provider": "kilo"
        }' > "${auth_file}"

    baish_print_info "✓ Kilo Gateway authentication successful!"
    return 0
}

# --- Validate API key ---
_kilo_validate_key() {
    local api_key="$1"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${api_key}" \
        "${KILO_GATEWAY_URL}/v1/models" 2>/dev/null)

    if [[ "${http_code}" == "200" || "${http_code}" == "404" ]]; then
        # 200 = valid, 404 = valid but no /models endpoint (still authenticated)
        return 0
    fi

    baish_debug "Kilo: key validation failed (HTTP ${http_code})"
    return 1
}

# --- Model listing ---
provider_kilo_list_models() {
    local api_key
    api_key=$(_kilo_load_api_key)

    if [[ -z "${api_key}" ]]; then
        echo "[]"
        return 0
    fi

    baish_debug "Kilo: fetching model list from ${KILO_GATEWAY_URL}/v1/models"

    local response
    response=$(curl -s \
        -H "Authorization: Bearer ${api_key}" \
        -H "Accept: application/json" \
        "${KILO_GATEWAY_URL}/v1/models" 2>/dev/null)

    local models_raw
    models_raw=$(echo "${response}" | jq -c '.data // []' 2>/dev/null)

    if [[ -z "${models_raw}" || "${models_raw}" == "null" ]]; then
        echo "[]"
        return 0
    fi

    # Filter to chat-capable models and group by provider prefix
    # Kilo models use prefixed IDs like "anthropic/claude-sonnet-4.5"
    # We extract the prefix as the group and filter for models with "chat" features
    # If no features field exists, include by default (OpenAI-compatible endpoints)
    echo "${models_raw}" | jq '
        [.[] | select(
            ((.features // []) | map(ascii_downcase) | index("chat")) != null
            or ((.features // null) == null and (.object == "model" or .type == "model"))
        )] |
        unique_by(.id) |
        [.[] | {
            "id": .id,
            "name": (if .name then .name else (.id | split("/") | last) end),
            "group": (if (.id | contains("/")) then (.id | split("/") | first) else "other" end)
        }] |
        sort_by(.group, .name)
    '
}

# --- Chat ---
provider_kilo_chat() {
    local messages_json="$1"
    local tools_json="$2"

    local api_key
    api_key=$(_kilo_load_api_key)

    if [[ -z "${api_key}" ]]; then
        baish_print_error "Kilo: No API key found. Run /connect to authenticate." >&2
        return 1
    fi

    local model="${BAISH_CURRENT_MODEL}"

    # Build Chat Completions payload (Kilo uses OpenAI-compatible API)
    local payload
    if [[ -n "${tools_json}" && "${tools_json}" != "[]" && "${tools_json}" != "null" ]]; then
        payload=$(jq -n \
            --arg model "${model}" \
            --argjson messages "${messages_json}" \
            --argjson tools "${tools_json}" \
            '{
                "model": $model,
                "messages": $messages,
                "tools": $tools,
                "stream": false,
                "parallel_tool_calls": false
            }')
    else
        payload=$(jq -n \
            --arg model "${model}" \
            --argjson messages "${messages_json}" \
            '{
                "model": $model,
                "messages": $messages,
                "stream": false
            }')
    fi

    baish_debug "Kilo: sending chat request (model: ${model})"
    baish_debug_http "kilo" "POST" "${KILO_GATEWAY_URL}/v1/chat/completions" "" "sending request"

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${api_key}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "${payload}" \
        "${KILO_GATEWAY_URL}/v1/chat/completions" 2>/dev/null)

    local http_code body
    http_code=$(echo "${response}" | tail -1)
    body=$(echo "${response}" | sed '$d')

    baish_debug_http "kilo" "POST" "${KILO_GATEWAY_URL}/v1/chat/completions" "${http_code}"

    if [[ "${http_code}" != "200" ]]; then
        local error_msg
        error_msg=$(echo "${body}" | jq -r '.error.message // .message // "Unknown error"' 2>/dev/null)

        # Detect context overflow
        if echo "${body}" | grep -qi "context_length_exceeded\|context.*exceeded\|too long"; then
            baish_debug "Kilo: context overflow detected"
            echo "CONTEXT_OVERFLOW" >&2
            return 1
        fi

        # Detect auth failure
        if [[ "${http_code}" == "401" || "${http_code}" == "403" ]]; then
            baish_debug "Kilo: auth failure (HTTP ${http_code})"
            echo "AUTH_FAILURE" >&2
            baish_print_error "Kilo: API key is invalid or expired. Please re-authenticate with /connect." >&2
            return 1
        fi

        baish_print_error "Kilo: Chat error (HTTP ${http_code}): ${error_msg}" >&2
        return 1
    fi

    # Parse response
    local assistant_text
    assistant_text=$(echo "${body}" | jq -r '.choices[0].message.content // ""')

    # Extract tool calls
    local tool_calls
    tool_calls=$(echo "${body}" | jq -c '
        .choices[0].message.tool_calls // [] |
        [.[] | {
            "id": .id,
            "name": .function.name,
            "arguments": .function.arguments
        }]
    ')

    jq -n \
        --arg text "${assistant_text}" \
        --argjson tc "${tool_calls}" \
        '{"assistant_text": $text, "tool_calls": $tc}'
}
