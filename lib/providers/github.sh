#!/usr/bin/env bash
# ── lib/providers/github.sh — GitHub Copilot provider ─────────────

provider_api_key() {
    echo "${BAISH_API_KEY:-${GITHUB_TOKEN:-}}"
}

provider_base_url() {
    echo "${BAISH_BASE_URL:-https://models.inference.ai.azure.com}"
}

provider_default_model() {
    echo "${BAISH_MODEL:-gpt-4o-mini}"
}

provider_extract_model_list() {
    local models_json="$1"

    echo "$models_json" | jq -r '
        if type == "array" then
            .[] | select(.task == "chat-completion") | .name // empty
        elif type == "object" and (.data | type? == "array") then
            .data[].id // empty
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
        if type == "array" then
            .[]
            | select(
                .name == $m
                or .id == $m
                or ((.name // "") | contains($m))
                or ((.id // "") | contains($m))
            )
            | .max_context // .context_length // .max_input_tokens // empty
        elif type == "object" and (.data | type? == "array") then
            .data[]
            | select(
                .id == $m
                or .name == $m
                or ((.id // "") | contains($m))
                or ((.name // "") | contains($m))
            )
            | .max_context // .context_length // .max_input_tokens // empty
        else
            empty
        end
        ' 2>/dev/null | head -n 1)

    if [[ -n "$model_context" ]]; then
        echo "$model_context"
    else
        echo "$BAISH_MAX_CONTEXT"
    fi
}
