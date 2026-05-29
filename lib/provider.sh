#!/usr/bin/env bash
# ── lib/provider.sh — provider loader + stable interface ───────────

_PROVIDER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/providers" && pwd)"
_PROVIDER_LOADED=""

provider_init() {
    local provider="${BAISH_PROVIDER:-kilo}"

    case "$provider" in
        github|kilo)
            ;;
        *)
            echo "Error: Unknown provider '$provider'. Supported providers: github, kilo." >&2
            return 1
            ;;
    esac

    if [[ "${_PROVIDER_LOADED:-}" == "$provider" ]]; then
        return 0
    fi

    # shellcheck source=./providers/base.sh
    source "${_PROVIDER_LIB_DIR}/base.sh"
    # shellcheck source=./providers/github.sh
    # shellcheck source=./providers/kilo.sh
    source "${_PROVIDER_LIB_DIR}/${provider}.sh"

    _PROVIDER_LOADED="$provider"
}
