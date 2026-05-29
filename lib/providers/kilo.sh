#!/usr/bin/env bash
# ── lib/providers/kilo.sh — Kilo Code Gateway provider ────────────

provider_api_key() {
    echo "${BAISH_API_KEY:-${KILO_API_KEY:-}}"
}

provider_base_url() {
    echo "${BAISH_BASE_URL:-https://gateway.kilocode.ai/v1}"
}

provider_default_model() {
    echo "${BAISH_MODEL:-openai/gpt-4o-mini}"
}

provider_models_url() {
    echo "https://api.kilo.ai/api/gateway/models"
}
