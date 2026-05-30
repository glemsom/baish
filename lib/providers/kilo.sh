#!/usr/bin/env bash

provider_kilo_metadata() {
  jq -cn '{"id": "kilo", "label": "Kilo Gateway", "desc": "OpenAI-compatible gateway with broad model catalog", "selectable": true, "auth_env_var": "KILO_API_KEY"}'
}

provider_kilo_has_env_auth() {
  [[ -n "${KILO_API_KEY:-}" ]]
}

provider_kilo_api_base() {
  printf 'https://api.kilo.ai/api/gateway\n'
}

provider_kilo_active_api_key() {
  if [[ -n "${KILO_API_KEY:-}" ]]; then
    BAISH_KILO_ACTIVE_API_KEY="$KILO_API_KEY"
    BAISH_KILO_ACTIVE_AUTH_SOURCE='env'
    printf '%s\n' "$KILO_API_KEY"
    return 0
  fi

  if [[ -n "${BAISH_KILO_ACTIVE_API_KEY:-}" ]]; then
    printf '%s\n' "$BAISH_KILO_ACTIVE_API_KEY"
    return 0
  fi

  return 1
}

provider_kilo_set_active_api_key() {
  local api_key="$1"
  local auth_source="$2"

  BAISH_KILO_ACTIVE_API_KEY="$api_key"
  BAISH_KILO_ACTIVE_AUTH_SOURCE="$auth_source"
}

provider_kilo_clear_active_api_key() {
  unset BAISH_KILO_ACTIVE_API_KEY
  unset BAISH_KILO_ACTIVE_AUTH_SOURCE
}

provider_kilo_saved_auth_json() {
  local auth_json

  auth_json="$(baish_state_read_auth_json 'kilo')" || return 1
  if ! jq -e 'type == "object" and (.api_key? | type == "string" and length > 0)' >/dev/null 2>&1 <<<"$auth_json"; then
    return 1
  fi

  printf '%s\n' "$auth_json"
}

provider_kilo_prompt_api_key() {
  baish_prompt_secret 'Enter Kilo API key:'
}

provider_kilo_auth() {
  local auth_json api_key

  if provider_kilo_has_env_auth; then
    provider_kilo_set_active_api_key "$KILO_API_KEY" 'env'
    return 0
  fi

  if [[ -n "${BAISH_KILO_ACTIVE_API_KEY:-}" ]]; then
    return 0
  fi

  if auth_json="$(provider_kilo_saved_auth_json 2>/dev/null)"; then
    api_key="$(jq -r '.api_key' <<<"$auth_json")" || return 1
    provider_kilo_set_active_api_key "$api_key" 'saved'
    return 0
  fi

  api_key="$(provider_kilo_prompt_api_key)" || return 1
  provider_kilo_set_active_api_key "$api_key" 'prompt'
}

provider_kilo_commit_auth() {
  local api_key

  if [[ "${BAISH_KILO_ACTIVE_AUTH_SOURCE:-}" == 'env' ]]; then
    return 0
  fi

  api_key="$(provider_kilo_active_api_key)" || return 1
  baish_state_write_auth_json 'kilo' "$(jq -cn --arg api_key "$api_key" '{provider: "kilo", api_key: $api_key}')"
}

