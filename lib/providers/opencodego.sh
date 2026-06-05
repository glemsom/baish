#!/usr/bin/env bash
# BAISH — OpenCode Go provider
#
# Connects to the OpenCode Go gateway ($10/month subscription).
# Two-tier chat routing: OpenAI /chat/completions for most models,
# Anthropic /messages for minimax-* and qwen* models.
# API key authentication with validation and persistence in ~/.baish/auth/opencodego.json.

OPENCODEGO_BASE_URL="${OPENCODEGO_BASE_URL:-https://opencode.ai/zen/go/v1}"

# --- Metadata ---
provider_opencodego_metadata() {
    jq -n '{
        "id": "opencodego",
        "label": "OpenCode Go",
        "desc": "Curated models via OpenCode Go gateway. Requires an API key.",
        "selectable": true
    }'
}

# --- Environment auth detection ---
provider_opencodego_has_env_auth() {
    if [[ -n "${OPENCODEGO_API_KEY:-}" ]]; then
        return 0
    fi
    return 1
}

# --- Load stored API key ---
_opencodego_load_api_key() {
    # Prefer env var
    if [[ -n "${OPENCODEGO_API_KEY:-}" ]]; then
        echo "${OPENCODEGO_API_KEY}"
        return 0
    fi

    local auth_file="${BAISH_AUTH_DIR}/opencodego.json"
    if [[ -f "${auth_file}" ]]; then
        jq -r '.api_key // empty' "${auth_file}" 2>/dev/null
        return $?
    fi

    echo ""
    return 1
}

# --- Validate API key ---
_opencodego_validate_key() {
    local api_key="$1"

    # Validate by sending a minimal request to the chat completions endpoint.
    # HTTP 200 = valid, 401 = invalid.
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 10 \
        --max-time 30 \
        -X POST \
        -H "Authorization: Bearer ${api_key}" \
        -H "Content-Type: application/json" \
        -d '{"model":"kimi-k2.5","messages":[{"role":"user","content":"."}],"max_tokens":1}' \
        "${OPENCODEGO_BASE_URL}/chat/completions" 2>/dev/null)

    if [[ "${http_code}" == "200" ]]; then
        return 0
    fi

    baish_debug "OpenCodeGo: key validation failed (HTTP ${http_code})"
    return 1
}

# --- Authentication ---
provider_opencodego_auth() {
    local auth_file="${BAISH_AUTH_DIR}/opencodego.json"

    # Check for existing stored key
    local existing_key
    existing_key=$(jq -r '.api_key // empty' "${auth_file}" 2>/dev/null)
    if [[ -n "${existing_key}" ]]; then
        baish_debug "OpenCodeGo: existing API key found, validating..."
        if _opencodego_validate_key "${existing_key}"; then
            baish_debug "OpenCodeGo: existing API key is valid"
            return 0
        fi
        baish_debug "OpenCodeGo: existing API key is invalid, re-authenticating"
    fi

    # Prompt for API key
    baish_output_info "Enter your OpenCode Go API key:"
    local api_key
    api_key=$(gum input --placeholder "sk-..." 2>/dev/null || read -r -s -p "API Key: " api_key && echo "${api_key}")

    if [[ -z "${api_key}" ]]; then
        baish_output_error "No API key provided"
        return 1
    fi

    # Validate the key
    if ! _opencodego_validate_key "${api_key}"; then
        baish_output_error "Invalid OpenCode Go API key. Please check and try again."
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
            "provider": "opencodego"
        }' > "${auth_file}"

    baish_output_info "✓ OpenCode Go authentication successful!"
    return 0
}

# --- Model listing ---
provider_opencodego_list_models() {
    local api_key
    api_key=$(_opencodego_load_api_key)

    if [[ -z "${api_key}" ]]; then
        echo "[]"
        return 0
    fi

    baish_debug "OpenCodeGo: fetching model list from ${OPENCODEGO_BASE_URL}/models"

    local response
    response=$(curl -s \
        --connect-timeout 10 \
        --max-time 30 \
        -H "Accept: application/json" \
        "${OPENCODEGO_BASE_URL}/models" 2>/dev/null)

    local models_raw
    models_raw=$(echo "${response}" | jq -c '.data // []' 2>/dev/null)

    if [[ -z "${models_raw}" || "${models_raw}" == "null" ]]; then
        echo "[]"
        return 0
    fi

    # Sort, deduplicate, and format models.
    # Group by ID prefix family: glm, kimi, deepseek, mimo, minimax, qwen, hy3.
    # Derive display name from ID (replace hyphens with spaces, title-case).
    echo "${models_raw}" | jq '
        def derive_group($id):
            if $id | startswith("minimax") then "minimax"
            elif $id | startswith("deepseek") then "deepseek"
            elif $id | startswith("kimi") then "kimi"
            elif $id | startswith("qwen") then "qwen"
            elif $id | startswith("mimo") then "mimo"
            elif $id | startswith("glm") then "glm"
            elif $id | startswith("hy3") then "hy3"
            else "other" end;
        unique_by(.id) |
        [.[] | {
            "id": .id,
            "name": (
                .id |
                split("-") |
                map(
                    (.[0:1] | ascii_upcase) + .[1:]
                ) |
                join(" ")
            ),
            "group": derive_group(.id)
        }] |
        sort_by(.group, .name)
    '
}

# --- Chat ---
# Full chat implementation is in issues #22 (OpenAI path) and #23 (Anthropic path).
# This function provides the minimal stub required for provider discovery.
provider_opencodego_chat() {
    local messages_json="$1"
    local tools_json="$2"

    local api_key
    api_key=$(_opencodego_load_api_key)

    if [[ -z "${api_key}" ]]; then
        jq -n '{"ok": false, "error": {"code": "AUTH_FAILURE", "message": "No API key found. Run /connect to authenticate."}}'
        return 0
    fi

    # Chat not yet implemented — see issues #22 and #23
    jq -n '{"ok": false, "error": {"code": "GENERIC_ERROR", "message": "OpenCodeGo: Chat not yet implemented."}}'
    return 0
}
