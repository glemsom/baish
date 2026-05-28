#!/usr/bin/env bash
# ── lib/api.sh — OpenAI-compatible API client & context management ──
# Requires: lib/config.sh sourced first (BAISH_BASE_URL, BAISH_API_KEY, etc.)

# ── Hardcoded model context fallback table ─────────────────────────
declare -A _API_MODEL_CONTEXT=(
    ["gpt-5"]="200000"
    ["gpt-5-mini"]="128000"
    ["gpt-5-nano"]="128000"
    ["gpt-4o"]="128000"
    ["gpt-4o-mini"]="128000"
    ["gpt-4-turbo"]="128000"
    ["gpt-4"]="8192"
    ["gpt-3.5-turbo"]="16385"
    ["claude-sonnet-4-20250514"]="200000"
    ["claude-3-5-sonnet-20241022"]="200000"
    ["claude-3-opus-20240229"]="200000"
    ["gemini-2.5-pro"]="1000000"
    ["gemini-2.5-flash"]="1000000"
    ["gemini-2.0-flash"]="1000000"
)

# ── Fetch available models from provider ───────────────────────────
# Returns: raw JSON from /models endpoint on stdout
# Exit codes: 0 = success, 1 = error
api_fetch_models() {
    local response
    response=$(curl -sf --max-time 30 \
        -H "Authorization: Bearer ${BAISH_API_KEY}" \
        "${BAISH_BASE_URL}/models" 2>/dev/null) || {
        echo "Error: Could not reach ${BAISH_BASE_URL}/models" >&2
        return 1
    }

    if [[ -z "$response" ]]; then
        echo "Error: Empty response from /models endpoint" >&2
        return 1
    fi

    echo "$response"
}

# ── Look up model context window ───────────────────────────────────
api_lookup_model_context() {
    local model="${BAISH_MODEL}"
    local context=""

    # 1. Try /models endpoint
    local models_resp
    models_resp=$(curl -sf --max-time 10 \
        -H "Authorization: Bearer ${BAISH_API_KEY}" \
        "${BAISH_BASE_URL}/models" 2>/dev/null) || models_resp=""

    if [[ -n "$models_resp" ]]; then
        # Try OpenAI format (.data[]) first, then flat array (.[])
        local model_data
        model_data=$(echo "$models_resp" | jq -r \
            --arg m "$model" \
            'if type == "array" then .[] else .data[] end | select(.id == $m or (.id | contains($m)) or .name == $m or (.name | contains($m))) | .max_context // .context_length // empty' 2>/dev/null) || model_data=""
        if [[ -n "$model_data" ]]; then
            echo "$model_data"
            return 0
        fi
    fi

    # 2. Hardcoded lookup table
    for key in "${!_API_MODEL_CONTEXT[@]}"; do
        if [[ "$model" == *"$key"* ]]; then
            context="${_API_MODEL_CONTEXT[$key]}"
            break
        fi
    done

    if [[ -n "$context" ]]; then
        echo "$context"
        return 0
    fi

    # 3. Fallback to config value
    echo "$BAISH_MAX_CONTEXT"
    return 0
}

# ── Token estimation (bash heuristic: ~4 chars per token) ─────────
api_estimate_tokens() {
    local text="$1"
    local len=${#text}
    echo $(( (len + 3) / 4 ))
}

# ── Chat completion ────────────────────────────────────────────────
# Args: messages_json  [tools_json]
# Returns: raw JSON response on stdout
# Exit codes: 0 = success, 1 = error
api_chat() {
    local messages_json="$1"
    local tools_json="${2:-}"

    local body
    if [[ -n "$tools_json" ]]; then
        body=$(jq -n \
            --arg model "$BAISH_MODEL" \
            --argjson messages "$messages_json" \
            --argjson tools "$tools_json" \
            '{model: $model, messages: $messages, tools: $tools, stream: false}')
    else
        body=$(jq -n \
            --arg model "$BAISH_MODEL" \
            --argjson messages "$messages_json" \
            '{model: $model, messages: $messages, stream: false}')
    fi

    local status_code=""
    local response=""
    local attempt=0

    while [[ $attempt -lt 2 ]]; do
        attempt=$((attempt + 1))

        # Make the API call, capturing both response and HTTP status
        local tmpfile
        tmpfile=$(mktemp)
        status_code=$(curl -s --max-time 120 \
            -o "$tmpfile" \
            -w "%{http_code}" \
            -X POST \
            -H "Authorization: Bearer ${BAISH_API_KEY}" \
            -H "Content-Type: application/json" \
            "${BAISH_BASE_URL}/chat/completions" \
            -d "$body" 2>/dev/null) || status_code="000"

        response=$(cat "$tmpfile")
        rm -f "$tmpfile"

        case "$status_code" in
            200)
                # Validate JSON
                if ! echo "$response" | jq empty 2>/dev/null; then
                    echo "Error: Received malformed JSON from API." >&2
                    return 1
                fi
                echo "$response"
                return 0
                ;;
            429|500|502|503|504)
                # Transient error — retry once
                if [[ $attempt -eq 1 ]]; then
                    sleep 2
                    continue
                fi
                echo "Error: API returned $status_code after retry." >&2
                return 1
                ;;
            401)
                echo "Error: API key rejected (401 Unauthorized). Check BAISH_API_KEY." >&2
                return 1
                ;;
            403)
                echo "Error: API access forbidden (403)." >&2
                return 1
                ;;
            000)
                echo "Error: Network error — could not reach ${BAISH_BASE_URL}." >&2
                return 1
                ;;
            *)
                # Other errors — show detail if available
                local error_detail
                error_detail=$(echo "$response" | jq -r '.error.message // .error // "Unknown error"' 2>/dev/null) || error_detail=""
                if [[ -n "$error_detail" ]]; then
                    echo "Error: API returned $status_code — $error_detail" >&2
                else
                    echo "Error: API returned $status_code." >&2
                fi
                return 1
                ;;
        esac
    done
}

