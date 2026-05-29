#!/usr/bin/env bash
# ── lib/providers/base.sh — shared provider defaults ───────────────

provider_name() {
    echo "${BAISH_PROVIDER:-}"
}

provider_api_key() {
    echo "${BAISH_API_KEY:-}"
}

provider_base_url() {
    echo "${BAISH_BASE_URL:-}"
}

provider_default_model() {
    echo "${BAISH_MODEL:-gpt-4o-mini}"
}

provider_models_url() {
    local base_url
    base_url="$(provider_base_url)"

    if [[ -z "$base_url" ]]; then
        return 0
    fi

    echo "${base_url%/}/models"
}

provider_fetch_models() {
    local url
    url="$(provider_models_url)"

    if [[ -z "$url" ]]; then
        echo "Error: Provider '$(provider_name)' does not expose a models endpoint" >&2
        return 1
    fi

    api_http_get_json "$url" "$(provider_api_key)" 30
}

provider_extract_model_list() {
    local models_json="$1"

    echo "$models_json" | jq -r '
        if type == "object" and (.data | type? == "array") then
            .data[].id // empty
        elif type == "array" then
            .[].id // empty
        else
            empty
        end
    ' 2>/dev/null | sort -u
}

provider_lookup_model_context() {
    local model="${1:-$BAISH_MODEL}"
    local models_json
    models_json="$(provider_fetch_models 2>/dev/null)" || {
        echo "$BAISH_MAX_CONTEXT"
        return 0
    }

    local model_context
    model_context=$(echo "$models_json" | jq -r \
        --arg m "$model" \
        '
        def models:
            if type == "object" and (.data | type? == "array") then .data
            elif type == "array" then .
            else []
            end;

        models[]
        | select(
            .id == $m
            or .name == $m
            or ((.id // "") | contains($m))
            or ((.name // "") | contains($m))
        )
        | .max_context // .context_length // .max_input_tokens // empty
        ' 2>/dev/null | head -n 1)

    if [[ -n "$model_context" ]]; then
        echo "$model_context"
    else
        echo "$BAISH_MAX_CONTEXT"
    fi
}

provider_chat() {
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

    local base_url
    base_url="$(provider_base_url)"
    api_http_post_json "${base_url%/}/chat/completions" "$(provider_api_key)" "$body" 120
}

provider_extract_text() {
    local response_json="$1"
    echo "$response_json" | jq -r '.choices[0].message.content // empty' 2>/dev/null
}

provider_extract_tool_calls() {
    local response_json="$1"
    echo "$response_json" | jq -c '.choices[0].message.tool_calls // []' 2>/dev/null
}
