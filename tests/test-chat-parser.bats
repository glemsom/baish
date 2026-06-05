#!/usr/bin/env bats
# BAISH — Tests: Shared Provider Chat Response Parser

setup() {
    BAISH_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
    export BAISH_ROOT
    source "${BAISH_ROOT}/lib/providers/chat-parser.sh"
}

# --- baish_provider_build_chat_payload ---

@test "build_chat_payload includes model, messages, and tools when tools provided" {
    local messages='[{"role":"user","content":"hello"}]'
    local tools='[{"type":"function","function":{"name":"read","parameters":{}}}]'

    local payload
    payload=$(baish_provider_build_chat_payload "gpt-4o" "${messages}" "${tools}")

    local model has_messages has_tools
    model=$(echo "${payload}" | jq -r '.model')
    has_messages=$(echo "${payload}" | jq 'has("messages")')
    has_tools=$(echo "${payload}" | jq 'has("tools")')

    [[ "${model}" == "gpt-4o" ]]
    [[ "${has_messages}" == "true" ]]
    [[ "${has_tools}" == "true" ]]
}

@test "build_chat_payload omits tools key when tools is empty array" {
    local messages='[{"role":"user","content":"hello"}]'
    local tools='[]'

    local payload
    payload=$(baish_provider_build_chat_payload "gpt-4o" "${messages}" "${tools}")

    local has_tools
    has_tools=$(echo "${payload}" | jq 'has("tools")')
    [[ "${has_tools}" == "false" ]]
}

@test "build_chat_payload omits tools key when tools is null" {
    local messages='[{"role":"user","content":"hello"}]'
    local tools='null'

    local payload
    payload=$(baish_provider_build_chat_payload "gpt-4o" "${messages}" "${tools}")

    local has_tools
    has_tools=$(echo "${payload}" | jq 'has("tools")')
    [[ "${has_tools}" == "false" ]]
}

@test "build_chat_payload includes stream:false" {
    local messages='[{"role":"user","content":"hello"}]'
    local tools='[]'

    local payload
    payload=$(baish_provider_build_chat_payload "gpt-4o" "${messages}" "${tools}")

    local stream
    stream=$(echo "${payload}" | jq -r '.stream')
    [[ "${stream}" == "false" ]]
}

@test "build_chat_payload includes parallel_tool_calls:false when tools present" {
    local messages='[{"role":"user","content":"hello"}]'
    local tools='[{"type":"function","function":{"name":"read","parameters":{}}}]'

    local payload
    payload=$(baish_provider_build_chat_payload "gpt-4o" "${messages}" "${tools}")

    local parallel
    parallel=$(echo "${payload}" | jq -r '.parallel_tool_calls')
    [[ "${parallel}" == "false" ]]
}

@test "build_chat_payload messages are passed through correctly" {
    local messages='[{"role":"user","content":"hello"},{"role":"assistant","content":"hi"}]'
    local tools='[]'

    local payload
    payload=$(baish_provider_build_chat_payload "gpt-4o" "${messages}" "${tools}")

    local msg_count first_role
    msg_count=$(echo "${payload}" | jq '.messages | length')
    first_role=$(echo "${payload}" | jq -r '.messages[0].role')

    [[ "${msg_count}" == "2" ]]
    [[ "${first_role}" == "user" ]]
}

# --- baish_provider_parse_error_body ---

@test "parse_error_body returns empty string for HTTP 200" {
    local body='{"choices":[{"message":{"content":"ok"}}]}'

    local result
    result=$(baish_provider_parse_error_body "200" "${body}" '.error.message // .message // "Unknown error"' "AUTH_FAILURE" "")

    [[ -z "${result}" ]]
}

@test "parse_error_body detects CONTEXT_OVERFLOW via context_length_exceeded" {
    local body='{"error":{"message":"context_length_exceeded: this model max context length is 8192 tokens"}}'

    local result
    result=$(baish_provider_parse_error_body "400" "${body}" '.error.message // .message // "Unknown error"' "AUTH_FAILURE" "")

    local ok error_code
    ok=$(echo "${result}" | jq -r '.ok')
    error_code=$(echo "${result}" | jq -r '.error.code')

    [[ "${ok}" == "false" ]]
    [[ "${error_code}" == "CONTEXT_OVERFLOW" ]]
}

@test "parse_error_body detects CONTEXT_OVERFLOW via 'too long'" {
    local body='{"error":{"message":"input is too long"}}'

    local result
    result=$(baish_provider_parse_error_body "400" "${body}" '.error.message // .message // "Unknown error"' "AUTH_FAILURE" "")

    local error_code
    error_code=$(echo "${result}" | jq -r '.error.code')

    [[ "${error_code}" == "CONTEXT_OVERFLOW" ]]
}

@test "parse_error_body returns TOKEN_EXPIRED for 401 with auth_error_code" {
    local body='{"error":{"message":"token expired"}}'

    local result
    result=$(baish_provider_parse_error_body "401" "${body}" '.error.message // .message // "Unknown error"' "TOKEN_EXPIRED" "")

    local ok error_code
    ok=$(echo "${result}" | jq -r '.ok')
    error_code=$(echo "${result}" | jq -r '.error.code')

    [[ "${ok}" == "false" ]]
    [[ "${error_code}" == "TOKEN_EXPIRED" ]]
}

