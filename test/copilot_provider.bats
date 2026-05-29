#!/usr/bin/env bats

load test_helper.bash

setup() {
  REPO_ROOT="$(repo_root)"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  TEST_PROJECT="$BATS_TEST_TMPDIR/project"
  CURL_LOG="$BATS_TEST_TMPDIR/curl-log.jsonl"

  mkdir -p "$TEST_HOME" "$TEST_PROJECT"
  cd "$TEST_PROJECT"

  source "$REPO_ROOT/lib/state.sh"
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/slash.sh"
  source "$REPO_ROOT/lib/providers/copilot.sh"

  HOME="$TEST_HOME"
  PATH="/usr/bin:/bin"
  BAISH_PROVIDER='copilot'
  unset BAISH_MODEL
  unset BAISH_DEBUG
  unset BAISH_ACTIVE_PROVIDER
  unset BAISH_ACTIVE_MODEL
  unset BAISH_COPILOT_SESSION_ID

  : >"$CURL_LOG"

  baish_state_init
  baish_session_reset
}

sleep() {
  :
}

fzf() {
  head -n 1
}

curl() {
  local method='GET'
  local url=''
  local data=''
  local header_file=''
  local body_file=''
  local status='200'
  local body=''
  local status_text='OK'
  local arg

  while (($#)); do
    arg="$1"
    case "$arg" in
      -X)
        method="$2"
        shift 2
        ;;
      -H)
        shift 2
        ;;
      --data|-d|--data-raw|--data-binary)
        data="$2"
        shift 2
        ;;
      -D)
        header_file="$2"
        shift 2
        ;;
      -o)
        body_file="$2"
        shift 2
        ;;
      -s|-S|-sS)
        shift
        ;;
      http://*|https://*)
        url="$1"
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  printf '%s\n' "$(jq -cn --arg method "$method" --arg url "$url" --arg data "$data" '{method: $method, url: $url, data: $data}')" >>"$CURL_LOG"

  case "$method $url" in
    'POST https://github.com/login/device/code')
      body='{"device_code":"device-code-123","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":0}'
      ;;
    'POST https://github.com/login/oauth/access_token')
      body='{"access_token":"gho-test-token","token_type":"bearer","scope":"read:user,read:org,repo,gist"}'
      ;;
    'GET https://api.github.com/user')
      body='{"login":"octocat"}'
      ;;
    'GET https://api.github.com/copilot_internal/v2/token')
      body='{"token":"copilot-access-token","expires_at":4102444800,"refresh_in":900,"sku":"copilot_individual","endpoints":{"api":"https://api.githubcopilot.com"}}'
      ;;
    'GET https://api.githubcopilot.com/models')
      body='[{"id":"gpt-4o","name":"GPT-4o","model_picker_enabled":true},{"id":"claude-sonnet-4","name":"Claude Sonnet 4","model_picker_enabled":true}]'
      ;;
    'POST https://api.githubcopilot.com/chat/completions')
      body='{"choices":[{"message":{"content":null,"tool_calls":[{"id":"call-1","type":"function","function":{"name":"read","arguments":"{\"path\":\"idea.md\",\"offset\":1}"}}]}}]}'
      ;;
    *)
      status='404'
      status_text='Not Found'
      body='{"message":"not found"}'
      ;;
  esac

  if [[ -n "$header_file" ]]; then
    printf 'HTTP/1.1 %s %s\n\n' "$status" "$status_text" >"$header_file"
  fi

  if [[ -n "$body_file" ]]; then
    printf '%s' "$body" >"$body_file"
  else
    printf '%s' "$body"
  fi
}

capture_output() {
  local command="$1"
  local output_file="$BATS_TEST_TMPDIR/output"

  : >"$output_file"
  set +e
  eval "$command" >"$output_file" 2>&1
  CAPTURE_STATUS=$?
  set -e
  CAPTURE_OUTPUT="$(<"$output_file")"
}

