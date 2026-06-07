#!/usr/bin/env bats
# BAISH — Tests: Session Management (lib/agent/session.sh)

setup() {
    # Isolate to a temp directory
    BAISH_STATE_DIR="$(mktemp -d)"
    export BAISH_STATE_DIR

    BAISH_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
    export BAISH_ROOT

    BAISH_DEBUG=0
    export BAISH_DEBUG

    # Reset session arrays
    BAISH_SESSION_MESSAGES=()
    BAISH_SESSION_SKILL_NAMES=()
    BAISH_SESSION_SKILL_CONTENTS=()
    BAISH_SESSION_TOOL_ROUNDS=0

    # Reset AGENTS.md content between tests
    BAISH_AGENTS_MD_CONTENT=""

    # Clean up any AGENTS.md files left by previous tests
    rm -f "${HOME}/.baish/AGENTS.md"
    rm -f "$(pwd)/AGENTS.md"

    # Source modules under test
    source "${BAISH_ROOT}/lib/agent/config.sh"
    source "${BAISH_ROOT}/lib/agent/session.sh"
    source "${BAISH_ROOT}/lib/agent/agents-md.sh"
}

teardown() {
    rm -rf "${BAISH_STATE_DIR}"
}

# --- baish_session_append_user_message ---

@test "baish_session_append_user_message appends a message with role user" {
    baish_session_append_user_message "Hello, BAISH!"

    [[ ${#BAISH_SESSION_MESSAGES[@]} -eq 1 ]]

    local msg="${BAISH_SESSION_MESSAGES[0]}"
    local role
    role=$(echo "${msg}" | jq -r '.role')
    local content
    content=$(echo "${msg}" | jq -r '.content')

    [[ "${role}" == "user" ]]
    [[ "${content}" == "Hello, BAISH!" ]]
}

@test "baish_session_append_user_message appends multiple messages in order" {
    baish_session_append_user_message "first"
    baish_session_append_user_message "second"
    baish_session_append_user_message "third"

    [[ ${#BAISH_SESSION_MESSAGES[@]} -eq 3 ]]

    local c1 c2 c3
    c1=$(echo "${BAISH_SESSION_MESSAGES[0]}" | jq -r '.content')
    c2=$(echo "${BAISH_SESSION_MESSAGES[1]}" | jq -r '.content')
    c3=$(echo "${BAISH_SESSION_MESSAGES[2]}" | jq -r '.content')

    [[ "${c1}" == "first" ]]
    [[ "${c2}" == "second" ]]
    [[ "${c3}" == "third" ]]
}

@test "baish_session_append_user_message handles empty text" {
    baish_session_append_user_message ""

    [[ ${#BAISH_SESSION_MESSAGES[@]} -eq 1 ]]

    local content
    content=$(echo "${BAISH_SESSION_MESSAGES[0]}" | jq -r '.content')
    [[ "${content}" == "" ]]
}

# --- baish_session_append_assistant_response ---

@test "baish_session_append_assistant_response appends a message with role assistant" {
    baish_session_append_assistant_response "I am BAISH." '[]'

    [[ ${#BAISH_SESSION_MESSAGES[@]} -eq 1 ]]

    local msg="${BAISH_SESSION_MESSAGES[0]}"
    local role
    role=$(echo "${msg}" | jq -r '.role')
    local content
    content=$(echo "${msg}" | jq -r '.content')

    [[ "${role}" == "assistant" ]]
    [[ "${content}" == "I am BAISH." ]]
}

@test "baish_session_append_assistant_response handles empty tool_calls gracefully" {
    baish_session_append_assistant_response "No tools needed." '[]'

    local tc
    tc=$(echo "${BAISH_SESSION_MESSAGES[0]}" | jq -c '.tool_calls')
    [[ "${tc}" == "[]" ]]
}

@test "baish_session_append_assistant_response handles null tool_calls" {
    baish_session_append_assistant_response "No tools." 'null'

    local tc
    tc=$(echo "${BAISH_SESSION_MESSAGES[0]}" | jq -c '.tool_calls')
    [[ "${tc}" == "[]" ]]
}

@test "baish_session_append_assistant_response normalizes tool_calls to OpenAI format" {
    local tc_json='[{"id":"call_1","name":"read","arguments":"{\"path\":\"/tmp/test\"}"}]'
    baish_session_append_assistant_response "Using tools." "${tc_json}"

    local msg="${BAISH_SESSION_MESSAGES[0]}"

    # Verify the normalized structure has the function envelope
    local type
    type=$(echo "${msg}" | jq -r '.tool_calls[0].type')
    local fn_name
    fn_name=$(echo "${msg}" | jq -r '.tool_calls[0].function.name')
    local fn_args
    fn_args=$(echo "${msg}" | jq -r '.tool_calls[0].function.arguments')
    local tc_id
    tc_id=$(echo "${msg}" | jq -r '.tool_calls[0].id')

    [[ "${type}" == "function" ]]
    [[ "${fn_name}" == "read" ]]
    [[ "${fn_args}" == '{"path":"/tmp/test"}' ]]
    [[ "${tc_id}" == "call_1" ]]
}

@test "baish_session_append_assistant_response is idempotent for already-wrapped tool_calls" {
    # Simulate tool_calls that already have the function envelope
    local tc_json='[{"id":"call_1","type":"function","function":{"name":"read","arguments":"{}"}}]'
    baish_session_append_assistant_response "Already wrapped." "${tc_json}"

    local type
    type=$(echo "${BAISH_SESSION_MESSAGES[0]}" | jq -r '.tool_calls[0].type')
    local fn_name
    fn_name=$(echo "${BAISH_SESSION_MESSAGES[0]}" | jq -r '.tool_calls[0].function.name')

    [[ "${type}" == "function" ]]
    [[ "${fn_name}" == "read" ]]
}

@test "baish_session_append_assistant_response handles multiple tool calls" {
    local tc_json='[
        {"id":"tc1","name":"read","arguments":"{\"path\":\"a.txt\"}"},
        {"id":"tc2","name":"write","arguments":"{\"path\":\"b.txt\"}"}
    ]'
    baish_session_append_assistant_response "Multiple tools." "${tc_json}"

    local count
    count=$(echo "${BAISH_SESSION_MESSAGES[0]}" | jq '.tool_calls | length')
    [[ "${count}" -eq 2 ]]

    local name1 name2
    name1=$(echo "${BAISH_SESSION_MESSAGES[0]}" | jq -r '.tool_calls[0].function.name')
    name2=$(echo "${BAISH_SESSION_MESSAGES[0]}" | jq -r '.tool_calls[1].function.name')
    [[ "${name1}" == "read" ]]
    [[ "${name2}" == "write" ]]
}

# --- baish_session_append_tool_result ---

@test "baish_session_append_tool_result appends a message with role tool" {
    baish_session_append_tool_result "call_1" '{"ok":true}'

    [[ ${#BAISH_SESSION_MESSAGES[@]} -eq 1 ]]

    local msg="${BAISH_SESSION_MESSAGES[0]}"
    local role
    role=$(echo "${msg}" | jq -r '.role')
    local tool_call_id
    tool_call_id=$(echo "${msg}" | jq -r '.tool_call_id')

    [[ "${role}" == "tool" ]]
    [[ "${tool_call_id}" == "call_1" ]]
}

@test "baish_session_append_tool_result encodes result JSON as a string content field" {
    baish_session_append_tool_result "call_1" '{"ok":true,"data":"some content"}'

    local content
    content=$(echo "${BAISH_SESSION_MESSAGES[0]}" | jq -r '.content')
    local expected='{"ok":true,"data":"some content"}'
    [[ "${content}" == "${expected}" ]]
}

@test "baish_session_append_tool_result handles empty result JSON" {
    baish_session_append_tool_result "call_2" '{}'

    local content
    content=$(echo "${BAISH_SESSION_MESSAGES[0]}" | jq -r '.content')
    [[ "${content}" == "{}" ]]
}

@test "baish_session_append_tool_result preserves tool_call_id" {
    baish_session_append_tool_result "my-tool-call-id-42" '{"ok":true}'

    local tid
    tid=$(echo "${BAISH_SESSION_MESSAGES[0]}" | jq -r '.tool_call_id')
    [[ "${tid}" == "my-tool-call-id-42" ]]
}

# --- baish_session_reset_context_window ---

@test "baish_session_reset_context_window clears message history" {
    baish_session_append_user_message "Hello"
    baish_session_append_assistant_response "Hi" '[]'
    [[ ${#BAISH_SESSION_MESSAGES[@]} -eq 2 ]]

    baish_session_reset_context_window

    [[ ${#BAISH_SESSION_MESSAGES[@]} -eq 0 ]]
}

@test "baish_session_reset_context_window resets tool rounds" {
    BAISH_SESSION_TOOL_ROUNDS=5
    baish_session_reset_context_window

    [[ ${BAISH_SESSION_TOOL_ROUNDS} -eq 0 ]]
}

@test "baish_session_reset_context_window keeps provider and model, clears skills" {
    BAISH_CURRENT_PROVIDER="copilot"
    BAISH_CURRENT_MODEL="gpt-4"
    BAISH_SESSION_SKILL_NAMES=("my-skill")
    BAISH_SESSION_SKILL_CONTENTS=("You are skilled.")

    baish_session_reset_context_window

    [[ "${BAISH_CURRENT_PROVIDER}" == "copilot" ]]
    [[ "${BAISH_CURRENT_MODEL}" == "gpt-4" ]]
    [[ "${#BAISH_SESSION_SKILL_NAMES[@]}" -eq 0 ]]
    [[ "${#BAISH_SESSION_SKILL_CONTENTS[@]}" -eq 0 ]]
}

@test "baish_session_reset_context_window handles empty session gracefully" {
    baish_session_reset_context_window

    [[ ${#BAISH_SESSION_MESSAGES[@]} -eq 0 ]]
    [[ ${BAISH_SESSION_TOOL_ROUNDS} -eq 0 ]]
}

# --- baish_session_build_request ---

@test "baish_session_build_request builds a valid JSON payload with system message" {
    local result
    result=$(baish_session_build_request '[]')

    # Should be valid JSON with messages and tools keys
    local messages
    messages=$(echo "${result}" | jq -c '.messages')
    local tools
    tools=$(echo "${result}" | jq -c '.tools')

    [[ -n "${messages}" ]]
    [[ -n "${tools}" ]]

    # First message should be system
    local first_role
    first_role=$(echo "${result}" | jq -r '.messages[0].role')
    [[ "${first_role}" == "system" ]]
}

@test "baish_session_build_request includes conversation messages" {
    baish_session_append_user_message "Hello"
    baish_session_append_assistant_response "Hi there" '[]'

    local result
    result=$(baish_session_build_request '[]')

    local msg_count
    msg_count=$(echo "${result}" | jq '.messages | length')
    # 1 system + 2 conversation = 3
    [[ "${msg_count}" -eq 3 ]]

    local roles
    roles=$(echo "${result}" | jq -r '.messages[].role' | tr '\n' ' ')
    [[ "${roles}" == "system user assistant " ]]
}

@test "baish_session_build_request includes the tools key when tools_json is non-empty" {
    local tools_json='[{"type":"function","function":{"name":"read","description":"Read a file"}}]'
    local result
    result=$(baish_session_build_request "${tools_json}")

    local has_tools
    has_tools=$(echo "${result}" | jq 'has("tools")')
    [[ "${has_tools}" == "true" ]]

    local tool_count
    tool_count=$(echo "${result}" | jq '.tools | length')
    [[ "${tool_count}" -eq 1 ]]
}

@test "baish_session_build_request omits tools key when tools_json is empty array" {
    local result
    result=$(baish_session_build_request '[]')

    # tools is present but empty (we always pass tools in the JSON)
    local tools
    tools=$(echo "${result}" | jq -c '.tools')
    [[ "${tools}" == "[]" ]]
}

@test "baish_session_build_request includes skill system messages when skills are loaded" {
    BAISH_SESSION_SKILL_NAMES=("helper")
    BAISH_SESSION_SKILL_CONTENTS=("You are a helpful assistant.")

    local result
    result=$(baish_session_build_request '[]')

    # messages: system + skill system = 2
    local msg_count
    msg_count=$(echo "${result}" | jq '.messages | length')
    [[ "${msg_count}" -eq 2 ]]

    local roles
    roles=$(echo "${result}" | jq -r '.messages[].role' | tr '\n' ' ')
    [[ "${roles}" == "system system " ]]
}

@test "baish_session_build_request includes multiple skill messages in order" {
    BAISH_SESSION_SKILL_NAMES=("skill-a" "skill-b")
    BAISH_SESSION_SKILL_CONTENTS=("First skill." "Second skill.")

    local result
    result=$(baish_session_build_request '[]')

    local content1 content2
    content1=$(echo "${result}" | jq -r '.messages[1].content')
    content2=$(echo "${result}" | jq -r '.messages[2].content')

    [[ "${content1}" == "First skill." ]]
    [[ "${content2}" == "Second skill." ]]
}

@test "baish_session_build_request uses custom BAISH_SYSTEM_PROMPT when set" {
    BAISH_SYSTEM_PROMPT="Custom system prompt."
    export BAISH_SYSTEM_PROMPT

    local result
    result=$(baish_session_build_request '[]')

    local sys_content
    sys_content=$(echo "${result}" | jq -r '.messages[0].content')
    [[ "${sys_content}" == "Custom system prompt." ]]
}

@test "baish_session_build_request honors message order: system, skills, conversation" {
    BAISH_SESSION_SKILL_NAMES=("skill-x")
    BAISH_SESSION_SKILL_CONTENTS=("Skill content.")
    baish_session_append_user_message "Hello"
    baish_session_append_assistant_response "World" '[]'

    local result
    result=$(baish_session_build_request '[]')

    local roles
    roles=$(echo "${result}" | jq -r '.messages[].role' | tr '\n' ' ')
    [[ "${roles}" == "system system user assistant " ]]

    local contents
    contents=$(echo "${result}" | jq -r '.messages[].content')
    [[ "${contents}" == *"Skill content."* ]]
    [[ "${contents}" == *"Hello"* ]]
    [[ "${contents}" == *"World"* ]]
}

# --- Integration: round-trip append + build_request ---

@test "round-trip: append user, assistant, tool_result then build_request" {
    baish_session_append_user_message "Read file /tmp/test.txt"
    baish_session_append_assistant_response \
        "I'll read the file." \
        '[{"id":"tc1","name":"read","arguments":"{\"path\":\"/tmp/test.txt\"}"}]'
    baish_session_append_tool_result "tc1" '{"ok":true,"content":"file contents"}'

    local result
    result=$(baish_session_build_request '[]')

    local msg_count
    msg_count=$(echo "${result}" | jq '.messages | length')
    # system + user + assistant + tool = 4
    [[ "${msg_count}" -eq 4 ]]

    local roles
    roles=$(echo "${result}" | jq -r '.messages[].role' | tr '\n' ' ')
    [[ "${roles}" == "system user assistant tool " ]]

    # Verify tool result content is a string
    local tool_content
    tool_content=$(echo "${result}" | jq -r '.messages[3].content')
    [[ "${tool_content}" == '{"ok":true,"content":"file contents"}' ]]
}

# --- AGENTS.md loading ---

@test "baish_agents_md_init loads global AGENTS.md" {
    mkdir -p "${HOME}/.baish"
    echo "Global agent instructions" > "${HOME}/.baish/AGENTS.md"

    baish_agents_md_init

    local content
    content=$(baish_agents_md_get_content)
    [[ "${content}" == "Global agent instructions" ]]
}

@test "baish_agents_md_init loads project AGENTS.md" {
    echo "Project agent instructions" > "./AGENTS.md"

    baish_agents_md_init

    local content
    content=$(baish_agents_md_get_content)
    [[ "${content}" == "Project agent instructions" ]]
}

@test "baish_agents_md_init concatenates global then project AGENTS.md" {
    mkdir -p "${HOME}/.baish"
    echo "Global instructions" > "${HOME}/.baish/AGENTS.md"
    echo "Project instructions" > "./AGENTS.md"

    baish_agents_md_init

    local content
    content=$(baish_agents_md_get_content)
    [[ "${content}" == *"Global instructions"* ]]
    [[ "${content}" == *"Project instructions"* ]]
    # Global should come before project
    [[ "$(echo "${content}" | head -1)" == "Global instructions" ]]
}

@test "baish_agents_md_init skips missing global AGENTS.md silently" {
    rm -f "${HOME}/.baish/AGENTS.md"
    echo "Project only" > "./AGENTS.md"

    baish_agents_md_init

    local content
    content=$(baish_agents_md_get_content)
    [[ "${content}" == "Project only" ]]
}

@test "baish_agents_md_init skips missing project AGENTS.md silently" {
    mkdir -p "${HOME}/.baish"
    echo "Global only" > "${HOME}/.baish/AGENTS.md"
    rm -f "./AGENTS.md"

    baish_agents_md_init

    local content
    content=$(baish_agents_md_get_content)
    [[ "${content}" == "Global only" ]]
}

@test "baish_agents_md_init returns empty when neither file exists" {
    rm -f "${HOME}/.baish/AGENTS.md"
    rm -f "./AGENTS.md"

    baish_agents_md_init

    local content
    content=$(baish_agents_md_get_content)
    [[ -z "${content}" ]]
}

@test "baish_agents_md_init skips empty files silently" {
    mkdir -p "${HOME}/.baish"
    touch "${HOME}/.baish/AGENTS.md"
    touch "./AGENTS.md"

    baish_agents_md_init

    local content
    content=$(baish_agents_md_get_content)
    [[ -z "${content}" ]]
}

# --- ARG_MAX regression (Argument list too long) ---

@test "baish_session_build_request handles large sessions without ARG_MAX overflow" {
    # 50 rounds of user→assistant+tool_call→large_tool_result
    local chunk
    chunk=$(python3 -c "print('x' * 40000)" 2>/dev/null || yes x | head -c 40000 | tr -d '\n')

    for (( i = 1; i <= 50; i++ )); do
        baish_session_append_user_message "Read file /tmp/test${i}.txt"
        baish_session_append_assistant_response \
            "Here is file ${i}." \
            "[{\"id\":\"call_${i}\",\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"/tmp/test${i}.txt\\\"}\"}]"
        local tool_result
        tool_result=$(jq -n --arg content "${chunk}" '{"ok":true,"data":{"stdout":$content}}')
        baish_session_append_tool_result "call_${i}" "${tool_result}"
    done

    run baish_session_build_request '[]'

    [[ "${status}" -eq 0 ]]
    # Verify valid JSON and correct message count: 1 system + 50*(user+assistant+tool) = 151
    local msg_count
    msg_count=$(echo "${output}" | jq '.messages | length')
    [[ "${msg_count}" -eq 151 ]]
}

@test "AGENTS.md content injected as user message between skills and conversation" {
    mkdir -p "${HOME}/.baish"
    echo "Always follow best practices." > "${HOME}/.baish/AGENTS.md"

    # Re-init to load the new file
    baish_agents_md_init

    BAISH_SESSION_SKILL_NAMES=("helper")
    BAISH_SESSION_SKILL_CONTENTS=("You are a helpful assistant.")
    baish_session_append_user_message "Hello"
    baish_session_append_assistant_response "Hi" '[]'

    local result
    result=$(baish_session_build_request '[]')

    local roles
    roles=$(echo "${result}" | jq -r '.messages[].role' | tr '\n' ' ')
    # Order: system, skill(system), agents_md(user), conversation(user), conversation(assistant)
    [[ "${roles}" == "system system user user assistant " ]]

    # The AGENTS.md user message should be between skills and conversation
    local agents_role
    agents_role=$(echo "${result}" | jq -r '.messages[2].role')
    [[ "${agents_role}" == "user" ]]
    local agents_content
    agents_content=$(echo "${result}" | jq -r '.messages[2].content')
    [[ "${agents_content}" == "Always follow best practices." ]]
}
