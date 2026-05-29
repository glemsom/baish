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
  unset COPILOT_GITHUB_TOKEN
  unset GH_TOKEN
  unset GITHUB_TOKEN

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
  local headers_json='[]'
  local arg
  local -a headers=()

  while (($#)); do
    arg="$1"
    case "$arg" in
      -X)
        method="$2"
        shift 2
        ;;
      -H)
        headers+=("$2")
        shift 2
        ;;
      --data|-d|--data-raw|--data-binary)
        data="$2"
        if [[ "$data" == '@-' ]]; then
          data="$(cat)"
        fi
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

  if ((${#headers[@]} > 0)); then
    headers_json="$(printf '%s\n' "${headers[@]}" | jq -R . | jq -s .)"
  fi

  printf '%s\n' "$(jq -cn --arg method "$method" --arg url "$url" --arg data "$data" --argjson headers "$headers_json" '{method: $method, url: $url, data: $data, headers: $headers}')" >>"$CURL_LOG"

  case "$method $url" in
    'POST https://github.com/login/device/code')
      body='{"device_code":"device-code-123","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":0}'
      ;;
    'POST https://github.com/login/oauth/access_token')
      body='{"access_token":"gho-test-token","token_type":"bearer","scope":"read:user"}'
      ;;
    'GET https://api.github.com/user')
      body='{"login":"octocat"}'
      ;;
    'GET https://api.github.com/copilot_internal/v2/token')
      body='{"token":"tid=test;exp=4102444800;proxy-ep=proxy.individual.githubcopilot.com;","expires_at":4102444800,"refresh_in":900,"sku":"copilot_individual"}'
      ;;
    'GET https://api.individual.githubcopilot.com/models')
      body='[{"id":"gpt-4o","name":"GPT-4o","model_picker_enabled":true},{"id":"gpt-5.4","name":"GPT-5.4","model_picker_enabled":true},{"id":"claude-sonnet-4.6","name":"Claude Sonnet 4.6","model_picker_enabled":true}]'
      ;;
    'POST https://api.individual.githubcopilot.com/chat/completions')
      body='{"choices":[{"message":{"content":null,"tool_calls":[{"id":"call-1","type":"function","function":{"name":"read","arguments":"{\"path\":\"idea.md\",\"offset\":1}"}}]}}]}'
      ;;
    'POST https://api.individual.githubcopilot.com/responses')
      body='{"output":[{"type":"function_call","call_id":"call-5","name":"read","arguments":"{\"path\":\"gpt5.md\"}"}]}'
      ;;
    'POST https://api.individual.githubcopilot.com/v1/messages')
      body='{"content":[{"type":"text","text":"Claude says hi."},{"type":"tool_use","id":"call-claude","name":"read","input":{"path":"claude.md"}}]}'
      ;;
    POST\ https://api.individual.githubcopilot.com/models/*/policy)
      body='{"state":"enabled"}'
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

@test "copilot default host honors env overrides" {
  BAISH_COPILOT_HOST='ghe.example.com'
  [ "$(provider_copilot_default_host)" = 'https://ghe.example.com' ]

  unset BAISH_COPILOT_HOST
  COPILOT_GH_HOST='copilot.example.com'
  [ "$(provider_copilot_default_host)" = 'https://copilot.example.com' ]

  unset COPILOT_GH_HOST
  GH_HOST='gh.example.com'
  [ "$(provider_copilot_default_host)" = 'https://gh.example.com' ]

  unset GH_HOST
  [ "$(provider_copilot_default_host)" = 'https://github.com' ]
}