# ── Extract assistant text content ─────────────────────────────────
api_extract_text() {
    local response_json="$1"
    echo "$response_json" | jq -r '.choices[0].message.content // empty' 2>/dev/null
}

# ── Extract tool calls array ───────────────────────────────────────
api_extract_tool_calls() {
    local response_json="$1"
    echo "$response_json" | jq -c '.choices[0].message.tool_calls // []' 2>/dev/null
}

# ── Trim messages to fit within token budget ───────────────────────
# Args: messages_json  max_tokens
# Returns: trimmed messages JSON
# Strategy: drop oldest non-system messages until under 80% of max_tokens.
#           Always preserves system prompt and the last user/assistant exchange.
api_trim_messages() {
    local messages_json="$1"
    local max_tokens="$2"
    local target=$(( (max_tokens * 80) / 100 ))

    local count
    count=$(echo "$messages_json" | jq 'length')

    # Build a list of message indices with their token estimates
    # Index 0 is typically system — always keep
    # Always keep the last exchange (last user + last assistant if present)

    # Calculate tokens for each message
    local -a msg_tokens=()
    local total_tokens=0
    local i
    for (( i = 0; i < count; i++ )); do
        local content
        content=$(echo "$messages_json" | jq -r ".[$i].content // \"\"")
        local tool_calls_json
        tool_calls_json=$(echo "$messages_json" | jq -c ".[$i].tool_calls // []" 2>/dev/null)
        local tc_len=${#tool_calls_json}
        local tokens
        tokens=$(( (${#content} + tc_len + 3) / 4 ))
        msg_tokens+=("$tokens")
        total_tokens=$((total_tokens + tokens))
    done

    if [[ $total_tokens -le $target ]]; then
        # Already within budget
        echo "$messages_json"
        return 0
    fi

    # Determine which indices to keep:
    # 0 (system), and the last user message + any assistant/tool messages after it
    # We drop from the middle (oldest non-system messages first)

    # Find the index of the last user message
    local last_user_idx=0
    for (( i = count - 1; i >= 0; i-- )); do
        local role
        role=$(echo "$messages_json" | jq -r ".[$i].role")
        if [[ "$role" == "user" ]]; then
            last_user_idx=$i
            break
        fi
    done

    # Collect indices to drop: from 1 up to (but not including) the exchange before last
    # Find the exchange boundary: go back from last_user_idx to find the preceding assistant message
    # Keep everything from the last user message onwards

    # Indices to keep: 0 (system), and everything from last_user_idx onwards
    # Also try to keep the assistant message just before last_user_idx if it exists
    local keep_before=""
    if [[ $last_user_idx -gt 1 ]]; then
        local prev_role
        prev_role=$(echo "$messages_json" | jq -r ".[$((last_user_idx - 1))].role")
        if [[ "$prev_role" == "assistant" ]]; then
            keep_before="$((last_user_idx - 1))"
        fi
    fi

    # Build trimmed array
    local trimmed="["
    local first=true

    for (( i = 0; i < count; i++ )); do
        local keep=false
        if [[ $i -eq 0 ]]; then
            keep=true  # system prompt
        elif [[ -n "$keep_before" && $i -eq $keep_before ]]; then
            keep=true
        elif [[ $i -ge $last_user_idx ]]; then
            keep=true  # last exchange onwards
        fi

        if $keep; then
            local msg
            msg=$(echo "$messages_json" | jq -c ".[$i]")
            if $first; then
                trimmed+="$msg"
                first=false
            else
                trimmed+=",$msg"
            fi
        fi
    done
    trimmed+="]"

    echo "$trimmed"
}
