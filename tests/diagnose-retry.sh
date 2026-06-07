#!/usr/bin/env bash
# Diagnose: test the retry loop by directly simulating kilo's error path.
# We call baish_provider_parse_error_body (the shared parser) directly,
# then simulate what baish_agent_provider_chat_capture's retry loop does.
set -euo pipefail

BAISH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export BAISH_DEBUG=1

# Source only what's needed
source "${BAISH_ROOT}/lib/agent/config.sh"
source "${BAISH_ROOT}/lib/providers/chat-parser.sh"

echo "=== Test 1: parse_error_body produces GENERIC_ERROR for network failure ==="
result=$(baish_provider_parse_error_body "000" "" \
    '.error.message // .message // "Unknown error"' "AUTH_FAILURE" "Kilo: ")

echo "Error JSON for http_code=000, body='':"
echo "${result}" | jq .
code=$(echo "${result}" | jq -r '.error.code')
echo "Error code: [${code}]"
echo "Is GENERIC_ERROR? $([[ "${code}" == "GENERIC_ERROR" ]] && echo YES || echo NO)"
echo ""

echo "=== Test 2: simulate the retry loop ==="
max_retries=3
retry_delay=0.1

# Simulated provider that always returns a GENERIC_ERROR
simulate_provider_error() {
    jq -n \
        --arg code "GENERIC_ERROR" \
        --arg msg "Kilo: Network error — could not reach the API server. Check your connection and try again." \
        '{"ok": false, "error": {"code": $code, "message": $msg}}'
}

for (( attempt = 1; attempt <= max_retries; attempt++ )); do
    result=$(simulate_provider_error)
    exit_code=$?

    echo "Attempt ${attempt}: exit_code=${exit_code}"

    if (( exit_code == 0 )); then
        ok=$(echo "${result}" | jq -r '.ok // false')
        error_code=$(echo "${result}" | jq -r '.error.code // ""')

        echo "  ok=${ok}, error_code=[${error_code}]"

        if [[ "${ok}" == "true" ]]; then
            echo "  → SUCCESS"
            break
        fi

        if [[ "${error_code}" != "GENERIC_ERROR" ]]; then
            echo "  → Non-retryable error, breaking"
            break
        fi

        echo "  → GENERIC_ERROR detected, would retry..."
    else
        echo "  → Infra failure, would retry..."
    fi

    if (( attempt < max_retries )); then
        echo "  Sleeping ${retry_delay}s before retry..."
        sleep "${retry_delay}"
    fi
done

echo ""
echo "=== Final result after ${attempt} attempts ==="
echo "ok=$(echo "${result}" | jq -r '.ok'), error=$(echo "${result}" | jq -r '.error.message')"
