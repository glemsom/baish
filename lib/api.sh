#!/usr/bin/env bash
# ── lib/api.sh — provider-agnostic transport + context helpers ────
# Requires: lib/config.sh and lib/provider.sh sourced first.

api_http_get_json() {
    local url="$1"
    local api_key="$2"
    local max_time="${3:-30}"

    local response
    response=$(curl -sf --max-time "$max_time" \
        -H "Authorization: Bearer ${api_key}" \
        "$url" 2>/dev/null) || {
        echo "Error: Could not reach $url" >&2
        return 1
    }

    if [[ -z "$response" ]]; then
        echo "Error: Empty response from $url" >&2
        return 1
    fi

    echo "$response"
}

api_http_post_json() {
    local url="$1"
    local api_key="$2"
    local body="$3"
    local max_time="${4:-120}"

    local status_code=""
    local response=""
    local attempt=0

    while [[ $attempt -lt 2 ]]; do
        attempt=$((attempt + 1))

        local tmpfile
        tmpfile=$(mktemp)
        status_code=$(curl -s --max-time "$max_time" \
            -o "$tmpfile" \
            -w "%{http_code}" \
            -X POST \
            -H "Authorization: Bearer ${api_key}" \
            -H "Content-Type: application/json" \
            "$url" \
            -d "$body" 2>/dev/null) || status_code="000"

        response=$(cat "$tmpfile")
        rm -f "$tmpfile"

        case "$status_code" in
            200)
                if ! echo "$response" | jq empty 2>/dev/null; then
                    echo "Error: Received malformed JSON from API." >&2
                    return 1
                fi
                echo "$response"
                return 0
                ;;
            429|500|502|503|504)
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
                echo "Error: Network error — could not reach ${url}." >&2
                return 1
                ;;
            *)
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

api_estimate_tokens() {
    local text="$1"
    local len=${#text}
    echo $(( (len + 3) / 4 ))
}

api_trim_messages() {
    local messages_json="$1"
    local max_tokens="$2"
    local target=$(( (max_tokens * 80) / 100 ))

    local count
    count=$(echo "$messages_json" | jq 'length')

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
        echo "$messages_json"
        return 0
    fi

    local last_user_idx=0
    for (( i = count - 1; i >= 0; i-- )); do
        local role
        role=$(echo "$messages_json" | jq -r ".[$i].role")
        if [[ "$role" == "user" ]]; then
            last_user_idx=$i
            break
        fi
    done

    local keep_before=""
    if [[ $last_user_idx -gt 1 ]]; then
        local prev_role
        prev_role=$(echo "$messages_json" | jq -r ".[$((last_user_idx - 1))].role")
        if [[ "$prev_role" == "assistant" ]]; then
            keep_before="$((last_user_idx - 1))"
        fi
    fi

    local trimmed="["
    local first=true

    for (( i = 0; i < count; i++ )); do
        local keep=false
        if [[ $i -eq 0 ]]; then
            keep=true
        elif [[ -n "$keep_before" && $i -eq $keep_before ]]; then
            keep=true
        elif [[ $i -ge $last_user_idx ]]; then
            keep=true
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
