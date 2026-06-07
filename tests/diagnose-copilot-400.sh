#!/usr/bin/env bash
# BAISH — Copilot HTTP 400 diagnostic script
# Replicates the internal logic of _copilot_chat_single for gpt-5-mini
# and captures the full request/response for analysis.
# Run with: BAISH_DEBUG=1 ./tests/diagnose-copilot-400.sh

set -euo pipefail

BAISH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${BAISH_ROOT}/lib/agent/config.sh"
source "${BAISH_ROOT}/lib/providers/chat-parser.sh"

# ── Simulate the exact state from the bug report ──────────────────────────

MESSAGES_JSON=$(jq -n '[
    {"role": "system", "content": "You are BAISH, a Bash-first terminal AI coding agent."},
    {"role": "user", "content": "Respon with Hi"}
]')

TOOLS_JSON='[]'
MODEL="gpt-5-mini"

echo "═══ Diagnostic: Copilot gpt-5-mini → Responses API ═══"
echo ""
echo "Model:         ${MODEL}"
echo "Messages:      ${MESSAGES_JSON}"
echo "Tools:         ${TOOLS_JSON}"
echo ""

# ── Step 1: Extract system messages as instructions ──────────────────────

echo "── Step 1: Extract instructions ──"
system_msgs=$(echo "${MESSAGES_JSON}" | jq -c '[.[] | select(.role == "system") | .content] | join("\n---\n")')
echo "  system_msgs (raw):    ${system_msgs}"

instructions=$(echo "${system_msgs}" | jq -r '.')
echo "  instructions (clean): ${instructions}"
echo ""

# ── Step 2: Extract last user message ────────────────────────────────────

echo "── Step 2: Extract user input ──"
last_user_content=$(echo "${MESSAGES_JSON}" | jq -r '[.[] | select(.role == "user")] | last | .content // empty')
echo "  last_user_content:    ${last_user_content}"
echo ""

# ── Step 3: Build payload ────────────────────────────────────────────────

echo "── Step 3: Build payload (responses API format) ──"
payload=$(jq -n \
    --arg model "${MODEL}" \
    --arg input "${last_user_content}" \
    --arg instructions "${instructions}" \
    '{
        "model": $model,
        "input": $input,
        "instructions": $instructions,
        "stream": false
    }')
echo "  Payload:"
echo "${payload}" | jq '.'
echo ""

if echo "${payload}" | jq '.' >/dev/null 2>&1; then
    echo "  VALID JSON"
else
    echo "  INVALID JSON"
fi
echo ""

# ── Step 4: Show what curl would send ────────────────────────────────────

echo "── Step 4: Simulated curl command (dry run, no actual call) ──"
echo ""
echo "  curl -s -w \"\\n%{http_code}\" \\"
echo "    --connect-timeout 10 \\"
echo "    --max-time 120 \\"
echo "    -X POST \\"
echo "    -H \"Authorization: Bearer \${BAISH_COPILOT_RUNTIME_TOKEN}\" \\"
echo "    -H \"Content-Type: application/json\" \\"
echo "    -H \"Accept: application/json\" \\"
echo "    -H \"Copilot-Integration-Id: vscode\" \\"
echo "    -d '${payload}' \\"
echo "    \"https://api.githubcopilot.com/responses\""
echo ""

# ── Step 5: Alternative 1 — Chat Completions format ──────────────────────

echo "═══ Alt 1: Chat Completions format (what gpt-4o would use) ═══"
alt_payload3=$(jq -n \
    --arg model "${MODEL}" \
    --argjson messages "${MESSAGES_JSON}" \
    '{
        "model": $model,
        "messages": $messages,
        "stream": false
    }')
echo "${alt_payload3}" | jq '.'
echo ""

echo "── Corresponding curl ──"
echo "  curl -s -w \"\\n%{http_code}\" \\"
echo "    --connect-timeout 10 \\"
echo "    --max-time 120 \\"
echo "    -X POST \\"
echo "    -H \"Authorization: Bearer \${BAISH_COPILOT_RUNTIME_TOKEN}\" \\"
echo "    -H \"Content-Type: application/json\" \\"
echo "    -H \"Accept: application/json\" \\"
echo "    -H \"Copilot-Integration-Id: vscode\" \\"
echo "    -d '${alt_payload3}' \\"
echo "    \"https://api.githubcopilot.com/chat/completions\""
echo ""

echo "═══════════════════════════════════════════════════════════"
echo ""
echo "The bug: gpt-5-mini routes to Responses API (/responses)"
echo "         which returns HTTP 400."
echo ""
echo "Hypothesis 1 (MOST LIKELY): gpt-5-mini is not a Responses-API model."
echo "  → It should route through Chat Completions like gpt-4o."
echo "  → The routing if [[ \"\${model}\" == gpt-5* ]] is too broad."
echo ""
echo "Hypothesis 2: The /responses endpoint doesn't exist on Copilot."
echo "  → All gpt-5 models would fail, not just mini."
echo ""
echo "Hypothesis 3: The payload format is incompatible."
echo "  → E.g., instructions field not supported, input must be array."
echo ""
echo "To test Hypothesis 1: change router to send gpt-5-mini/nano"
echo "to Chat Completions instead of Responses API."
