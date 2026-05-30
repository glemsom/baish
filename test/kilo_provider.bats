#!/usr/bin/env bats

load test_helper.bash

setup() {
  REPO_ROOT="$(repo_root)"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  CURL_LOG="$BATS_TEST_TMPDIR/kilo-curl-log.jsonl"

  mkdir -p "$TEST_HOME"
  : >"$CURL_LOG"

  source "$REPO_ROOT/lib/state.sh"
  source "$REPO_ROOT/lib/prompt.sh"
  source "$REPO_ROOT/lib/providers/kilo.sh"

  HOME="$TEST_HOME"
  PATH="/usr/bin:/bin"

  unset KILO_API_KEY
  unset BAISH_KILO_ACTIVE_API_KEY
  unset BAISH_KILO_ACTIVE_AUTH_SOURCE

  baish_state_init
}

curl() {
  local method='GET'
  local url=''
  local data=''
  local header_file=''
  local body_file=''
  local status='200'
  local status_text='OK'
  local body='{}'
  local arg authorization=''
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
        if [[ "$2" == Authorization:* ]]; then
          authorization="${2#Authorization: }"
        fi
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

  printf '%s\n' "$(jq -cn --arg method "$method" --arg url "$url" --arg authorization "$authorization" --arg data "$data" '{method: $method, url: $url, authorization: $authorization, data: $data}')" >>"$CURL_LOG"

  case "$method $url $authorization" in
    'GET https://api.kilo.ai/api/gateway/models Bearer env-key'|'GET https://api.kilo.ai/api/gateway/models Bearer saved-key'|'GET https://api.kilo.ai/api/gateway/models Bearer prompt-key')
      body='{"data":[{"id":"kilo-fast","name":"Kilo Fast"},{"id":"kilo-tools","name":"Kilo Tools"}]}'
      ;;
    'GET https://api.kilo.ai/api/gateway/models Bearer bad-saved-key')
      status='401'
      status_text='Unauthorized'
      body='{"error":{"message":"bad key"}}'
      ;;
    'POST https://api.kilo.ai/api/gateway/chat/completions Bearer env-key')
      body='{"choices":[{"message":{"content":"hello from kilo","tool_calls":[{"id":"call-1","type":"function","function":{"name":"read","arguments":"{\"path\":\"README.md\"}"}}]}}]}'
      ;;
    'POST https://api.kilo.ai/api/gateway/chat/completions Bearer prompt-key')
      body='{"choices":[{"message":{"content":"OK"}}]}'
      ;;
    'POST https://api.kilo.ai/api/gateway/chat/completions Bearer saved-key')
      body='{"choices":[{"message":{"content":"OK"}}]}'
      ;;
    'POST https://api.kilo.ai/api/gateway/chat/completions Bearer bad-saved-key')
      status='401'
      status_text='Unauthorized'
      body='{"error":{"message":"bad key"}}'
      ;;
    'POST https://api.kilo.ai/api/gateway/chat/completions Bearer model-denied-key')
      status='404'
      status_text='Not Found'
      body='{"error":{"message":"model unavailable"}}'
      ;;
    *)
      status='404'
      status_text='Not Found'
      body='{"error":{"message":"not found"}}'
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

@test "kilo metadata matches the discovery contract" {
  run provider_kilo_metadata

  [ "$status" -eq 0 ]
  [ "$(jq -r '.id' <<<"$output")" = 'kilo' ]
  [ "$(jq -r '.label' <<<"$output")" = 'Kilo Gateway' ]
  [ "$(jq -r '.desc' <<<"$output")" = 'OpenAI-compatible gateway with broad model catalog' ]
  [ "$(jq -r '.auth_env_var' <<<"$output")" = 'KILO_API_KEY' ]
}

@test "kilo env auth overrides saved auth for the current process only" {
  local models_json auth_file authorization

  auth_file="$TEST_HOME/.baish/auth/kilo.json"
  baish_state_write_auth_json 'kilo' '{"provider":"kilo","api_key":"saved-key"}'
  KILO_API_KEY='env-key'

  models_json="$(provider_kilo_list_models)"
  authorization="$(jq -r 'select(.url == "https://api.kilo.ai/api/gateway/models") | .authorization' "$CURL_LOG")"

  [ "$(jq -r '.[0].id' <<<"$models_json")" = 'kilo-fast' ]
  [ "$authorization" = 'Bearer env-key' ]
  [ "$(jq -r '.api_key' "$auth_file")" = 'saved-key' ]
  ! grep -q 'env-key' "$auth_file"
}

@test "kilo falls back to saved auth when no env key is present" {
  local models_json authorization

  baish_state_write_auth_json 'kilo' '{"provider":"kilo","api_key":"saved-key"}'

  models_json="$(provider_kilo_list_models)"
  authorization="$(jq -r 'select(.url == "https://api.kilo.ai/api/gateway/models") | .authorization' "$CURL_LOG")"

  [ "$(jq -r '.[1].id' <<<"$models_json")" = 'kilo-tools' ]
  [ "$authorization" = 'Bearer saved-key' ]
}

@test "kilo validation retries auth failures with a prompted replacement key and persists it" {
  local auth_file validation_payload authorization

  baish_state_write_auth_json 'kilo' '{"provider":"kilo","api_key":"bad-saved-key"}'

  provider_kilo_prompt_api_key() {
    printf 'prompt-key\n'
  }

  run provider_kilo_validate_selection 'kilo-fast'

  auth_file="$TEST_HOME/.baish/auth/kilo.json"
  validation_payload="$(jq -r 'select(.method == "POST" and .authorization == "Bearer prompt-key") | .data' "$CURL_LOG")"
  authorization="$(jq -r 'select(.method == "POST" and .authorization == "Bearer prompt-key") | .authorization' "$CURL_LOG")"

  [ "$status" -eq 0 ]
  [[ "$output" == *'Saved Kilo API key was rejected.'* ]]
  [ "$authorization" = 'Bearer prompt-key' ]
  [ "$(jq -r '.model' <<<"$validation_payload")" = 'kilo-fast' ]
  [ "$(jq -r '.messages[0].content' <<<"$validation_payload")" = 'Respond with exactly: OK' ]
  [ "$(jq -r '.api_key' "$auth_file")" = 'prompt-key' ]
}

@test "kilo validation keeps credentials and asks for a new model on non-auth failures" {
  provider_kilo_set_active_api_key 'model-denied-key' 'prompt'

  run provider_kilo_validate_selection 'kilo-fast'

  [ "$status" -eq 3 ]
  [[ "$output" == *'BAISH Kilo rejected model kilo-fast (HTTP 404): model unavailable'* ]]
}

@test "kilo chat normalizes OpenAI-style tool calls" {
  local response_json request_json

  KILO_API_KEY='env-key'
  request_json='{
    "model":"kilo-tools",
    "system_prompt":"You are BAISH.",
    "tool_use_instructions":"Use tools structurally.",
    "skills":[],
    "tools":[{"name":"read","description":"Read a file.","input_schema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}}],
    "messages":[{"role":"user","content":"Inspect README.md"}]
  }'

  response_json="$(provider_kilo_chat "$request_json")"

  [ "$(jq -r '.assistant_text' <<<"$response_json")" = 'hello from kilo' ]
  [ "$(jq -r '.tool_calls[0].id' <<<"$response_json")" = 'call-1' ]
  [ "$(jq -r '.tool_calls[0].name' <<<"$response_json")" = 'read' ]
  [ "$(jq -r '.tool_calls[0].arguments.path' <<<"$response_json")" = 'README.md' ]
}
