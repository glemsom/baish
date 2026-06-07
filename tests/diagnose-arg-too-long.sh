#!/usr/bin/env bash
# BAISH — Diagnostic: "Argument list too long" in session.sh
# Reproduces the bug by simulating a long conversation with large tool results.
# Run: BAISH_DEBUG=1 ./tests/diagnose-arg-too-long.sh

set -euo pipefail

BAISH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${BAISH_ROOT}/lib/agent/config.sh"
source "${BAISH_ROOT}/lib/agent/session.sh"

# Reset session
BAISH_SESSION_MESSAGES=()
BAISH_SESSION_SKILL_NAMES=()
BAISH_SESSION_SKILL_CONTENTS=()
BAISH_SESSION_TOOL_ROUNDS=0
BAISH_AGENTS_MD_CONTENT=""

echo "═══ Diagnostic: Argument list too long in session.sh ═══"
echo ""
echo "ARG_MAX: $(getconf ARG_MAX 2>/dev/null || echo 'unknown')"
echo ""

# Simulate a long conversation: user msg → assistant + tool call → tool result.
# Each file read returns ~2KB. After N rounds, the session JSON passes ARG_MAX.
# At ~3 rounds with 2KB files, the full messages JSON is ~10KB total.
# We need to hit the ARG_MAX which is typically 128KB-2MB.
# Let's do ~50 rounds with ~40KB tool results each = ~2MB.

ROUNDS=50
CHUNK_SIZE=40000  # bytes per tool result

# Generate a large-ish string (repeating "x")
make_chunk() {
    python3 -c "print(${CHUNK_SIZE} * 'x')" 2>/dev/null || \
    yes x | head -c ${CHUNK_SIZE} | tr -d '\n'
}

echo "Generating ${ROUNDS} rounds with ${CHUNK_SIZE}-byte tool results..."
echo "Estimated total message JSON: ~$((ROUNDS * CHUNK_SIZE)) bytes"
echo ""

chunk=$(make_chunk)

for (( i = 1; i <= ROUNDS; i++ )); do
    baish_session_append_user_message "Read file /tmp/test${i}.txt"

    baish_session_append_assistant_response \
        "Here's file ${i} content." \
        "[{\"id\":\"call_${i}\",\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"/tmp/test${i}.txt\\\"}\"}]"

    # Large tool result (simulates reading a big file)
    tool_result=$(jq -n --arg content "${chunk}" '{"ok":true,"data":{"stdout":$content,"stderr":"","exit_code":0}}')
    baish_session_append_tool_result "call_${i}" "${tool_result}"
done

echo "Session has ${#BAISH_SESSION_MESSAGES[@]} messages."
echo ""

# Estimate session JSON size
echo "── Estimating accumulated messages size ──"
total_len=0
for msg in "${BAISH_SESSION_MESSAGES[@]}"; do
    len=${#msg}
    total_len=$((total_len + len))
done
echo "Sum of message string lengths: ${total_len} bytes"
echo ""

# Now try to build the request — this is the call that should fail
echo "── Running baish_session_build_request (this may trigger 'Argument list too long') ──"
# Suppress stderr (e.g., baish_agents_md_get_content not sourced)
if result_json=$(baish_session_build_request '[]' 2>/dev/null); then
    echo "${result_json}" > /tmp/baish_diagnose_result.json
    ok=$(jq -r '.messages | length' /tmp/baish_diagnose_result.json 2>/dev/null)
    echo "SUCCESS: build_request returned, messages array length=${ok}"
    echo ""
    echo "BUG FIXED — no Argument list too long at 2MB session."
    exit 0
else
    exit_code=$?
    echo ""
    echo "BUG REPRODUCED! exit_code=${exit_code}"
    echo "Error: ${result_json}"
    echo ""
    echo "This confirms the 'Argument list too long' bug."
    echo ""
    echo "Affected calls in session.sh:"
    echo "  - baish_session_append_user_message: --arg content \"\${text}\""
    echo "  - baish_session_append_assistant_response: --arg content \"\${text}\" --argjson tc \"\${normalized_tc}\""
    echo "  - baish_session_append_tool_result: --arg content \"\${content_str}\""
    echo "  - baish_session_build_request: --arg content \"\${skill_content}\" in loop"
    echo "  - baish_session_build_request: --argjson m \"\${msg}\" in loop"
    echo "  - baish_session_build_request: --argjson messages \"\${full_messages}\"   ← PRIMARY FAIL POINT"
    echo "  - baish_agent_provider_chat_capture: \${chat_fn} \"\${messages}\" \"\${tools_json}\""
    exit 1
fi
