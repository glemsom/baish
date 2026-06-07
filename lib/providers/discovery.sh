#!/usr/bin/env bash
# BAISH — Provider discovery and infrastructure
# Scans lib/providers/*.sh, sources them, validates required functions,
# detects ID collisions, and registers providers.

# Guard against re-initialization when discovery.sh is sourced
# mid-loop (the glob includes discovery.sh itself)
if [[ -z "${BAISH_DISCOVERY_INIT:-}" ]]; then
    BAISH_DISCOVERY_INIT=1
    BAISH_DISCOVERED_PROVIDERS=()
    BAISH_PROVIDER_IDS=()
fi

# Discover and register all providers from lib/providers/*.sh
baish_discover_providers() {
    local providers_dir="${BAISH_ROOT}/lib/providers"
    if [[ ! -d "${providers_dir}" ]]; then
        baish_debug "No providers directory found"
        return
    fi

    local before_funcs
    before_funcs=$(declare -F | awk '{print $3}')

    local provider_file
    for provider_file in "${providers_dir}"/*.sh; do
        [[ -f "${provider_file}" ]] || continue

        # Source the provider in current shell to register its functions
        source "${provider_file}"

        local after_funcs new_funcs
        after_funcs=$(declare -F | awk '{print $3}')
        new_funcs=$(comm -13 <(echo "${before_funcs}" | sort) <(echo "${after_funcs}" | sort))

        # Extract provider ID from provider_<id>_metadata function
        local provider_id
        provider_id=$(echo "${new_funcs}" | grep -oP '^provider_\K[^_]+(?=_metadata$)' | head -1)

        if [[ -z "${provider_id}" ]]; then
            # No new metadata function appeared in the environment — the file may
            # redefine an existing one (duplicate) or may not be a provider file.
            # Grep the source directly to find any provider_*_metadata definition.
            local file_provider_id
            file_provider_id=$(grep -oP '^\s*provider_\K[^_]+(?=_metadata\s*\(\s*\)?\s*\{?)' "${provider_file}" | head -1)
            if [[ -n "${file_provider_id}" ]]; then
                # This file defines a metadata function. If it's already registered, collide.
                for pid in "${BAISH_PROVIDER_IDS[@]}"; do
                    if [[ "${pid}" == "${file_provider_id}" ]]; then
                        baish_output_error "Provider ID collision: '${file_provider_id}' is already registered. Cannot load duplicate provider."
                        exit 1
                    fi
                done
                # Not a collision — register it (functions were pre-sourced or already loaded)
                provider_id="${file_provider_id}"
            else
                baish_debug "Could not extract provider ID from ${provider_file}"
                before_funcs="${after_funcs}"
                continue
            fi
        fi

        # Check for ID collision — is this provider already registered?
        local pid
        for pid in "${BAISH_PROVIDER_IDS[@]}"; do
            if [[ "${pid}" == "${provider_id}" ]]; then
                baish_output_error "Provider ID collision: '${provider_id}' is already registered. Cannot load duplicate provider."
                exit 1
            fi
        done

        # Validate required functions exist
        local required_funcs=(
            "provider_${provider_id}_metadata"
            "provider_${provider_id}_auth"
            "provider_${provider_id}_list_models"
            "provider_${provider_id}_chat"
        )
        local func
        for func in "${required_funcs[@]}"; do
            if ! declare -F "${func}" &>/dev/null; then
                baish_output_error "Provider '${provider_id}' missing required function: ${func}"
                # Unregister partial provider
                return 1
            fi
        done

        BAISH_PROVIDER_IDS+=("${provider_id}")
        baish_debug "Discovered provider: ${provider_id}"

        # Update before_funcs for next iteration so diff only captures
        # functions introduced by the next provider file
        before_funcs="${after_funcs}"
    done
}

# Get metadata for a provider as JSON
baish_provider_metadata() {
    local provider_id="$1"
    local metadata_fn="provider_${provider_id}_metadata"
    if ! declare -F "${metadata_fn}" &>/dev/null; then
        baish_output_error "Unknown provider: ${provider_id}"
        return 1
    fi
    "${metadata_fn}"
}

# Select a provider interactively using fzf
# Sets BAISH_CURRENT_PROVIDER and BAISH_CURRENT_MODEL
baish_provider_select_interactive() {
    local selectable_providers=()
    local selectable_ids=()
    local selectable_labels=()

    local pid
    for pid in "${BAISH_PROVIDER_IDS[@]}"; do
        local metadata
        metadata=$(baish_provider_metadata "${pid}")
        local selectable
        selectable=$(echo "${metadata}" | jq -r '.selectable // false')
        if [[ "${selectable}" == "true" ]]; then
            selectable_providers+=("${pid}")
            local label
            label=$(echo "${metadata}" | jq -r '.label')
            selectable_labels+=("${label}")
            selectable_ids+=("${pid}")
        fi
    done

    if (( ${#selectable_providers[@]} == 0 )); then
        baish_output_error "No selectable providers available"
        return 1
    fi

    if (( ${#selectable_providers[@]} == 1 )); then
        # Only one selectable provider — auto-select
        BAISH_CURRENT_PROVIDER="${selectable_providers[0]}"
        baish_debug "Auto-selected single provider: ${BAISH_CURRENT_PROVIDER}"
    else
        # Use fzf to pick
        local picked_label
        picked_label=$(printf '%s\n' "${selectable_labels[@]}" | fzf \
            --header="Select an LLM provider" \
            --reverse \
            --layout=reverse \
            --border=rounded \
            --height=40% \
            --no-multi)

        if [[ -z "${picked_label}" ]]; then
            baish_output_error "No provider selected"
            return 1
        fi

        # Find the provider ID matching the picked label
        local i
        for i in "${!selectable_labels[@]}"; do
            if [[ "${selectable_labels[$i]}" == "${picked_label}" ]]; then
                BAISH_CURRENT_PROVIDER="${selectable_ids[$i]}"
                break
            fi
        done
    fi

    baish_debug "Provider selected: ${BAISH_CURRENT_PROVIDER}"
}

# Select a model interactively using fzf
# Sets BAISH_CURRENT_MODEL
baish_model_select_interactive() {
    local list_models_fn="provider_${BAISH_CURRENT_PROVIDER}_list_models"
    if ! declare -F "${list_models_fn}" &>/dev/null; then
        baish_output_error "Provider ${BAISH_CURRENT_PROVIDER} has no list_models function"
        return 1
    fi

    local models_json
    models_json=$("${list_models_fn}")
    local model_count
    model_count=$(echo "${models_json}" | jq 'length')

    if (( model_count == 0 )); then
        baish_output_error "No models available for provider ${BAISH_CURRENT_PROVIDER}"
        return 1
    fi

    if (( model_count == 1 )); then
        BAISH_CURRENT_MODEL=$(echo "${models_json}" | jq -r '.[0].id')
        baish_debug "Auto-selected single model: ${BAISH_CURRENT_MODEL}"
        return 0
    fi

    # Check if provider has a grouped_display field (for Kilo prefix grouping)
    local grouped_display
    grouped_display=$(echo "${models_json}" | jq -r '.[0].group // empty')

    local picked_model_id
    if [[ -n "${grouped_display}" ]]; then
        # Grouped display: use grouped input for fzf
        local input=""
        local i
        for i in $(seq 0 $((model_count - 1))); do
            local model_id model_name group
            model_id=$(echo "${models_json}" | jq -r ".[$i].id")
            model_name=$(echo "${models_json}" | jq -r ".[$i].name // .id")
            group=$(echo "${models_json}" | jq -r ".[$i].group // \"other\"")
            input+="${group}\t${model_name}\t${model_id}\n"
        done

        picked_model_id=$(printf '%b' "${input}" | fzf \
            --header="Select a model" \
            --reverse \
            --layout=reverse \
            --border=rounded \
            --height=40% \
            --no-multi \
            --delimiter='\t' \
            --with-nth=1,2 \
            --tabstop=1 \
            --ansi | awk -F'\t' '{print $3}')
    else
        # Flat display
        picked_model_id=$(echo "${models_json}" | jq -r '.[] | [.name // .id, .id] | @tsv' | fzf \
            --header="Select a model" \
            --reverse \
            --layout=reverse \
            --border=rounded \
            --height=40% \
            --no-multi \
            --with-nth=1 \
            --delimiter='\t' | awk -F'\t' '{print $2}')
    fi

    if [[ -z "${picked_model_id}" ]]; then
        baish_output_error "No model selected"
        return 1
    fi

    BAISH_CURRENT_MODEL="${picked_model_id}"
    baish_debug "Model selected: ${BAISH_CURRENT_MODEL}"
}

# Unified provider chat function
# Calls the current provider's chat function and returns {assistant_text, tool_calls}
# Args: messages_json tools_json
# Writes result to stdout, returns provider's exit code
baish_provider_chat() {
    local messages_json="$1"
    local tools_json="$2"
    local chat_fn="provider_${BAISH_CURRENT_PROVIDER}_chat"

    if ! declare -F "${chat_fn}" &>/dev/null; then
        baish_output_error "Provider ${BAISH_CURRENT_PROVIDER} has no chat function"
        return 1
    fi

    "${chat_fn}" "${messages_json}" "${tools_json}"
}

# Check if current provider has environment-based auth
# Returns 0 if env auth exists, 1 otherwise
baish_provider_has_env_auth() {
    local has_env_fn="provider_${BAISH_CURRENT_PROVIDER}_has_env_auth"
    if declare -F "${has_env_fn}" &>/dev/null; then
        "${has_env_fn}"
        return $?
    fi
    return 1
}

# Authenticate the current provider
baish_provider_auth() {
    local auth_fn="provider_${BAISH_CURRENT_PROVIDER}_auth"
    if ! declare -F "${auth_fn}" &>/dev/null; then
        baish_output_error "Provider ${BAISH_CURRENT_PROVIDER} has no auth function"
        return 1
    fi

    # Check for env auth first
    if baish_provider_has_env_auth; then
        baish_debug "Environment-based auth detected for ${BAISH_CURRENT_PROVIDER}, skipping interactive auth"
        return 0
    fi

    "${auth_fn}"
}
