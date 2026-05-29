#!/usr/bin/env bash
# ── lib/config.sh — Configuration loading with env override ─────────
# Load order: defaults → config file → env vars (env wins)

# ── Defaults ────────────────────────────────────────────────────────
BAISH_PROVIDER="${BAISH_PROVIDER:-kilo}"
BAISH_MODEL="${BAISH_MODEL:-}"
BAISH_API_KEY="${BAISH_API_KEY:-}"
BAISH_BASE_URL="${BAISH_BASE_URL:-}"
BAISH_MAX_CONTEXT="${BAISH_MAX_CONTEXT:-32000}"
BAISH_SKILLS_DIR="${BAISH_SKILLS_DIR:-$HOME/.baish/skills}"
BAISH_CONFIG_FILE="${BAISH_CONFIG_FILE:-$HOME/.baish/config}"


# ── Load config file (key=value, # comments) ──────────────────────
config_load_file() {
    local file="${BAISH_CONFIG_FILE}"
    if [[ ! -f "$file" ]]; then
        return 0
    fi
    while IFS='=' read -r key value; do
        # Skip comments and blanks
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        key="$(echo "$key" | xargs)"
        value="$(echo "$value" | xargs)"
        case "$key" in
            BAISH_PROVIDER)  BAISH_PROVIDER="$value" ;;
            BAISH_MODEL)     BAISH_MODEL="$value" ;;
            BAISH_API_KEY)   BAISH_API_KEY="$value" ;;
            BAISH_BASE_URL)  BAISH_BASE_URL="$value" ;;
            BAISH_MAX_CONTEXT) BAISH_MAX_CONTEXT="$value" ;;
            BAISH_SKILLS_DIR)  BAISH_SKILLS_DIR="$value" ;;
        esac
    done < "$file"
}

# ── Apply env overrides (already handled by ${VAR:-default} above) ─
# After sourcing, env vars already beat defaults because of := syntax.
# We now fill in provider-derived values if not explicitly set.

config_resolve_provider() {
    if [[ -z "$BAISH_API_KEY" ]]; then
        BAISH_API_KEY="$(provider_api_key)"
    fi

    if [[ -z "$BAISH_BASE_URL" ]]; then
        BAISH_BASE_URL="$(provider_base_url)"
    fi

    if [[ -z "$BAISH_MODEL" ]]; then
        BAISH_MODEL="$(provider_default_model)"
    fi
}

# ── Persist a config value to the config file ──────────────────────
# Args: key  value
config_set() {
    local key="$1" value="$2"
    local file="${BAISH_CONFIG_FILE}"

    mkdir -p "$(dirname "$file")"

    if [[ -f "$file" ]] && grep -q "^${key}[[:space:]]*=" "$file" 2>/dev/null; then
        # Update existing line in place
        sed -i "s|^${key}[[:space:]]*=.*|${key}=${value}|" "$file"
    else
        # Append new key=value
        echo "${key}=${value}" >> "$file"
    fi
}

# ── Main init ──────────────────────────────────────────────────────
config_init() {
    config_load_file

    if ! provider_init; then
        exit 1
    fi

    config_resolve_provider

    # Validate API key is set
    if [[ -z "$BAISH_API_KEY" ]]; then
        echo -e "\033[0;31mError:\033[0m No API key found. Set BAISH_API_KEY or configure ~/.baish/config" >&2
        echo -e "\033[0;31mError:\033[0m Alternatively, set GITHUB_TOKEN (github provider) or KILO_API_KEY (kilo provider)" >&2
        exit 1
    fi

    # Validate base URL is set
    if [[ -z "$BAISH_BASE_URL" ]]; then
        echo -e "\033[0;31mError:\033[0m No API base URL resolved. Set BAISH_BASE_URL or check BAISH_PROVIDER value." >&2
        exit 1
    fi
}