@test "copilot auth performs device flow and persists auth state" {
  local auth_file

  capture_output 'provider_copilot_auth'
  auth_file="$TEST_HOME/.baish/auth/copilot.json"

  [ "$CAPTURE_STATUS" -eq 0 ]
  [[ "$CAPTURE_OUTPUT" == *'To connect Copilot, visit https://github.com/login/device and enter code ABCD-EFGH'* ]]
  [[ "$CAPTURE_OUTPUT" == *'Copilot authorization completed for octocat.'* ]]
  [ -f "$auth_file" ]
  [ "$(stat -c '%a' "$auth_file")" = '600' ]
  [ "$(jq -r '.provider' "$auth_file")" = 'copilot' ]
  [ "$(jq -r '.host' "$auth_file")" = 'https://github.com' ]
  [ "$(jq -r '.login' "$auth_file")" = 'octocat' ]
  [ "$(jq -r '.github_token' "$auth_file")" = 'gho-test-token' ]
  [ "$(jq -r '.copilot_token' "$auth_file")" = 'copilot-access-token' ]
  [ "$(jq -r '.endpoints.api' "$auth_file")" = 'https://api.githubcopilot.com' ]
  [ -n "$(jq -r '.machine_id' "$auth_file")" ]
  [ -n "$(jq -r '.device_id' "$auth_file")" ]
}

@test "connect authenticates copilot and persists the selected model" {
  local auth_file state_file

  capture_output 'baish_connect_current_provider'
  auth_file="$TEST_HOME/.baish/auth/copilot.json"
  state_file="$TEST_HOME/.baish/state.json"

  [ "$CAPTURE_STATUS" -eq 0 ]
  [[ "$CAPTURE_OUTPUT" == *'Selected model: gpt-4o'* ]]
  [[ "$CAPTURE_OUTPUT" == *'Connected provider: copilot'* ]]
  [ -f "$auth_file" ]
  [ -f "$state_file" ]
  [ "$(jq -r '.selected_provider' "$state_file")" = 'copilot' ]
  [ "$(jq -r '.selected_model' "$state_file")" = 'gpt-4o' ]
}

@test "copilot chat uses OpenAI-style tool payloads and normalizes tool calls" {
  local auth_json request_json response_json payload_json

  auth_json='{"provider":"copilot","host":"https://github.com","github_token":"gho-test-token","copilot_token":"copilot-access-token","copilot_token_expires_at":4102444800,"machine_id":"machine-1","device_id":"device-1","endpoints":{"api":"https://api.githubcopilot.com"}}'
  baish_state_write_auth_json 'copilot' "$auth_json"

  request_json='{
    "model":"gpt-4o",
    "system_prompt":"You are BAISH.",
    "tool_use_instructions":"Use tools structurally.",
    "skills":[{"name":"tdd","content":"Write tests first."}],
    "tools":[{"name":"read","description":"Read a file.","input_schema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}}],
    "messages":[{"role":"user","content":"Inspect idea.md"}]
  }'

  response_json="$(provider_copilot_chat "$request_json")"
  payload_json="$(jq -r 'select(.url == "https://api.githubcopilot.com/chat/completions") | .data' "$CURL_LOG")"

  [ "$(jq -r '.assistant_text' <<<"$response_json")" = 'null' ]
  [ "$(jq -r '.tool_calls | length' <<<"$response_json")" = '1' ]
  [ "$(jq -r '.tool_calls[0].id' <<<"$response_json")" = 'call-1' ]
  [ "$(jq -r '.tool_calls[0].name' <<<"$response_json")" = 'read' ]
  [ "$(jq -r '.tool_calls[0].arguments.path' <<<"$response_json")" = 'idea.md' ]
  [ "$(jq -r '.tool_calls[0].arguments.offset' <<<"$response_json")" = '1' ]

  [ "$(jq -r '.stream' <<<"$payload_json")" = 'false' ]
  [ "$(jq -r '.parallel_tool_calls' <<<"$payload_json")" = 'true' ]
  [ "$(jq -r '.tool_choice' <<<"$payload_json")" = 'auto' ]
  [ "$(jq -r '.tools[0].type' <<<"$payload_json")" = 'function' ]
  [ "$(jq -r '.tools[0].function.name' <<<"$payload_json")" = 'read' ]
  [ "$(jq -r '.messages[0].role' <<<"$payload_json")" = 'system' ]
  [ "$(jq -r '.messages[1].role' <<<"$payload_json")" = 'system' ]
  [ "$(jq -r '.messages[2].content' <<<"$payload_json")" = $'Loaded skill: tdd\nWrite tests first.' ]
  [ "$(jq -r '.messages[3].role' <<<"$payload_json")" = 'user' ]
}
