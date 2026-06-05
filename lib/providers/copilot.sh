#!/usr/bin/env bash
# BAISH — GitHub Copilot provider
#
# OAuth device flow authentication with long-lived GitHub token persistence.
# Short-lived Copilot runtime token (ghc_*) is refreshed lazily with 60s expiry buffer.
# Model routing: gpt-5* → Responses API (/v1/responses), everything else → Chat Completions (/v1/chat/completions).
#
# Internal state (not persisted):
#   BAISH_COPILOT_RUNTIME_TOKEN: short-lived token
#   BAISH_COPILOT_RUNTIME_EXPIRY: epoch seconds when the runtime token expires

# --- Metadata ---
provider_copilot_metadata() {
    jq -n '{
        "id": "copilot",
        "label": "GitHub Copilot",
        "desc": "Use your GitHub Copilot subscription. OAuth device flow auth.",
        "selectable": true
    }'
}

# --- Environment auth detection ---
provider_copilot_has_env_auth() {
    if [[ -n "${GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" ]]; then
        return 0
    fi
    return 1
}

# --- Authentication (OAuth device flow) ---
provider_copilot_auth() {
    local auth_file="${BAISH_AUTH_DIR}/copilot.json"

    # Check for existing long-lived token
    if [[ -f "${auth_file}" ]]; then
        local existing_token
        existing_token=$(jq -r '.github_token // empty' "${auth_file}" 2>/dev/null)
        if [[ -n "${existing_token}" && "${existing_token}" == gho_* ]]; then
            baish_debug "Copilot: existing GitHub token found"
            return 0
        fi
    fi

    # OAuth device flow
    baish_output_info "Authenticating with GitHub Copilot..."
    baish_output_info "Starting device flow..."

    # Step 1: Get device and user codes
    local device_response
    device_response=$(curl -s -X POST \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d '{"client_id": "Iv1.b507608c826910e1","scope": "read:user"}' \
        "https://github.com/login/device/code" 2>/dev/null)

    local device_code user_code verification_uri expires_in interval
    device_code=$(echo "${device_response}" | jq -r '.device_code // empty')
    user_code=$(echo "${device_response}" | jq -r '.user_code // empty')
    verification_uri=$(echo "${device_response}" | jq -r '.verification_uri // empty')
    expires_in=$(echo "${device_response}" | jq -r '.expires_in // 900')
    interval=$(echo "${device_response}" | jq -r '.interval // 5')

    if [[ -z "${device_code}" || -z "${user_code}" ]]; then
        baish_output_error "Failed to initiate Copilot device flow: ${device_response}"
        return 1
    fi

    # Step 2: Show user the verification URL and code
    baish_output_info ""
    baish_output_info "Open this URL in your browser:"
    baish_output_info "  ${verification_uri}"
    baish_output_info ""
    baish_output_info "Enter this code: ${user_code}"
    baish_output_info ""
    baish_output_info "Waiting for authorization..."

    # Step 3: Poll for access token
    local start_time
    start_time=$(date +%s)
    local access_token=""

    while true; do
        local elapsed=$(( $(date +%s) - start_time ))
        if (( elapsed >= expires_in )); then
            baish_output_error "Device flow timed out. Please try again."
            return 1
        fi

        sleep "${interval}"

        local poll_response
        poll_response=$(curl -s -X POST \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -d "{\"client_id\": \"Iv1.b507608c826910e1\",\"device_code\": \"${device_code}\",\"grant_type\": \"urn:ietf:params:oauth:grant-type:device_code\"}" \
            "https://github.com/login/oauth/access_token" 2>/dev/null)

        if [[ -z "${poll_response}" ]]; then
            baish_output_error "Empty response from GitHub OAuth endpoint"
            return 1
        fi

        local error_type
        error_type=$(echo "${poll_response}" | jq -r '.error // empty')

        if [[ "${error_type}" == "authorization_pending" ]]; then
            continue
        elif [[ "${error_type}" == "slow_down" ]]; then
            interval=$(( interval + 5 ))
            continue
        elif [[ "${error_type}" == "expired_token" ]]; then
            baish_output_error "Device code expired. Please try again."
            return 1
        elif [[ "${error_type}" == "access_denied" ]]; then
            baish_output_error "Authorization denied. Please try again."
            return 1
        fi

        # Got the access token
        access_token=$(echo "${poll_response}" | jq -r '.access_token // empty')
        if [[ -n "${access_token}" ]]; then
            break
        fi

        baish_output_error "Unexpected response from GitHub: ${poll_response}"
        return 1
    done

    # Step 4: Persist the long-lived token
    mkdir -p "$(dirname "${auth_file}")"
    jq -n \
        --arg token "${access_token}" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            "github_token": $token,
            "authenticated_at": $ts,
            "provider": "github"
        }' > "${auth_file}"

    baish_output_info "✓ Copilot authentication successful!"
    # Clear the runtime token so it will be refreshed on next chat
    BAISH_COPILOT_RUNTIME_TOKEN=""
    BAISH_COPILOT_RUNTIME_EXPIRY=0

    return 0
}