provider_kilo_extract_error_message() {
  local body="$1"
  local json_message

  if json_message="$(jq -r '
    if type == "object" then
      .error.message // .error // .message // empty
    else
      empty
    end
  ' <<<"$body" 2>/dev/null)" && [[ -n "$json_message" ]]; then
    printf '%s\n' "$json_message"
    return 0
  fi

  printf '%s\n' "$body" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

provider_kilo_is_auth_failure_status() {
  local status="$1"
  [[ "$status" == '401' || "$status" == '403' ]]
}

provider_kilo_http_request() {
  local method="$1"
  local url="$2"
  local headers_json="$3"
  local body="${4-}"
  local header_file body_file curl_status status_code header_line
  local -a curl_args=()

  header_file="$(mktemp)" || return 1
  body_file="$(mktemp)" || {
    rm -f -- "$header_file"
    return 1
  }

  curl_args=(-sS -X "$method" -D "$header_file" -o "$body_file")
  while IFS= read -r header_line; do
    [[ -z "$header_line" ]] && continue
    curl_args+=(-H "$header_line")
  done < <(jq -r 'to_entries[] | "\(.key): \(.value)"' <<<"$headers_json")

  curl_status=0
  if [[ -n "$body" ]]; then
    curl "${curl_args[@]}" --data-binary @- "$url" <<<"$body" || curl_status=$?
  else
    curl "${curl_args[@]}" "$url" || curl_status=$?
  fi

  BAISH_KILO_HTTP_BODY="$(<"$body_file")"
  status_code="$(awk '/^HTTP\// { code=$2 } END { print code }' "$header_file")"
  BAISH_KILO_HTTP_STATUS="${status_code:-0}"

  rm -f -- "$header_file" "$body_file"

  if (( curl_status != 0 )); then
    printf 'BAISH Kilo HTTP request failed for %s %s (curl exit %s).\n' "$method" "$url" "$curl_status" >&2
    return 1
  fi
}

provider_kilo_auth_headers_json() {
  local api_key="$1"

  jq -cn \
    --arg accept 'application/json' \
    --arg content_type 'application/json' \
    --arg authorization "Bearer $api_key" \
    '{Accept: $accept, "Content-Type": $content_type, Authorization: $authorization}'
}

provider_kilo_models_headers_json() {
  local api_key="$1"

  jq -cn \
    --arg accept 'application/json' \
    --arg authorization "Bearer $api_key" \
    '{Accept: $accept, Authorization: $authorization}'
}

provider_kilo_models_url() {
  printf '%s/models\n' "$(provider_kilo_api_base)"
}

provider_kilo_chat_url() {
  printf '%s/chat/completions\n' "$(provider_kilo_api_base)"
}

provider_kilo_normalize_models_json() {
  local raw_json="$1"

  jq -c '
    if type == "array" then
      .
    elif type == "object" and (.data? | type == "array") then
      .data
    elif type == "object" and (.models? | type == "array") then
      .models
    else
      error("unsupported models response")
    end
    | map({
        id: (.id // .model // .name),
        label: (.name // .label // .display_name // .id // .model)
      })
    | map(select((.id | type) == "string" and (.id | length > 0)))
  ' <<<"$raw_json"
}

provider_kilo_prepare_models() {
  local prompt_on_reject="${1:-1}"
  local api_key headers_json models_json message auth_source

  provider_kilo_auth || return 1

  while true; do
    api_key="$(provider_kilo_active_api_key)" || return 1
    headers_json="$(provider_kilo_models_headers_json "$api_key")" || return 1
    provider_kilo_http_request 'GET' "$(provider_kilo_models_url)" "$headers_json" || return 1

    if [[ "$BAISH_KILO_HTTP_STATUS" == '200' ]]; then
      models_json="$(provider_kilo_normalize_models_json "$BAISH_KILO_HTTP_BODY")" || {
        printf 'BAISH Kilo model listing response was invalid.\n' >&2
        return 1
      }
      printf '%s\n' "$models_json"
      return 0
    fi

    auth_source="${BAISH_KILO_ACTIVE_AUTH_SOURCE:-}"
    if provider_kilo_is_auth_failure_status "$BAISH_KILO_HTTP_STATUS"; then
      if [[ "$auth_source" == 'env' ]]; then
        printf 'BAISH Kilo rejected KILO_API_KEY (HTTP %s).\n' "$BAISH_KILO_HTTP_STATUS" >&2
        return 1
      fi

      if [[ "$prompt_on_reject" != '1' ]]; then
        return 1
      fi

      if [[ "$auth_source" == 'saved' ]]; then
        printf 'Saved Kilo API key was rejected.\n' >&2
      else
        printf 'Kilo API key was rejected.\n' >&2
      fi

      api_key="$(provider_kilo_prompt_api_key)" || return 1
      provider_kilo_set_active_api_key "$api_key" 'prompt'
      continue
    fi

    message="$(provider_kilo_extract_error_message "$BAISH_KILO_HTTP_BODY")"
    printf 'BAISH Kilo model listing failed (HTTP %s): %s\n' "$BAISH_KILO_HTTP_STATUS" "$message" >&2
    return 1
  done
}

provider_kilo_list_models() {
  provider_kilo_prepare_models 1
}

provider_kilo_build_chat_payload_json() {
  local request_json="$1"

  jq -c '
    def skill_messages:
      (.skills // [])
      | map({role: "system", content: ("Loaded skill: " + .name + "\n" + .content)});

    def assistant_tool_calls:
      (.tool_calls // [])
      | map({
          id: .id,
          type: "function",
          function: {
            name: .name,
            arguments: (.arguments | tojson)
          }
        });

    def map_message:
      if .role == "assistant" then
        ({role: "assistant"}
          + (if .content == null then {} else {content: .content} end)
          + (if ((.tool_calls // []) | length) > 0 then {tool_calls: assistant_tool_calls} else {} end))
      elif .role == "tool" then
        {
          role: "tool",
          tool_call_id: .tool_call_id,
          content: (.result | tojson)
        }
      else
        {
          role: .role,
          content: .content
        }
      end;

    {
      model: .model,
      stream: false,
      tool_choice: "auto",
      parallel_tool_calls: true,
      tools: ((.tools // []) | map({
        type: "function",
        function: {
          name: .name,
          description: (.description // ""),
          parameters: (.input_schema // {type: "object", properties: {}, additionalProperties: false})
        }
      })),
      messages: (
        [
          {role: "system", content: .system_prompt},
          {role: "system", content: .tool_use_instructions}
        ]
        + skill_messages
        + ((.messages // []) | map(map_message))
      )
    }
  ' <<<"$request_json"
}

provider_kilo_normalize_chat_response() {
  local response_json="$1"

  jq -c '
    def text_content(value):
      if value == null then
        null
      elif (value | type) == "string" then
        value
      elif (value | type) == "array" then
        (
          value
          | map(
              if type == "string" then
                .
              elif type == "object" and (.type // "") == "text" then
                (.text // "")
              elif type == "object" and (.text? | type == "string") then
                .text
              else
                ""
              end
            )
          | join("")
        )
      else
        (value | tostring)
      end;

    {
      assistant_text: text_content(.choices[0].message.content),
      tool_calls: (
        (.choices[0].message.tool_calls // [])
        | to_entries
        | map({
            id: (.value.id // ("kilo-call-" + ((.key + 1) | tostring))),
            name: (.value.function.name // .value.name // ""),
            arguments: (
              (.value.function.arguments // .value.arguments // {})
              | if type == "string" then fromjson else . end
            )
          })
      )
    }
  ' <<<"$response_json"
}

provider_kilo_validate_selection() {
  local model="$1"
  local api_key headers_json payload_json message auth_source

  if [[ -z "$model" ]]; then
    printf 'BAISH Kilo validation requires a model.\n' >&2
    return 1
  fi

  provider_kilo_auth || return 1

  while true; do
    api_key="$(provider_kilo_active_api_key)" || return 1
    headers_json="$(provider_kilo_auth_headers_json "$api_key")" || return 1
    payload_json="$(jq -cn --arg model "$model" '{model: $model, messages: [{role: "user", content: "Respond with exactly: OK"}], stream: false}')" || return 1
    provider_kilo_http_request 'POST' "$(provider_kilo_chat_url)" "$headers_json" "$payload_json" || return 1

    if [[ "$BAISH_KILO_HTTP_STATUS" == '200' ]]; then
      provider_kilo_commit_auth || return 1
      return 0
    fi

    auth_source="${BAISH_KILO_ACTIVE_AUTH_SOURCE:-}"
    if provider_kilo_is_auth_failure_status "$BAISH_KILO_HTTP_STATUS"; then
      if [[ "$auth_source" == 'env' ]]; then
        printf 'BAISH Kilo rejected KILO_API_KEY (HTTP %s).\n' "$BAISH_KILO_HTTP_STATUS" >&2
        return 1
      fi

      if [[ "$auth_source" == 'saved' ]]; then
        printf 'Saved Kilo API key was rejected.\n' >&2
      else
        printf 'Kilo API key was rejected.\n' >&2
      fi

      api_key="$(provider_kilo_prompt_api_key)" || return 1
      provider_kilo_set_active_api_key "$api_key" 'prompt'
      continue
    fi

    message="$(provider_kilo_extract_error_message "$BAISH_KILO_HTTP_BODY")"
    printf 'BAISH Kilo rejected model %s (HTTP %s): %s\n' "$model" "$BAISH_KILO_HTTP_STATUS" "$message" >&2
    return 3
  done
}

provider_kilo_chat() {
  local request_json="$1"
  local api_key headers_json payload_json response_json message

  provider_kilo_auth || return 1
  api_key="$(provider_kilo_active_api_key)" || return 1
  headers_json="$(provider_kilo_auth_headers_json "$api_key")" || return 1
  payload_json="$(provider_kilo_build_chat_payload_json "$request_json")" || return 1

  if baish_transcript_log_enabled; then
    baish_transcript_log_event "llm_request" "$(jq -cn --arg provider kilo --argjson payload "$payload_json" '{provider: $provider, payload: $payload}')"
  fi

  provider_kilo_http_request 'POST' "$(provider_kilo_chat_url)" "$headers_json" "$payload_json" || return 1

  if [[ "$BAISH_KILO_HTTP_STATUS" != '200' ]]; then
    message="$(provider_kilo_extract_error_message "$BAISH_KILO_HTTP_BODY")"
    printf 'BAISH Kilo chat request failed (HTTP %s): %s\n' "$BAISH_KILO_HTTP_STATUS" "$message" >&2
    return 1
  fi

  if ! jq -e 'type == "object" and (.choices | type == "array" and length > 0) and (.choices[0].message | type == "object")' >/dev/null 2>&1 <<<"$BAISH_KILO_HTTP_BODY"; then
    printf 'BAISH Kilo chat response was invalid.\n' >&2
    return 1
  fi

  response_json="$(provider_kilo_normalize_chat_response "$BAISH_KILO_HTTP_BODY")" || {
    printf 'BAISH Kilo chat response could not be normalized.\n' >&2
    return 1
  }

  printf '%s\n' "$response_json"
}

# ─── Streaming support ──────────────────────────────────────────────

provider_kilo_has_streaming() {
  printf 'true'
}

provider_kilo_http_stream() {
  local method="$1"
  local url="$2"
  local headers_json="$3"
  local body="${4-}"
  local -a curl_args=()
  local header_line

  while IFS= read -r header_line; do
    [[ -z "$header_line" ]] && continue
    curl_args+=(-H "$header_line")
  done < <(jq -r 'to_entries[] | "\(.key): \(.value)"' <<<"$headers_json")

  # -N disables buffering so tokens arrive immediately
  curl_args+=(-sS -N -X "$method")

  if [[ -n "$body" ]]; then
    curl "${curl_args[@]}" --data-binary @- "$url" <<<"$body" || return 1
  else
    curl "${curl_args[@]}" "$url" || return 1
  fi
}

# Build streaming payload for chat_completions (stream: true)
provider_kilo_build_chat_payload_stream_json() {
  local request_json="$1"

  jq -c '
    def skill_messages:
      (.skills // [])
      | map({role: "system", content: ("Loaded skill: " + .name + "\n" + .content)});

    def assistant_tool_calls:
      (.tool_calls // [])
      | map({
          id: .id,
          type: "function",
          function: {
            name: .name,
            arguments: (.arguments | tojson)
          }
        });

    def map_message:
      if .role == "assistant" then
        ({role: "assistant"}
          + (if .content == null then {} else {content: .content} end)
          + (if ((.tool_calls // []) | length) > 0 then {tool_calls: (assistant_tool_calls)} else {} end))
      elif .role == "tool" then
        {
          role: "tool",
          tool_call_id: .tool_call_id,
          content: (.result | tojson)
        }
      else
        {
          role: .role,
          content: .content
        }
      end;

    {
      model: .model,
      stream: true,
      stream_options: {include_usage: true},
      tool_choice: "auto",
      parallel_tool_calls: true,
      tools: ((.tools // []) | map({
        type: "function",
        function: {
          name: .name,
          description: (.description // ""),
          parameters: (.input_schema // {type: "object", properties: {}, additionalProperties: false})
        }
      })),
      messages: (
        [
          {role: "system", content: .system_prompt},
          {role: "system", content: .tool_use_instructions}
        ]
        + skill_messages
        + ((.messages // []) | map(map_message))
      )
    }
  ' <<<"$request_json"
}

# SSE parser for OpenAI chat_completions streaming format.
# Reads SSE from stdin, emits BAISH NDJSON events to stdout.
_kilo_parse_sse() {
  local line data_line content reasoning_content finish_reason
  local tool_call_id tool_name tool_args_delta

  tool_call_id=''
  tool_name=''
  tool_args_delta=''

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip SSE "data: " prefix
    if [[ "$line" == 'data: '* ]]; then
      data_line="${line#data: }"
    elif [[ "$line" == 'data:'* && "$line" != 'data: '* ]]; then
      data_line="${line#data:}"
    else
      continue
    fi

    # Skip [DONE] sentinel and empty lines
    [[ "$data_line" == '[DONE]' ]] && continue
    [[ -z "$data_line" ]] && continue

    # Extract text content from delta
    content="$(jq -r '.choices[0].delta.content // empty' <<<"$data_line" 2>/dev/null)" || continue
    if [[ -n "$content" ]]; then
      local escaped_content
      escaped_content="$(printf '%s' "$content" | jq -Rs '.')" || continue
      printf '{"type":"delta","category":"text","content":%s}\n' "$escaped_content"
    fi

    # Extract reasoning/thinking content
    reasoning_content="$(jq -r '(.choices[0].delta.reasoning_content // .choices[0].delta.reasoning) // empty' <<<"$data_line" 2>/dev/null)" || true
    if [[ -n "$reasoning_content" ]]; then
      local escaped_reasoning
      escaped_reasoning="$(printf '%s' "$reasoning_content" | jq -Rs '.')" || continue
      printf '{"type":"delta","category":"thinking","content":%s}\n' "$escaped_reasoning"
    fi

    # Extract tool call deltas
    local tc_json
    tc_json="$(jq -c '.choices[0].delta.tool_calls[]?' <<<"$data_line" 2>/dev/null)" || true
    if [[ -n "$tc_json" ]]; then
      while IFS= read -r tc; do
        [[ -z "$tc" ]] && continue
        local idx id name args
        idx="$(jq -r '.index // 0' <<<"$tc" 2>/dev/null)" || continue
        id="$(jq -r '.id // empty' <<<"$tc" 2>/dev/null)" || true
        name="$(jq -r '.function.name // empty' <<<"$tc" 2>/dev/null)" || true
        args="$(jq -r '.function.arguments // empty' <<<"$tc" 2>/dev/null)" || true

        # When we get an id, it's a new tool call
        if [[ -n "$id" ]]; then
          tool_call_id="$id"
          tool_name="$name"
          tool_args_delta=''
        fi

        if [[ -n "$args" ]]; then
          tool_args_delta+="$args"
          local escaped_args
          escaped_args="$(printf '%s' "$args" | jq -Rs '.')" || continue
          printf '{"type":"tool_call_delta","index":%s,"tool_call_id":"%s","name":"%s","arguments_delta":%s}\n' \
            "$idx" "$tool_call_id" "$tool_name" "$escaped_args"
        fi
      done <<<"$tc_json"
    fi

    # Check for finish_reason
    finish_reason="$(jq -r '
      if (.choices? | type == "array" and length > 0) then
        .choices[0].finish_reason // empty
      else
        empty
      end
    ' <<<"$data_line" 2>/dev/null)" || true
    if [[ -n "$finish_reason" && "$finish_reason" != 'null' ]]; then
      # Emit pending tool_call if we have accumulated args
      if [[ -n "$tool_call_id" && -n "$tool_args_delta" ]]; then
        local full_args_json
        full_args_json="$(jq -c '.' <<<"$tool_args_delta" 2>/dev/null)" || full_args_json="{}"
        printf '{"type":"tool_call","tool_call_id":"%s","name":"%s","arguments":%s}\n' \
          "$tool_call_id" "$tool_name" "$full_args_json"
      fi

      local mapped_reason
      case "$finish_reason" in
        stop) mapped_reason="stop" ;;
        tool_calls) mapped_reason="tool_calls" ;;
        length) mapped_reason="length" ;;
        *) mapped_reason="stop" ;;
      esac
      printf '{"type":"done","finish_reason":"%s"}\n' "$mapped_reason"
    fi
  done
}

provider_kilo_chat_stream() {
  local request_json="$1"
  local api_key headers_json payload_json message

  provider_kilo_auth || return 1
  api_key="$(provider_kilo_active_api_key)" || return 1
  headers_json="$(provider_kilo_auth_headers_json "$api_key")" || return 1
  payload_json="$(provider_kilo_build_chat_payload_stream_json "$request_json")" || return 1

  if baish_transcript_log_enabled; then
    baish_transcript_log_event "llm_request" "$(jq -cn --arg provider kilo --argjson payload "$payload_json" '{provider: $provider, payload: $payload}')"
  fi
  provider_kilo_http_stream 'POST' "$(provider_kilo_chat_url)" "$headers_json" "$payload_json" \
    | _kilo_parse_sse
}