@test "copilot env token helpers prefer COPILOT_GITHUB_TOKEN then GH_TOKEN then GITHUB_TOKEN" {
  run provider_copilot_has_env_token
  [ "$status" -ne 0 ]

  GITHUB_TOKEN='github-token'
  [ "$(provider_copilot_env_token_name)" = 'GITHUB_TOKEN' ]
  [ "$(provider_copilot_env_token_value)" = 'github-token' ]

  GH_TOKEN='gh-token'
  [ "$(provider_copilot_env_token_name)" = 'GH_TOKEN' ]
  [ "$(provider_copilot_env_token_value)" = 'gh-token' ]

  COPILOT_GITHUB_TOKEN='copilot-github-token'
  [ "$(provider_copilot_env_token_name)" = 'COPILOT_GITHUB_TOKEN' ]
  [ "$(provider_copilot_env_token_value)" = 'copilot-github-token' ]

  provider_copilot_has_env_token
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
  [ "$(jq -r '.copilot_token' "$auth_file")" = 'tid=test;exp=4102444800;proxy-ep=proxy.individual.githubcopilot.com;' ]
  [ "$(jq -r '.api_base' "$auth_file")" = 'https://api.individual.githubcopilot.com' ]
  [ -n "$(jq -r '.machine_id' "$auth_file")" ]
  [ -n "$(jq -r '.device_id' "$auth_file")" ]
}

@test "copilot refresh explains 404 failures" {
  local auth_json

  auth_json='{"provider":"copilot","host":"https://ghe.example.com","github_token":"gho-test-token"}'

  capture_output 'provider_copilot_refresh_auth_json "$auth_json"'

  [ "$CAPTURE_STATUS" -ne 0 ]
  [[ "$CAPTURE_OUTPUT" == *'BAISH Copilot token refresh failed (HTTP 404): not found'* ]]
  [[ "$CAPTURE_OUTPUT" == *'The Copilot token endpoint was not found for https://ghe.example.com.'* ]]
  [[ "$CAPTURE_OUTPUT" == *'This usually means the GitHub account does not have Copilot access on that host, or the wrong GitHub host is configured.'* ]]
}