# --- Load stored GitHub token ---
_copilot_load_github_token() {
    local auth_file="${BAISH_AUTH_DIR}/copilot.json"
    if [[ -f "${auth_file}" ]]; then
        jq -r '.github_token // empty' "${auth_file}" 2>/dev/null
    else
        echo ""
    fi
}

# --- Refresh runtime token ---
_copilot_refresh_runtime_token() {
    local github_token
    github_token=$(_copilot_load_github_token)

    if [[ -z "${github_token}" ]]; then
        baish_output_error "Copilot: No GitHub token found. Run /connect to authenticate."
        return 1
    fi

    local now
    now=$(date +%s)

    # Check if current runtime token is still valid (with 60s buffer)
    if [[ -n "${BAISH_COPILOT_RUNTIME_TOKEN:-}" && "${BAISH_COPILOT_RUNTIME_EXPIRY:-0}" -gt $(( now + 60 )) ]]; then
        baish_debug "Copilot: runtime token still valid"
        return 0
    fi

    baish_debug "Copilot: refreshing runtime token"

    # Exchange GitHub token for Copilot runtime token
    local response
    response=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: token ${github_token}" \
        -H "Accept: application/json" \
        "https://api.github.com/copilot_internal/v2/token" 2>/dev/null)

    local http_code body
    http_code=$(echo "${response}" | tail -1)
    body=$(echo "${response}" | sed '$d')

    if [[ "${http_code}" != "200" ]]; then
        if [[ "${http_code}" == "401" || "${http_code}" == "403" ]]; then
            baish_output_error "Copilot: GitHub token is invalid or expired. Please re-authenticate with /connect."
        else
            baish_output_error "Copilot: Failed to refresh runtime token (HTTP ${http_code}): ${body}"
        fi
        return 1
    fi

    BAISH_COPILOT_RUNTIME_TOKEN=$(echo "${body}" | jq -r '.token // empty')
    local expires_at
    expires_at=$(echo "${body}" | jq -r '.expires_at // 0')

    if [[ -z "${BAISH_COPILOT_RUNTIME_TOKEN}" || "${BAISH_COPILOT_RUNTIME_TOKEN}" == "null" ]]; then
        baish_output_error "Copilot: Failed to extract runtime token from response"
        return 1
    fi

    BAISH_COPILOT_RUNTIME_EXPIRY="${expires_at}"
    baish_debug "Copilot: runtime token refreshed, expires at ${BAISH_COPILOT_RUNTIME_EXPIRY}"
    return 0
}

# --- Model listing ---
provider_copilot_list_models() {
    # Copilot doesn't expose a model listing endpoint via the runtime token API.
    # We provide a curated list of known Copilot models.
    jq -n '[
        {"id": "gpt-5", "name": "GPT-5"},
        {"id": "gpt-5-codex", "name": "GPT-5 Codex"},
        {"id": "gpt-5-mini", "name": "GPT-5 Mini"},
        {"id": "gpt-5-nano", "name": "GPT-5 Nano"},
        {"id": "gpt-4.1", "name": "GPT-4.1"},
        {"id": "gpt-4.1-mini", "name": "GPT-4.1 Mini"},
        {"id": "gpt-4.1-nano", "name": "GPT-4.1 Nano"},
        {"id": "gpt-4o", "name": "GPT-4o"},
        {"id": "gpt-4o-mini", "name": "GPT-4o Mini"},
        {"id": "o3", "name": "o3"},
        {"id": "o3-mini", "name": "o3 Mini"},
        {"id": "o4-mini", "name": "o4 Mini"},
        {"id": "claude-sonnet-4-20250514", "name": "Claude Sonnet 4"},
        {"id": "claude-opus-4-20250514", "name": "Claude Opus 4"},
        {"id": "claude-3.5-sonnet", "name": "Claude 3.5 Sonnet"},
        {"id": "gemini-2.5-flash", "name": "Gemini 2.5 Flash"},
        {"id": "gemini-2.5-pro", "name": "Gemini 2.5 Pro"}
    ]'
}