@test "parse_error_body returns AUTH_FAILURE for 401 with auth_error_code" {
    local body='{"error":{"message":"invalid key"}}'

    local result
    result=$(baish_provider_parse_error_body "401" "${body}" '.error.message // .message // "Unknown error"' "AUTH_FAILURE" "")

    local error_code
    error_code=$(echo "${result}" | jq -r '.error.code')

    [[ "${error_code}" == "AUTH_FAILURE" ]]
}

@test "parse_error_body returns AUTH_FAILURE for 403" {
    local body='{"error":{"message":"forbidden"}}'

    local result
    result=$(baish_provider_parse_error_body "403" "${body}" '.error.message // .message // "Unknown error"' "AUTH_FAILURE" "")

    local error_code
    error_code=$(echo "${result}" | jq -r '.error.code')

    [[ "${error_code}" == "AUTH_FAILURE" ]]
}

@test "parse_error_body returns GENERIC_ERROR for 500" {
    local body='{"error":{"message":"internal error"}}'

    local result
    result=$(baish_provider_parse_error_body "500" "${body}" '.error.message // .message // "Unknown error"' "AUTH_FAILURE" "")

    local error_code error_message
    error_code=$(echo "${result}" | jq -r '.error.code')
    error_message=$(echo "${result}" | jq -r '.error.message')

    [[ "${error_code}" == "GENERIC_ERROR" ]]
    [[ "${error_message}" == *"500"* ]]
    [[ "${error_message}" == *"internal error"* ]]
}

@test "parse_error_body prepends provider_prefix to generic error message" {
    local body='{"error":{"message":"server error"}}'

    local result
    result=$(baish_provider_parse_error_body "500" "${body}" '.error.message // .message // "Unknown error"' "AUTH_FAILURE" "Kilo: ")

    local error_message
    error_message=$(echo "${result}" | jq -r '.error.message')

    [[ "${error_message}" == "Kilo: "* ]]
}

@test "parse_error_body uses custom error_msg_jq for Responses API format" {
    local body='{"message":"context_length_exceeded: input too long"}'

    local result
    result=$(baish_provider_parse_error_body "400" "${body}" '.message // .error // "Unknown error"' "TOKEN_EXPIRED" "")

    local error_code error_message
    error_code=$(echo "${result}" | jq -r '.error.code')
    error_message=$(echo "${result}" | jq -r '.error.message')

    [[ "${error_code}" == "CONTEXT_OVERFLOW" ]]
    [[ "${error_message}" == "context_length_exceeded: input too long" ]]
}

@test "parse_error_body returns GENERIC_ERROR for empty body" {
    local body=''

    local result
    result=$(baish_provider_parse_error_body "502" "${body}" '.error.message // .message // "Unknown error"' "AUTH_FAILURE" "")

    local error_code
    error_code=$(echo "${result}" | jq -r '.error.code')

    [[ "${error_code}" == "GENERIC_ERROR" ]]
}

# --- baish_provider_parse_chat_response_body ---

@test "parse_chat_response_body extracts assistant_text from Chat Completions response" {
    local body='{"choices":[{"message":{"content":"Hello, world!","tool_calls":[]}}]}'

    local result
    result=$(baish_provider_parse_chat_response_body "${body}")

    local ok text tc
    ok=$(echo "${result}" | jq -r '.ok')
    text=$(echo "${result}" | jq -r '.assistant_text')
    tc=$(echo "${result}" | jq -c '.tool_calls')

    [[ "${ok}" == "true" ]]
    [[ "${text}" == "Hello, world!" ]]
    [[ "${tc}" == "[]" ]]
}

@test "parse_chat_response_body returns empty tool_calls when none present" {
    local body='{"choices":[{"message":{"content":"no tools"}}]}'

    local result
    result=$(baish_provider_parse_chat_response_body "${body}")

    local tc
    tc=$(echo "${result}" | jq -c '.tool_calls')

    [[ "${tc}" == "[]" ]]
}

@test "parse_chat_response_body normalizes tool_calls from OpenAI format" {
    local body
    body=$(jq -n '{
        choices: [{
            message: {
                content: "I will read the file",
                tool_calls: [{
                    id: "tc-1",
                    type: "function",
                    function: {
                        name: "read",
                        arguments: "{\"path\":\"test.txt\"}"
                    }
                }]
            }
        }]
    }')

    local result
    result=$(baish_provider_parse_chat_response_body "${body}")

    local tc_len tc_name tc_id tc_args
    tc_len=$(echo "${result}" | jq '.tool_calls | length')
    tc_name=$(echo "${result}" | jq -r '.tool_calls[0].name')
    tc_id=$(echo "${result}" | jq -r '.tool_calls[0].id')

    [[ "${tc_len}" == "1" ]]
    [[ "${tc_name}" == "read" ]]
    [[ "${tc_id}" == "tc-1" ]]

    # Verify no "function" wrapper in normalized output
    local has_fn
    has_fn=$(echo "${result}" | jq '.tool_calls[0] | has("function")')
    [[ "${has_fn}" == "false" ]]

    # Arguments should be a raw JSON string
    local args
    args=$(echo "${result}" | jq -r '.tool_calls[0].arguments')
    local parsed_args_path
    parsed_args_path=$(echo "${args}" | jq -r '.path')
    [[ "${parsed_args_path}" == "test.txt" ]]
}

@test "parse_chat_response_body returns empty assistant_text when content is null" {
    local body='{"choices":[{"message":{"content":null,"tool_calls":[]}}]}'

    local result
    result=$(baish_provider_parse_chat_response_body "${body}")

    local text
    text=$(echo "${result}" | jq -r '.assistant_text')

    [[ "${text}" == "" ]]
}