@test "copilot github user call stays minimal and token exchange uses copilot client headers" {
  local auth_json user_headers token_headers

  auth_json='{"provider":"copilot","host":"https://github.com","github_token":"gho-test-token","machine_id":"machine-1","device_id":"device-1"}'

  [ "$(provider_copilot_fetch_login 'https://github.com' 'gho-test-token')" = 'octocat' ]
  provider_copilot_refresh_auth_json "$auth_json" >/dev/null

  user_headers="$(jq -c 'select(.url == "https://api.github.com/user") | .headers' "$CURL_LOG")"
  token_headers="$(jq -c 'select(.url == "https://api.github.com/copilot_internal/v2/token") | .headers' "$CURL_LOG")"

  [[ "$user_headers" == *'Accept: application/json'* ]]
  [[ "$user_headers" == *'Authorization: Bearer gho-test-token'* ]]
  [[ "$user_headers" == *'User-Agent: GitHubCopilotChat/0.35.0'* ]]
  [[ "$user_headers" != *'Editor-Version:'* ]]
  [[ "$user_headers" != *'Copilot-Integration-Id:'* ]]

  [[ "$token_headers" == *'Accept: application/json'* ]]
  [[ "$token_headers" == *'Authorization: Bearer gho-test-token'* ]]
  [[ "$token_headers" == *'User-Agent: GitHubCopilotChat/0.35.0'* ]]
  [[ "$token_headers" == *'Editor-Version: vscode/1.107.0'* ]]
  [[ "$token_headers" == *'Editor-Plugin-Version: copilot-chat/0.35.0'* ]]
  [[ "$token_headers" == *'Copilot-Integration-Id: vscode-chat'* ]]
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

@test "connect uses env github token auth but still exchanges for a copilot token" {
  local auth_file state_file user_headers token_headers model_headers

  COPILOT_GITHUB_TOKEN='ghu-env-token'

  capture_output 'baish_connect_current_provider'
  auth_file="$TEST_HOME/.baish/auth/copilot.json"
  state_file="$TEST_HOME/.baish/state.json"
  user_headers="$(jq -c 'select(.url == "https://api.github.com/user") | .headers' "$CURL_LOG")"
  token_headers="$(jq -c 'select(.url == "https://api.github.com/copilot_internal/v2/token") | .headers' "$CURL_LOG")"
  model_headers="$(jq -c 'select(.url == "https://api.individual.githubcopilot.com/models") | .headers' "$CURL_LOG")"

  [ "$CAPTURE_STATUS" -eq 0 ]
  [[ "$CAPTURE_OUTPUT" == *'Using Copilot GitHub token from COPILOT_GITHUB_TOKEN.'* ]]
  [[ "$CAPTURE_OUTPUT" == *'Copilot authorization completed for octocat.'* ]]
  [[ "$CAPTURE_OUTPUT" == *'Selected model: gpt-4o'* ]]
  [[ "$CAPTURE_OUTPUT" != *'To connect Copilot, visit '* ]]
  [ -f "$auth_file" ]
  [ -f "$state_file" ]
  [ "$(jq -r '.auth_source' "$auth_file")" = 'env' ]
  [ "$(jq -r '.auth_env_var' "$auth_file")" = 'COPILOT_GITHUB_TOKEN' ]
  [ "$(jq -r '.host' "$auth_file")" = 'https://github.com' ]
  [ "$(jq -r '.login' "$auth_file")" = 'octocat' ]
  [ "$(jq -r '.github_token // empty' "$auth_file")" = '' ]
  [ "$(jq -r '.copilot_token // empty' "$auth_file")" = '' ]
  [ "$(jq -r '.api_base' "$auth_file")" = 'https://api.individual.githubcopilot.com' ]
  [ "$(jq -r '.selected_provider' "$state_file")" = 'copilot' ]
  [ "$(jq -r '.selected_model' "$state_file")" = 'gpt-4o' ]
  [[ "$user_headers" == *'Authorization: Bearer ghu-env-token'* ]]
  [[ "$token_headers" == *'Authorization: Bearer ghu-env-token'* ]]
  [[ "$model_headers" == *'Authorization: Bearer tid=test;exp=4102444800;proxy-ep=proxy.individual.githubcopilot.com;'* ]]
}

@test "copilot list models exchanges env github token before calling the runtime api" {
  local models_json model_headers token_headers

  GH_TOKEN='github-env-token'
  models_json="$(provider_copilot_list_models)"
  token_headers="$(jq -c 'select(.url == "https://api.github.com/copilot_internal/v2/token") | .headers' "$CURL_LOG")"
  model_headers="$(jq -c 'select(.url == "https://api.individual.githubcopilot.com/models") | .headers' "$CURL_LOG")"

  [ "$(jq -r 'length' <<<"$models_json")" = '3' ]
  [ "$(jq -r '.[0].id' <<<"$models_json")" = 'gpt-4o' ]
  [[ "$token_headers" == *'Authorization: Bearer github-env-token'* ]]
  [[ "$model_headers" == *'Authorization: Bearer tid=test;exp=4102444800;proxy-ep=proxy.individual.githubcopilot.com;'* ]]
}

@test "copilot chat uses chat-completions payloads and normalizes tool calls" {
  local auth_json request_json response_json payload_json chat_headers policy_request

  auth_json='{"provider":"copilot","host":"https://github.com","github_token":"gho-test-token","copilot_token":"tid=test;exp=4102444800;proxy-ep=proxy.individual.githubcopilot.com;","copilot_token_expires_at":4102444800,"api_base":"https://api.individual.githubcopilot.com","machine_id":"machine-1","device_id":"device-1"}'
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
  payload_json="$(jq -r 'select(.url == "https://api.individual.githubcopilot.com/chat/completions") | .data' "$CURL_LOG")"
  chat_headers="$(jq -c 'select(.url == "https://api.individual.githubcopilot.com/chat/completions") | .headers' "$CURL_LOG")"
  policy_request="$(jq -c 'select(.url == "https://api.individual.githubcopilot.com/models/gpt-4o/policy")' "$CURL_LOG")"

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
  [[ "$chat_headers" == *'Authorization: Bearer tid=test;exp=4102444800;proxy-ep=proxy.individual.githubcopilot.com;'* ]]
  [[ "$chat_headers" == *'X-Initiator: user'* ]]
  [[ "$chat_headers" == *'Openai-Intent: conversation-edits'* ]]
  [ -n "$policy_request" ]
}

@test "copilot gpt-5 uses responses api without reasoning by default" {
  local auth_json request_json response_json payload_json response_headers policy_request

  auth_json='{"provider":"copilot","host":"https://github.com","github_token":"gho-test-token","copilot_token":"tid=test;exp=4102444800;proxy-ep=proxy.individual.githubcopilot.com;","copilot_token_expires_at":4102444800,"api_base":"https://api.individual.githubcopilot.com"}'
  baish_state_write_auth_json 'copilot' "$auth_json"

  request_json='{
    "model":"gpt-5.4",
    "system_prompt":"You are BAISH.",
    "tool_use_instructions":"Use tools structurally.",
    "skills":[],
    "tools":[{"name":"read","description":"Read a file.","input_schema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}}],
    "messages":[{"role":"user","content":"Inspect gpt5.md"}]
  }'

  response_json="$(provider_copilot_chat "$request_json")"
  payload_json="$(jq -r 'select(.url == "https://api.individual.githubcopilot.com/responses") | .data' "$CURL_LOG")"
  response_headers="$(jq -c 'select(.url == "https://api.individual.githubcopilot.com/responses") | .headers' "$CURL_LOG")"
  policy_request="$(jq -c 'select(.url == "https://api.individual.githubcopilot.com/models/gpt-5.4/policy")' "$CURL_LOG")"

  [ "$(jq -r '.assistant_text' <<<"$response_json")" = 'null' ]
  [ "$(jq -r '.tool_calls | length' <<<"$response_json")" = '1' ]
  [ "$(jq -r '.tool_calls[0].id' <<<"$response_json")" = 'call-5' ]
  [ "$(jq -r '.tool_calls[0].name' <<<"$response_json")" = 'read' ]
  [ "$(jq -r '.tool_calls[0].arguments.path' <<<"$response_json")" = 'gpt5.md' ]

  [ "$(jq -r '.stream' <<<"$payload_json")" = 'false' ]
  [ "$(jq -r '.store' <<<"$payload_json")" = 'false' ]
  [ "$(jq -r '.parallel_tool_calls' <<<"$payload_json")" = 'true' ]
  [ "$(jq -r '.tools[0].name' <<<"$payload_json")" = 'read' ]
  [ "$(jq -r '.input[0].role' <<<"$payload_json")" = 'system' ]
  [ "$(jq -r '.input[-1].role' <<<"$payload_json")" = 'user' ]
  [ "$(jq -r 'has("reasoning")' <<<"$payload_json")" = 'false' ]
  [[ "$response_headers" == *'X-Initiator: user'* ]]
  [ -n "$policy_request" ]
}

@test "copilot responses payload flattens prior tool calls out of assistant message content" {
  local request_json payload_json

  request_json='{
    "model":"gpt-5.4",
    "system_prompt":"You are BAISH.",
    "tool_use_instructions":"Use tools structurally.",
    "skills":[],
    "tools":[{"name":"read","description":"Read a file.","input_schema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}}],
    "messages":[
      {"role":"user","content":"Inspect CONTEXT.md"},
      {"role":"assistant","content":null,"tool_calls":[{"id":"call-5","name":"read","arguments":{"path":"CONTEXT.md","offset":1,"limit":0}}]},
      {"role":"tool","tool_call_id":"call-5","name":"read","result":{"ok":true,"tool":"read","data":{"path":"CONTEXT.md","content":"example","offset":1,"limit":0,"line_count":1}}}
    ]
  }'

  payload_json="$(provider_copilot_build_responses_payload_json "$request_json")"

  [ "$(jq -r '.input[2].role' <<<"$payload_json")" = 'user' ]
  [ "$(jq -r '.input[3].type' <<<"$payload_json")" = 'function_call' ]
  [ "$(jq -r '.input[3].call_id' <<<"$payload_json")" = 'call-5' ]
  [ "$(jq -r '.input[3].name' <<<"$payload_json")" = 'read' ]
  [ "$(jq -r '.input[4].type' <<<"$payload_json")" = 'function_call_output' ]
  [ "$(jq -r '.input[4].call_id' <<<"$payload_json")" = 'call-5' ]
  [ "$(jq -r '[.input[] | select(.role? == "assistant") | .content[]?.type] | any(. == "function_call")' <<<"$payload_json")" = 'false' ]
}

@test "copilot responses payload supports large request bodies without argv overflow" {
  local large_text request_json payload_json

  large_text="$(head -c 3145728 </dev/zero | tr '\0' 'x')"
  request_json="{\"model\":\"gpt-5.4\",\"system_prompt\":\"You are BAISH.\",\"tool_use_instructions\":\"Use tools structurally.\",\"skills\":[],\"tools\":[],\"messages\":[{\"role\":\"user\",\"content\":\"${large_text}\"}]}"

  payload_json="$(provider_copilot_build_responses_payload_json "$request_json")"

  [ "$(jq -r '.model' <<<"$payload_json")" = 'gpt-5.4' ]
  [ "$(jq -r '.input[2].role' <<<"$payload_json")" = 'user' ]
  [ "$(jq -r '.input[2].content[0].text | length' <<<"$payload_json")" = '3145728' ]
}

@test "copilot claude models use anthropic messages api" {
  local auth_json request_json response_json payload_json anth_headers policy_request

  auth_json='{"provider":"copilot","host":"https://github.com","github_token":"gho-test-token","copilot_token":"tid=test;exp=4102444800;proxy-ep=proxy.individual.githubcopilot.com;","copilot_token_expires_at":4102444800,"api_base":"https://api.individual.githubcopilot.com"}'
  baish_state_write_auth_json 'copilot' "$auth_json"

  request_json='{
    "model":"claude-sonnet-4.6",
    "system_prompt":"You are BAISH.",
    "tool_use_instructions":"Use tools structurally.",
    "skills":[],
    "tools":[{"name":"read","description":"Read a file.","input_schema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}}],
    "messages":[{"role":"user","content":"Inspect claude.md"}]
  }'

  response_json="$(provider_copilot_chat "$request_json")"
  payload_json="$(jq -r 'select(.url == "https://api.individual.githubcopilot.com/v1/messages") | .data' "$CURL_LOG")"
  anth_headers="$(jq -c 'select(.url == "https://api.individual.githubcopilot.com/v1/messages") | .headers' "$CURL_LOG")"
  policy_request="$(jq -c 'select(.url == "https://api.individual.githubcopilot.com/models/claude-sonnet-4.6/policy")' "$CURL_LOG")"

  [ "$(jq -r '.assistant_text' <<<"$response_json")" = 'Claude says hi.' ]
  [ "$(jq -r '.tool_calls | length' <<<"$response_json")" = '1' ]
  [ "$(jq -r '.tool_calls[0].id' <<<"$response_json")" = 'call-claude' ]
  [ "$(jq -r '.tool_calls[0].name' <<<"$response_json")" = 'read' ]
  [ "$(jq -r '.tool_calls[0].arguments.path' <<<"$response_json")" = 'claude.md' ]

  [ "$(jq -r '.stream' <<<"$payload_json")" = 'false' ]
  [ "$(jq -r '.max_tokens' <<<"$payload_json")" = '32000' ]
  [ "$(jq -r '.tools[0].name' <<<"$payload_json")" = 'read' ]
  [ "$(jq -r '.messages[0].role' <<<"$payload_json")" = 'user' ]
  [[ "$anth_headers" == *'Openai-Intent: conversation-edits'* ]]
  [ -n "$policy_request" ]
}