# --- Chat ---
# Internal helper: makes a single chat API call (no retry)
# Always returns 0; structured JSON with ok field on stdout.
# Error conditions are encoded as {"ok": false, "error": {"code": "...", "message": "..."}}.
_copilot_chat_single() {
    local messages_json="$1"
    local tools_json="$2"
    local model="${BAISH_CURRENT_MODEL}"
    local auth_header="Bearer ${BAISH_COPILOT_RUNTIME_TOKEN}"
    local url response

    # Route based on model family
    if [[ "${model}" == gpt-5* ]]; then
        # Responses API for gpt-5 models
        url="https://api.githubcopilot.com/responses"

        # Convert messages format for Responses API
        local instructions last_user_content
        instructions=""
        last_user_content=""

        # Extract system messages as instructions
        local system_msgs
        system_msgs=$(echo "${messages_json}" | jq -c '[.[] | select(.role == "system") | .content] | join("\n---\n")')
        # Remove surrounding quotes from jq output
        instructions=$(echo "${system_msgs}" | jq -r '.')

        # Get the last user message content
        last_user_content=$(echo "${messages_json}" | jq -r '[.[] | select(.role == "user")] | last | .content // empty')

        # Build Responses API payload
        local payload
        if [[ -n "${tools_json}" && "${tools_json}" != "[]" && "${tools_json}" != "null" ]]; then
            local tools_for_responses
            tools_for_responses=$(echo "${tools_json}" | jq '
                [.[] | {
                    "name": .function.name,
                    "type": "function",
                    "description": .function.description,
                    "parameters": .function.parameters
                }]
            ')
            payload=$(jq -n \
                --arg model "${model}" \
                --arg input "${last_user_content}" \
                --arg instructions "${instructions}" \
                --argjson tools "${tools_for_responses}" \
                '{
                    "model": $model,
                    "input": $input,
                    "instructions": $instructions,
                    "tools": $tools,
                    "stream": false,
                    "parallel_tool_calls": false
                }')
        else
            payload=$(jq -n \
                --arg model "${model}" \
                --arg input "${last_user_content}" \
                --arg instructions "${instructions}" \
                '{
                    "model": $model,
                    "input": $input,
                    "instructions": $instructions,
                    "stream": false
                }')
        fi

        baish_debug "Copilot: sending to Responses API (model: ${model})"

        response=$(curl -s -w "\n%{http_code}" \
            -X POST \
            -H "Authorization: ${auth_header}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -H "Copilot-Integration-Id: vscode" \
            -d "${payload}" \
            "https://api.githubcopilot.com/responses" 2>/dev/null)

        local http_code
        http_code=$(echo "${response}" | tail -1)
        local body
        body=$(echo "${response}" | sed '$d')

        if [[ -z "${body}" ]]; then
            jq -n '{"ok": false, "error": {"code": "GENERIC_ERROR", "message": "Empty response from Copilot Responses API"}}'
            return 0
        fi

        if [[ "${http_code}" != "200" ]]; then
            local error_msg
            error_msg=$(echo "${body}" | jq -r '.message // .error // "Unknown error"' 2>/dev/null)
            if echo "${body}" | grep -qi "context_length_exceeded\|context.*exceeded\|too long"; then
                jq -n --arg msg "${error_msg}" '{"ok": false, "error": {"code": "CONTEXT_OVERFLOW", "message": $msg}}'
                return 0
            fi
            if [[ "${http_code}" == "401" ]]; then
                jq -n --arg msg "${error_msg}" '{"ok": false, "error": {"code": "TOKEN_EXPIRED", "message": $msg}}'
                return 0
            fi
            jq -n --arg msg "${error_msg}" '{"ok": false, "error": {"code": "GENERIC_ERROR", "message": $msg}}'
            return 0
        fi

        # Parse Responses API response
        local assistant_text
        assistant_text=$(echo "${body}" | jq -r '.output[].content[].text // empty' 2>/dev/null)

        # Check for tool calls in Responses API format
        local tool_calls="[]"
        if echo "${body}" | jq -e '.output[] | select(.type == "function_call")' &>/dev/null; then
            tool_calls=$(echo "${body}" | jq '[
                .output[] | select(.type == "function_call") | {
                    "id": .id,
                    "name": .name,
                    "arguments": (.arguments | if type == "string" then . else tostring end)
                }
            ]')
        fi

        jq -n \
            --arg text "${assistant_text}" \
            --argjson tc "${tool_calls}" \
            '{"ok": true, "assistant_text": $text, "tool_calls": $tc}'

    else
        # Chat Completions API for all other models
        url="https://api.githubcopilot.com/chat/completions"

        # Build Chat Completions payload
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

        baish_debug "Copilot: sending to Chat Completions API (model: ${model})"

        response=$(curl -s -w "\n%{http_code}" \
            -X POST \
            -H "Authorization: ${auth_header}" \
            -H "Content-Type: application/json" \
            -H "Accept: application/json" \
            -H "Copilot-Integration-Id: vscode" \
            -d "${payload}" \
            "https://api.githubcopilot.com/chat/completions" 2>&1)

        local http_code body
        http_code=$(echo "${response}" | tail -1)
        body=$(echo "${response}" | sed '$d')

        if [[ "${http_code}" != "200" ]]; then
            local error_msg
            error_msg=$(echo "${body}" | jq -r '.error.message // .message // "Unknown error"' 2>/dev/null)
            if echo "${body}" | grep -qi "context_length_exceeded\|context.*exceeded\|too long"; then
                jq -n --arg msg "${error_msg}" '{"ok": false, "error": {"code": "CONTEXT_OVERFLOW", "message": $msg}}'
                return 0
            fi
            if [[ "${http_code}" == "401" ]]; then
                jq -n --arg msg "${error_msg}" '{"ok": false, "error": {"code": "TOKEN_EXPIRED", "message": $msg}}'
                return 0
            fi
            jq -n --arg msg "${error_msg}" '{"ok": false, "error": {"code": "GENERIC_ERROR", "message": $msg}}'
            return 0
        fi

        # Parse Chat Completions response
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
            '{"ok": true, "assistant_text": $text, "tool_calls": $tc}'
    fi
}

# Public chat entry point with auto-reconnect on token expiry.
# Calls _copilot_chat_single; if it responds with error.code TOKEN_EXPIRED,
# refreshes the runtime token and retries exactly once.
# Returns structured JSON on stdout; exit code 0 always (even for errors).
provider_copilot_chat() {
    local messages_json="$1"
    local tools_json="$2"

    # Refresh runtime token before first attempt
    if ! _copilot_refresh_runtime_token; then
        jq -n '{"ok": false, "error": {"code": "AUTH_FAILURE", "message": "Authentication failed. Please re-authenticate with /connect."}}'
        return 0
    fi

    # First attempt
    local result
    result=$(_copilot_chat_single "${messages_json}" "${tools_json}")

    local ok error_code
    ok=$(echo "${result}" | jq -r '.ok // false')

    if [[ "${ok}" == "true" ]]; then
        echo "${result}"
        return 0
    fi

    # Check error code for auto-reconnect
    error_code=$(echo "${result}" | jq -r '.error.code // ""')

    if [[ "${error_code}" == "TOKEN_EXPIRED" ]]; then
        baish_debug "Copilot: token expired during chat, refreshing and retrying"

        # Force refresh the runtime token
        BAISH_COPILOT_RUNTIME_TOKEN=""
        BAISH_COPILOT_RUNTIME_EXPIRY=0

        if ! _copilot_refresh_runtime_token; then
            jq -n '{"ok": false, "error": {"code": "AUTH_FAILURE", "message": "Authentication failed. Please re-authenticate with /connect."}}'
            return 0
        fi

        # Retry
        result=$(_copilot_chat_single "${messages_json}" "${tools_json}")

        ok=$(echo "${result}" | jq -r '.ok // false')
        if [[ "${ok}" == "true" ]]; then
            echo "${result}"
            return 0
        fi

        # Retry also failed — propagate the retry error
        echo "${result}"
        return 0
    fi

    # Non-token-expiry error — propagate as-is
    echo "${result}"
    return 0
}
