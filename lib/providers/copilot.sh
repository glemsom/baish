#!/usr/bin/env bash

provider_copilot_metadata() {
  jq -cn '{"id": "copilot", "label": "GitHub Copilot", "desc": "GitHub Copilot Chat provider", "selectable": true, "auth_env_var": "COPILOT_GITHUB_TOKEN"}'
}

provider_copilot_has_env_auth() {
  provider_copilot_has_env_token
}

provider_copilot_normalize_host() {
  local host="$1"

  if [[ -z "$host" ]]; then
    printf 'BAISH Copilot host is empty.\n' >&2
    return 1
  fi

  if [[ "$host" =~ ^https?:// ]]; then
    provider_copilot_trim_trailing_slash "$host"
    return 0
  fi

  provider_copilot_trim_trailing_slash "https://$host"
}

provider_copilot_default_host() {
  local host="${BAISH_COPILOT_HOST:-${COPILOT_GH_HOST:-${GH_HOST:-github.com}}}"

  provider_copilot_normalize_host "$host"
}

provider_copilot_oauth_client_id() {
  printf 'Iv1.b507a08c87ecfe98\n'
}

provider_copilot_oauth_scope() {
  printf 'read:user\n'
}

provider_copilot_user_agent() {
  printf 'GitHubCopilotChat/0.35.0\n'
}

provider_copilot_editor_version() {
  printf 'vscode/1.107.0\n'
}

provider_copilot_editor_plugin_version() {
  printf 'copilot-chat/0.35.0\n'
}

provider_copilot_integration_id() {
  printf 'vscode-chat\n'
}

provider_copilot_trim_trailing_slash() {
  local value="$1"
  value="${value%/}"
  printf '%s\n' "$value"
}

provider_copilot_now_epoch() {
  date -u +%s
}

provider_copilot_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr -d '\n' </proc/sys/kernel/random/uuid
    printf '\n'
    return 0
  fi

  printf '%s\n' "$(printf '%s' "$$-$(provider_copilot_now_epoch)-${RANDOM:-0}" | md5sum | awk '{print $1}')"
}

provider_copilot_session_id() {
  if [[ -z "${BAISH_COPILOT_SESSION_ID:-}" ]]; then
    BAISH_COPILOT_SESSION_ID="$(provider_copilot_uuid)" || return 1
  fi

  printf '%s\n' "$BAISH_COPILOT_SESSION_ID"
}

provider_copilot_log_event() {
  local event="$1"
  local metadata_json="${2-}"

  if declare -F baish_log_event >/dev/null 2>&1; then
    baish_log_event "$event" "$metadata_json" || return 1
  fi
}

provider_copilot_dotcom_api_base() {
  local host="$1"
  local normalized scheme authority

  normalized="$(provider_copilot_trim_trailing_slash "$host")"

  if [[ "$normalized" =~ ^(https?)://([^/]+)$ ]]; then
    scheme="${BASH_REMATCH[1]}"
    authority="${BASH_REMATCH[2]}"
  else
    printf 'BAISH Copilot host is invalid: %s\n' "$host" >&2
    return 1
  fi

  if [[ "$authority" == 'github.com' ]]; then
    printf 'https://api.github.com\n'
    return 0
  fi

  if [[ "$authority" == api.* ]]; then
    printf '%s://%s\n' "$scheme" "$authority"
    return 0
  fi

  printf '%s://api.%s\n' "$scheme" "$authority"
}

provider_copilot_host_authority() {
  local host="$1"
  local normalized

  normalized="$(provider_copilot_trim_trailing_slash "$host")"
  if [[ "$normalized" =~ ^https?://([^/]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  printf 'BAISH Copilot host is invalid: %s\n' "$host" >&2
  return 1
}

provider_copilot_extract_error_message() {
  local body="$1"
  local json_message

  if json_message="$(jq -r '
    if type == "object" then
      .error_description // .message // .error.message // .error.code // .error // empty
    else
      empty
    end
  ' <<<"$body" 2>/dev/null)" && [[ -n "$json_message" ]]; then
    printf '%s\n' "$json_message"
    return 0
  fi

  printf '%s\n' "$body" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

provider_copilot_http_request() {
  local method="$1"
  local url="$2"
  local headers_json="$3"
  local body="${4-}"
  local header_file body_file started_at finished_at curl_status status_code
  local -a curl_args=()
  local header_line

  header_file="$(mktemp)" || return 1
  body_file="$(mktemp)" || {
    rm -f -- "$header_file"
    return 1
  }

  started_at="$(date +%s%3N)"
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
  finished_at="$(date +%s%3N)"

  BAISH_COPILOT_HTTP_BODY="$(<"$body_file")"
  status_code="$(awk '/^HTTP\// { code=$2 } END { print code }' "$header_file")"
  BAISH_COPILOT_HTTP_STATUS="${status_code:-0}"

  provider_copilot_log_event 'provider_http' "$(jq -cn \
    --arg provider 'copilot' \
    --arg method "$method" \
    --arg url "$url" \
    --argjson status_code "${BAISH_COPILOT_HTTP_STATUS:-0}" \
    --argjson duration_ms "$(( finished_at - started_at ))" \
    '{provider: $provider, method: $method, url: $url, status_code: $status_code, duration_ms: $duration_ms}')"

  rm -f -- "$header_file" "$body_file"

  if [[ "$curl_status" -ne 0 ]]; then
    printf 'BAISH Copilot HTTP request failed for %s %s (curl exit %s).\n' "$method" "$url" "$curl_status" >&2
    return 1
  fi
}

provider_copilot_request_device_code_json() {
  local host="$1"
  local client_id scope headers_json body url message

  client_id="$(provider_copilot_oauth_client_id)" || return 1
  scope="$(provider_copilot_oauth_scope)" || return 1
  url="$(provider_copilot_trim_trailing_slash "$host")/login/device/code"
  headers_json="$(jq -cn \
    --arg accept 'application/json' \
    --arg content_type 'application/x-www-form-urlencoded' \
    --arg user_agent "$(provider_copilot_user_agent)" \
    '{Accept: $accept, "Content-Type": $content_type, "User-Agent": $user_agent}')" || return 1
  body="client_id=$(jq -rn --arg value "$client_id" '$value|@uri')&scope=$(jq -rn --arg value "$scope" '$value|@uri')"

  provider_copilot_http_request 'POST' "$url" "$headers_json" "$body" || return 1

  if [[ "$BAISH_COPILOT_HTTP_STATUS" != '200' ]]; then
    message="$(provider_copilot_extract_error_message "$BAISH_COPILOT_HTTP_BODY")"
    printf 'BAISH Copilot device-code request failed (HTTP %s): %s\n' "$BAISH_COPILOT_HTTP_STATUS" "$message" >&2
    return 1
  fi

  if ! jq -e '
    type == "object"
    and (.device_code | type == "string" and length > 0)
    and (.user_code | type == "string" and length > 0)
    and (.verification_uri | type == "string" and length > 0)
    and (.expires_in | type == "number")
    and (.interval | type == "number")
  ' >/dev/null 2>&1 <<<"$BAISH_COPILOT_HTTP_BODY"; then
    printf 'BAISH Copilot device-code response was invalid.\n' >&2
    return 1
  fi

  printf '%s\n' "$BAISH_COPILOT_HTTP_BODY"
}

provider_copilot_poll_access_token_json() {
  local host="$1"
  local device_code="$2"
  local headers_json body url message

  url="$(provider_copilot_trim_trailing_slash "$host")/login/oauth/access_token"
  headers_json="$(jq -cn \
    --arg accept 'application/json' \
    --arg content_type 'application/x-www-form-urlencoded' \
    --arg user_agent "$(provider_copilot_user_agent)" \
    '{Accept: $accept, "Content-Type": $content_type, "User-Agent": $user_agent}')" || return 1
  body="client_id=$(jq -rn --arg value "$(provider_copilot_oauth_client_id)" '$value|@uri')&device_code=$(jq -rn --arg value "$device_code" '$value|@uri')&grant_type=$(jq -rn --arg value 'urn:ietf:params:oauth:grant-type:device_code' '$value|@uri')"

  provider_copilot_http_request 'POST' "$url" "$headers_json" "$body" || return 1

  if [[ "$BAISH_COPILOT_HTTP_STATUS" != '200' ]]; then
    message="$(provider_copilot_extract_error_message "$BAISH_COPILOT_HTTP_BODY")"
    printf 'BAISH Copilot access-token polling failed (HTTP %s): %s\n' "$BAISH_COPILOT_HTTP_STATUS" "$message" >&2
    return 1
  fi

  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$BAISH_COPILOT_HTTP_BODY"; then
    printf 'BAISH Copilot access-token response was invalid JSON.\n' >&2
    return 1
  fi

  printf '%s\n' "$BAISH_COPILOT_HTTP_BODY"
}

provider_copilot_wait_for_github_token() {
  local host="$1"
  local device_json="$2"
  local device_code expires_in interval started_at now response_json token error_code next_interval error_message

  device_code="$(jq -r '.device_code' <<<"$device_json")" || return 1
  expires_in="$(jq -r '.expires_in' <<<"$device_json")" || return 1
  interval="$(jq -r '.interval' <<<"$device_json")" || return 1
  started_at="$(provider_copilot_now_epoch)" || return 1

  while true; do
    now="$(provider_copilot_now_epoch)" || return 1
    if (( now - started_at >= expires_in )); then
      printf 'BAISH Copilot device code expired before authorization completed.\n' >&2
      return 1
    fi

    response_json="$(provider_copilot_poll_access_token_json "$host" "$device_code")" || return 1
    token="$(jq -r '.access_token // empty' <<<"$response_json")" || return 1
    if [[ -n "$token" ]]; then
      printf '%s\n' "$response_json"
      return 0
    fi

    error_code="$(jq -r '.error // empty' <<<"$response_json")" || return 1
    case "$error_code" in
      authorization_pending|'')
        sleep "$interval"
        ;;
      slow_down)
        next_interval="$(jq -r '.interval // empty' <<<"$response_json")" || return 1
        if [[ "$next_interval" =~ ^[0-9]+$ ]] && (( next_interval > interval )); then
          interval="$next_interval"
        fi
        interval=$(( interval + 5 ))
        sleep "$interval"
        ;;
      access_denied)
        printf 'BAISH Copilot authorization was denied in the browser.\n' >&2
        return 1
        ;;
      expired_token|token_expired)
        printf 'BAISH Copilot device code expired before authorization completed.\n' >&2
        return 1
        ;;
      *)
        error_message="$(provider_copilot_extract_error_message "$response_json")"
        printf 'BAISH Copilot authorization failed: %s\n' "$error_message" >&2
        return 1
        ;;
    esac
  done
}

provider_copilot_github_auth_headers_json() {
  local github_token="$1"

  jq -cn \
    --arg accept 'application/json' \
    --arg authorization "Bearer $github_token" \
    --arg user_agent "$(provider_copilot_user_agent)" \
    '{
      Accept: $accept,
      Authorization: $authorization,
      "User-Agent": $user_agent
    }'
}

provider_copilot_token_exchange_headers_json() {
  local github_token="$1"

  jq -cn \
    --arg accept 'application/json' \
    --arg authorization "Bearer $github_token" \
    --arg user_agent "$(provider_copilot_user_agent)" \
    --arg editor_version "$(provider_copilot_editor_version)" \
    --arg editor_plugin_version "$(provider_copilot_editor_plugin_version)" \
    --arg integration_id "$(provider_copilot_integration_id)" \
    '{
      Accept: $accept,
      Authorization: $authorization,
      "User-Agent": $user_agent,
      "Editor-Version": $editor_version,
      "Editor-Plugin-Version": $editor_plugin_version,
      "Copilot-Integration-Id": $integration_id
    }'
}

provider_copilot_env_token_name() {
  if [[ -n "${COPILOT_GITHUB_TOKEN:-}" ]]; then
    printf 'COPILOT_GITHUB_TOKEN\n'
    return 0
  fi

  if [[ -n "${GH_TOKEN:-}" ]]; then
    printf 'GH_TOKEN\n'
    return 0
  fi

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    printf 'GITHUB_TOKEN\n'
    return 0
  fi

  return 1
}

provider_copilot_env_token_value() {
  local token_name

  token_name="$(provider_copilot_env_token_name)" || return 1
  printf '%s\n' "${!token_name}"
}

provider_copilot_has_env_token() {
  provider_copilot_env_token_name >/dev/null 2>&1
}

provider_copilot_fetch_login() {
  local host="$1"
  local github_token="$2"
  local api_base headers_json message

  api_base="$(provider_copilot_dotcom_api_base "$host")" || return 1
  headers_json="$(provider_copilot_github_auth_headers_json "$github_token")" || return 1

  provider_copilot_http_request 'GET' "$api_base/user" "$headers_json" || return 1

  if [[ "$BAISH_COPILOT_HTTP_STATUS" != '200' ]]; then
    message="$(provider_copilot_extract_error_message "$BAISH_COPILOT_HTTP_BODY")"
    printf 'BAISH Copilot could not fetch the authenticated GitHub user (HTTP %s): %s\n' "$BAISH_COPILOT_HTTP_STATUS" "$message" >&2
    return 1
  fi

  jq -r '.login // empty' <<<"$BAISH_COPILOT_HTTP_BODY"
}

provider_copilot_token_proxy_host() {
  local token="$1"
  local proxy_host

  proxy_host="$(sed -n 's/.*proxy-ep=\([^;]*\).*/\1/p' <<<"$token")"
  if [[ -n "$proxy_host" ]]; then
    printf '%s\n' "$proxy_host"
    return 0
  fi

  return 1
}

provider_copilot_api_base_fallback() {
  local host="$1"
  local authority

  authority="$(provider_copilot_host_authority "$host")" || return 1
  if [[ "$authority" == 'github.com' ]]; then
    printf 'https://api.individual.githubcopilot.com\n'
    return 0
  fi

  authority="${authority#api.}"
  printf 'https://copilot-api.%s\n' "$authority"
}

provider_copilot_api_base_from_token() {
  local host="$1"
  local token="$2"
  local proxy_host

  proxy_host="$(provider_copilot_token_proxy_host "$token" 2>/dev/null || true)"
  if [[ -n "$proxy_host" ]]; then
    printf 'https://%s\n' "${proxy_host/proxy./api.}"
    return 0
  fi

  provider_copilot_api_base_fallback "$host"
}

provider_copilot_api_base_from_auth_json() {
  local auth_json="$1"
  local api_base host token endpoint_api

  api_base="$(jq -r '.api_base // empty' <<<"$auth_json")" || return 1
  if [[ -n "$api_base" ]]; then
    provider_copilot_trim_trailing_slash "$api_base"
    return 0
  fi

  host="$(jq -r '.host // empty' <<<"$auth_json")" || return 1
  token="$(jq -r '.copilot_token // empty' <<<"$auth_json")" || return 1
  if [[ -n "$host" && -n "$token" ]]; then
    provider_copilot_api_base_from_token "$host" "$token"
    return 0
  fi

  endpoint_api="$(jq -r '.endpoints.api // empty' <<<"$auth_json")" || return 1
  if [[ -n "$endpoint_api" ]]; then
    provider_copilot_trim_trailing_slash "$endpoint_api"
    return 0
  fi

  if [[ -n "$host" ]]; then
    provider_copilot_api_base_fallback "$host"
    return 0
  fi

  printf 'BAISH Copilot auth is missing the runtime API base. Run /connect.\n' >&2
  return 1
}

provider_copilot_token_expiry_epoch() {
  local auth_json="$1"
  local raw_expiry parsed_expiry

  raw_expiry="$(jq -r '.copilot_token_expires_at // empty' <<<"$auth_json")" || return 1
  if [[ -z "$raw_expiry" || "$raw_expiry" == 'null' ]]; then
    printf '0\n'
    return 0
  fi

  if [[ "$raw_expiry" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$raw_expiry"
    return 0
  fi

  parsed_expiry="$(date -u -d "$raw_expiry" +%s 2>/dev/null || true)"
  if [[ "$parsed_expiry" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$parsed_expiry"
  else
    printf '0\n'
  fi
}

provider_copilot_token_needs_refresh() {
  local auth_json="$1"
  local token expiry now

  token="$(jq -r '.copilot_token // empty' <<<"$auth_json")" || return 1
  if [[ -z "$token" ]]; then
    return 0
  fi

  expiry="$(provider_copilot_token_expiry_epoch "$auth_json")" || return 1
  now="$(provider_copilot_now_epoch)" || return 1

  if (( expiry <= now + 60 )); then
    return 0
  fi

  return 1
}

provider_copilot_auth_json_with_ids() {
  local auth_json="$1"
  local machine_id device_id updated_json

  machine_id="$(jq -r '.machine_id // empty' <<<"$auth_json")" || return 1
  device_id="$(jq -r '.device_id // empty' <<<"$auth_json")" || return 1

  if [[ -n "$machine_id" && -n "$device_id" ]]; then
    printf '%s\n' "$auth_json"
    return 0
  fi

  [[ -n "$machine_id" ]] || machine_id="$(provider_copilot_uuid)" || return 1
  [[ -n "$device_id" ]] || device_id="$(provider_copilot_uuid)" || return 1

  updated_json="$(jq -cn \
    --argjson auth "$auth_json" \
    --arg machine_id "$machine_id" \
    --arg device_id "$device_id" \
    '$auth + {machine_id: $machine_id, device_id: $device_id}')" || return 1

  printf '%s\n' "$updated_json"
}

provider_copilot_refresh_auth_json() {
  local auth_json="$1"
  local github_token_override="${2-}"
  local host github_token api_base headers_json url message refreshed_json runtime_api_base

  host="$(jq -r '.host // empty' <<<"$auth_json")" || return 1
  github_token="$github_token_override"
  if [[ -z "$github_token" ]]; then
    github_token="$(jq -r '.github_token // empty' <<<"$auth_json")" || return 1
  fi

  if [[ -z "$host" || -z "$github_token" ]]; then
    printf 'BAISH Copilot auth is missing the GitHub host or token. Run /connect.\n' >&2
    return 1
  fi

  auth_json="$(provider_copilot_auth_json_with_ids "$auth_json")" || return 1
  api_base="$(provider_copilot_dotcom_api_base "$host")" || return 1
  headers_json="$(provider_copilot_token_exchange_headers_json "$github_token")" || return 1
  url="$api_base/copilot_internal/v2/token"

  provider_copilot_http_request 'GET' "$url" "$headers_json" || return 1

  if [[ "$BAISH_COPILOT_HTTP_STATUS" != '200' ]]; then
    message="$(provider_copilot_extract_error_message "$BAISH_COPILOT_HTTP_BODY")"
    printf 'BAISH Copilot token refresh failed (HTTP %s): %s\n' "$BAISH_COPILOT_HTTP_STATUS" "$message" >&2

    if [[ "$BAISH_COPILOT_HTTP_STATUS" == '404' ]]; then
      printf 'The Copilot token endpoint was not found for %s. This usually means the GitHub account does not have Copilot access on that host, or the wrong GitHub host is configured.\n' "$host" >&2
      printf 'If you use GitHub Enterprise Cloud or data residency, set BAISH_COPILOT_HOST (or COPILOT_GH_HOST / GH_HOST) before running /connect.\n' >&2
    fi

    return 1
  fi

  if ! jq -e 'type == "object" and (.token | type == "string" and length > 0)' >/dev/null 2>&1 <<<"$BAISH_COPILOT_HTTP_BODY"; then
    printf 'BAISH Copilot token refresh response was invalid.\n' >&2
    return 1
  fi

  runtime_api_base="$(provider_copilot_api_base_from_token "$host" "$(jq -r '.token' <<<"$BAISH_COPILOT_HTTP_BODY")")" || return 1
  refreshed_json="$(jq -cn \
    --argjson auth "$auth_json" \
    --argjson refresh "$BAISH_COPILOT_HTTP_BODY" \
    --arg api_base "$runtime_api_base" \
    '
      $auth
      + {
          provider: "copilot",
          api_base: $api_base,
          copilot_token: $refresh.token,
          copilot_token_expires_at: ($refresh.expires_at // $auth.copilot_token_expires_at // 0),
          copilot_token_refresh_in: ($refresh.refresh_in // null),
          sku: ($refresh.sku // $auth.sku // null),
          copilot_user: ($refresh.user // $auth.copilot_user // null)
        }
      | with_entries(select(.value != null))
    ')" || return 1

  printf '%s\n' "$refreshed_json"
}

provider_copilot_metadata_only_auth_json() {
  local auth_json="$1"

  jq -cn \
    --argjson auth "$auth_json" \
    '$auth | del(.copilot_token, .copilot_token_expires_at, .copilot_token_refresh_in)' || return 1
}

provider_copilot_env_auth_json() {
  local existing_auth_json="${1:-{}}"
  local host auth_env_var auth_json

  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$existing_auth_json"; then
    existing_auth_json='{}'
  fi

  host="$(provider_copilot_default_host)" || return 1
  auth_env_var="$(provider_copilot_env_token_name)" || return 1

  auth_json="$(jq -cn \
    --argjson auth "$existing_auth_json" \
    --arg host "$host" \
    --arg auth_env_var "$auth_env_var" \
    '{
      provider: "copilot",
      auth_source: "env",
      auth_env_var: $auth_env_var,
      host: $host,
      login: ($auth.login // null),
      api_base: ($auth.api_base // null),
      sku: ($auth.sku // null),
      copilot_user: ($auth.copilot_user // null),
      machine_id: ($auth.machine_id // null),
      device_id: ($auth.device_id // null)
    }
    | with_entries(select(.value != null))')" || return 1

  provider_copilot_auth_json_with_ids "$auth_json"
}

provider_copilot_read_auth_json() {
  local auth_json

  auth_json="$(baish_state_read_auth_json 'copilot')" || return 1
  if ! jq -e 'type == "object" and (.github_token? | type == "string" and length > 0)' >/dev/null 2>&1 <<<"$auth_json"; then
    printf 'BAISH Copilot is not connected. Run /connect first.\n' >&2
    return 1
  fi

  printf '%s\n' "$auth_json"
}

provider_copilot_get_active_auth_json() {
  local auth_json existing_auth_json refreshed_json persisted_json login

  if provider_copilot_has_env_token; then
    existing_auth_json="$(baish_state_read_auth_json 'copilot' 2>/dev/null || printf '{}\n')" || return 1
    auth_json="$(provider_copilot_env_auth_json "$existing_auth_json")" || return 1
    login="$(jq -r '.login // empty' <<<"$auth_json")" || return 1
    if [[ -z "$login" ]]; then
      login="$(provider_copilot_fetch_login "$(jq -r '.host' <<<"$auth_json")" "$(provider_copilot_env_token_value)" 2>/dev/null || true)"
      if [[ -n "$login" ]]; then
        auth_json="$(jq -cn --argjson auth "$auth_json" --arg login "$login" '$auth + {login: $login}')" || return 1
      fi
    fi
    refreshed_json="$(provider_copilot_refresh_auth_json "$auth_json" "$(provider_copilot_env_token_value)")" || return 1
    persisted_json="$(provider_copilot_metadata_only_auth_json "$refreshed_json")" || return 1
    baish_state_write_auth_json 'copilot' "$persisted_json" || return 1
    printf '%s\n' "$refreshed_json"
    return 0
  fi

  auth_json="$(provider_copilot_read_auth_json)" || return 1
  auth_json="$(provider_copilot_auth_json_with_ids "$auth_json")" || return 1

  if provider_copilot_token_needs_refresh "$auth_json"; then
    refreshed_json="$(provider_copilot_refresh_auth_json "$auth_json")" || return 1
    baish_state_write_auth_json 'copilot' "$refreshed_json" || return 1
    auth_json="$refreshed_json"
  else
    if [[ -z "$(jq -r '.api_base // empty' <<<"$auth_json")" ]]; then
      auth_json="$(jq -cn \
        --argjson auth "$auth_json" \
        --arg api_base "$(provider_copilot_api_base_from_auth_json "$auth_json")" \
        '$auth + {api_base: $api_base}')" || return 1
    fi
    baish_state_write_auth_json 'copilot' "$auth_json" || return 1
  fi

  printf '%s\n' "$auth_json"
}

provider_copilot_try_reuse_existing_auth() {
  local auth_json refreshed_json

  auth_json="$(baish_state_read_auth_json 'copilot')" || return 1
  if ! jq -e 'type == "object" and (.github_token? | type == "string" and length > 0)' >/dev/null 2>&1 <<<"$auth_json"; then
    return 1
  fi

  refreshed_json="$(provider_copilot_refresh_auth_json "$auth_json" 2>/dev/null)" || return 1
  baish_state_write_auth_json 'copilot' "$refreshed_json" || return 1

  if [[ -n "$(jq -r '.login // empty' <<<"$refreshed_json")" ]]; then
    printf 'Reused existing Copilot auth for %s.\n' "$(jq -r '.login' <<<"$refreshed_json")"
  else
    printf 'Reused existing Copilot auth.\n'
  fi
}

provider_copilot_auth_from_env() {
  local existing_auth_json auth_json auth_env_var env_token login refreshed_json persisted_json

  if ! provider_copilot_has_env_token; then
    printf 'BAISH Copilot env auth requires COPILOT_GITHUB_TOKEN, GH_TOKEN, or GITHUB_TOKEN.\n' >&2
    return 1
  fi

  existing_auth_json="$(baish_state_read_auth_json 'copilot' 2>/dev/null || printf '{}\n')" || return 1
  auth_json="$(provider_copilot_env_auth_json "$existing_auth_json")" || return 1
  auth_env_var="$(provider_copilot_env_token_name)" || return 1
  env_token="$(provider_copilot_env_token_value)" || return 1
  login="$(provider_copilot_fetch_login "$(jq -r '.host' <<<"$auth_json")" "$env_token" 2>/dev/null || true)"

  if [[ -n "$login" ]]; then
    auth_json="$(jq -cn --argjson auth "$auth_json" --arg login "$login" '$auth + {login: $login}')" || return 1
  fi

  refreshed_json="$(provider_copilot_refresh_auth_json "$auth_json" "$env_token")" || return 1
  if [[ -n "$login" ]]; then
    refreshed_json="$(jq -cn --argjson auth "$refreshed_json" --arg login "$login" '$auth + {login: $login}')" || return 1
  fi
  provider_copilot_list_models_with_auth_json "$refreshed_json" >/dev/null || return 1
  persisted_json="$(provider_copilot_metadata_only_auth_json "$refreshed_json")" || return 1
  baish_state_write_auth_json 'copilot' "$persisted_json" || return 1

  printf 'Using Copilot GitHub token from %s.\n' "$auth_env_var"
  if [[ -n "$login" ]]; then
    printf 'Copilot authorization completed for %s.\n' "$login"
  else
    printf 'Copilot authorization completed.\n'
  fi
}

provider_copilot_auth() {
  local host device_json access_token_json github_token login auth_json refreshed_json

  if provider_copilot_has_env_token; then
    provider_copilot_auth_from_env
    return $?
  fi

  if provider_copilot_try_reuse_existing_auth; then
    return 0
  fi

  host="$(provider_copilot_default_host)" || return 1
  device_json="$(provider_copilot_request_device_code_json "$host")" || return 1

  printf 'To connect Copilot, visit %s and enter code %s\n' \
    "$(jq -r '.verification_uri' <<<"$device_json")" \
    "$(jq -r '.user_code' <<<"$device_json")"
  printf 'Waiting for GitHub authorization...\n'

  access_token_json="$(provider_copilot_wait_for_github_token "$host" "$device_json")" || return 1
  github_token="$(jq -r '.access_token' <<<"$access_token_json")" || return 1
  login="$(provider_copilot_fetch_login "$host" "$github_token" 2>/dev/null || true)"

  auth_json="$(jq -cn \
    --arg host "$host" \
    --arg github_token "$github_token" \
    --arg github_token_type "$(jq -r '.token_type // empty' <<<"$access_token_json")" \
    --arg github_scope "$(jq -r '.scope // empty' <<<"$access_token_json")" \
    --arg login "$login" \
    --arg machine_id "$(provider_copilot_uuid)" \
    --arg device_id "$(provider_copilot_uuid)" \
    '{
      provider: "copilot",
      host: $host,
      github_token: $github_token,
      github_token_type: (if $github_token_type == "" then null else $github_token_type end),
      github_scope: (if $github_scope == "" then null else $github_scope end),
      login: (if $login == "" then null else $login end),
      machine_id: $machine_id,
      device_id: $device_id
    }
    | with_entries(select(.value != null))')" || return 1

  refreshed_json="$(provider_copilot_refresh_auth_json "$auth_json")" || return 1
  baish_state_write_auth_json 'copilot' "$refreshed_json" || return 1

  if [[ -n "$login" ]]; then
    printf 'Copilot authorization completed for %s.\n' "$login"
  else
    printf 'Copilot authorization completed.\n'
  fi
}

provider_copilot_normalize_models_json() {
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
    | map(select((.model_picker_enabled? // true) != false))
  ' <<<"$raw_json"
}

provider_copilot_request_initiator() {
  local request_json="$1"
  local last_role

  last_role="$(jq -r '
    if ((.messages // []) | length) == 0 then
      "user"
    else
      ((.messages // [])[-1].role // "user")
    end
  ' <<<"$request_json" 2>/dev/null || true)"

  if [[ "$last_role" == 'user' || -z "$last_role" ]]; then
    printf 'user\n'
  else
    printf 'agent\n'
  fi
}

provider_copilot_auth_bearer_token() {
  local auth_json="$1"
  local copilot_token

  copilot_token="$(jq -r '.copilot_token // empty' <<<"$auth_json")" || return 1
  if [[ -z "$copilot_token" ]]; then
    printf 'BAISH Copilot auth is missing the runtime Copilot token. Run /connect.\n' >&2
    return 1
  fi

  printf '%s\n' "$copilot_token"
}

provider_copilot_base_api_headers_json() {
  local auth_json="$1"
  local bearer_token

  bearer_token="$(provider_copilot_auth_bearer_token "$auth_json")" || return 1

  jq -cn \
    --arg accept 'application/json' \
    --arg content_type 'application/json' \
    --arg authorization "Bearer $bearer_token" \
    --arg user_agent "$(provider_copilot_user_agent)" \
    --arg editor_version "$(provider_copilot_editor_version)" \
    --arg editor_plugin_version "$(provider_copilot_editor_plugin_version)" \
    --arg integration_id "$(provider_copilot_integration_id)" \
    '{
      Accept: $accept,
      "Content-Type": $content_type,
      Authorization: $authorization,
      "User-Agent": $user_agent,
      "Editor-Version": $editor_version,
      "Editor-Plugin-Version": $editor_plugin_version,
      "Copilot-Integration-Id": $integration_id
    }'
}

provider_copilot_api_headers_json() {
  local auth_json="$1"
  local request_json="${2:-{}}"
  local base_headers_json initiator

  base_headers_json="$(provider_copilot_base_api_headers_json "$auth_json")" || return 1
  initiator="$(provider_copilot_request_initiator "$request_json")" || return 1

  jq -cn \
    --argjson headers "$base_headers_json" \
    --arg initiator "$initiator" \
    '$headers + {
      "X-Initiator": $initiator,
      "Openai-Intent": "conversation-edits"
    }'
}

provider_copilot_policy_headers_json() {
  local auth_json="$1"
  local base_headers_json

  base_headers_json="$(provider_copilot_base_api_headers_json "$auth_json")" || return 1

  jq -cn \
    --argjson headers "$base_headers_json" \
    '$headers + {
      "openai-intent": "chat-policy",
      "x-interaction-type": "chat-policy"
    }'
}

provider_copilot_enable_model_policy() {
  local auth_json="$1"
  local model="$2"
  local api_base headers_json message encoded_model

  [[ -n "$model" ]] || return 0

  api_base="$(provider_copilot_api_base_from_auth_json "$auth_json")" || return 1
  headers_json="$(provider_copilot_policy_headers_json "$auth_json")" || return 1
  encoded_model="$(jq -rn --arg value "$model" '$value|@uri')" || return 1

  provider_copilot_http_request 'POST' "$(provider_copilot_trim_trailing_slash "$api_base")/models/$encoded_model/policy" "$headers_json" '{"state":"enabled"}' || return 1

  if [[ "$BAISH_COPILOT_HTTP_STATUS" == '200' || "$BAISH_COPILOT_HTTP_STATUS" == '204' ]]; then
    return 0
  fi

  message="$(provider_copilot_extract_error_message "$BAISH_COPILOT_HTTP_BODY")"
  provider_copilot_log_event 'copilot_model_policy_enable_failed' "$(jq -cn \
    --arg model "$model" \
    --arg message "$message" \
    --argjson status_code "${BAISH_COPILOT_HTTP_STATUS:-0}" \
    '{model: $model, status_code: $status_code, message: $message}')"
  return 0
}

provider_copilot_list_models_with_auth_json() {
  local auth_json="$1"
  local api_base headers_json message models_json

  auth_json="$(provider_copilot_auth_json_with_ids "$auth_json")" || return 1
  api_base="$(provider_copilot_api_base_from_auth_json "$auth_json")" || return 1
  headers_json="$(provider_copilot_base_api_headers_json "$auth_json")" || return 1

  provider_copilot_http_request 'GET' "$(provider_copilot_trim_trailing_slash "$api_base")/models" "$headers_json" || return 1

  if [[ "$BAISH_COPILOT_HTTP_STATUS" != '200' ]]; then
    message="$(provider_copilot_extract_error_message "$BAISH_COPILOT_HTTP_BODY")"
    printf 'BAISH Copilot model listing failed (HTTP %s): %s\n' "$BAISH_COPILOT_HTTP_STATUS" "$message" >&2
    return 1
  fi

  models_json="$(provider_copilot_normalize_models_json "$BAISH_COPILOT_HTTP_BODY")" || {
    printf 'BAISH Copilot model listing response was invalid.\n' >&2
    return 1
  }

  printf '%s\n' "$models_json"
}

provider_copilot_list_models() {
  local auth_json

  auth_json="$(provider_copilot_get_active_auth_json)" || return 1
  provider_copilot_list_models_with_auth_json "$auth_json"
}

provider_copilot_model_family() {
  local model="$1"

  case "$model" in
    claude-*)
      printf 'anthropic\n'
      ;;
    gpt-5*)
      printf 'responses\n'
      ;;
    *)
      printf 'chat_completions\n'
      ;;
  esac
}

provider_copilot_build_chat_payload_json() {
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

provider_copilot_build_responses_payload_json() {
  local request_json="$1"

  jq -c '
    def text_message(role; text):
      {role: role, content: [{type: "input_text", text: text}]};

    def assistant_items:
      ((if .content == null then [] else [{role: "assistant", content: [{type: "output_text", text: .content}]}] end)
      + ((.tool_calls // []) | map({
          type: "function_call",
          call_id: .id,
          name: .name,
          arguments: (.arguments | tojson)
        })));

    def message_items:
      if .role == "assistant" then
        assistant_items
      elif .role == "tool" then
        [{
          type: "function_call_output",
          call_id: .tool_call_id,
          output: (.result | tojson)
        }]
      else
        [text_message(.role; .content)]
      end;

    {
      model: .model,
      stream: false,
      store: false,
      tool_choice: "auto",
      parallel_tool_calls: true,
      tools: ((.tools // []) | map({
        type: "function",
        name: .name,
        description: (.description // ""),
        parameters: (.input_schema // {type: "object", properties: {}, additionalProperties: false})
      })),
      input: (
        [
          text_message("system"; .system_prompt),
          text_message("system"; .tool_use_instructions)
        ]
        + ((.skills // []) | map(text_message("system"; ("Loaded skill: " + .name + "\n" + .content))))
        + [((.messages // [])[] | message_items[])]
      )
    }
  ' <<<"$request_json"
}

provider_copilot_build_anthropic_payload_json() {
  local request_json="$1"

  jq -c '
    def system_blocks:
      [
        {type: "text", text: .system_prompt},
        {type: "text", text: .tool_use_instructions}
      ]
      + ((.skills // []) | map({type: "text", text: ("Loaded skill: " + .name + "\n" + .content)}));

    def assistant_content:
      ((if .content == null then [] else [{type: "text", text: .content}] end)
      + ((.tool_calls // []) | map({
          type: "tool_use",
          id: .id,
          name: .name,
          input: .arguments
        })));

    def map_message:
      if .role == "assistant" then
        {role: "assistant", content: assistant_content}
      elif .role == "tool" then
        {
          role: "user",
          content: [{
            type: "tool_result",
            tool_use_id: .tool_call_id,
            content: (.result | tojson)
          }]
        }
      else
        {
          role: .role,
          content: [{type: "text", text: .content}]
        }
      end;

    {
      model: .model,
      stream: false,
      max_tokens: 32000,
      system: system_blocks,
      tools: ((.tools // []) | map({
        name: .name,
        description: (.description // ""),
        input_schema: (.input_schema // {type: "object", properties: {}, additionalProperties: false})
      })),
      messages: ((.messages // []) | map(map_message))
    }
  ' <<<"$request_json"
}

provider_copilot_normalize_chat_response() {
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
            id: (.value.id // ("copilot-call-" + ((.key + 1) | tostring))),
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

provider_copilot_normalize_responses_response() {
  local response_json="$1"

  jq -c '
    def response_output:
      if (.output? | type) == "array" then
        .output
      elif (.response? | .output? | type) == "array" then
        .response.output
      else
        []
      end;

    def response_text:
      (
        [
          response_output[]?
          | if .type == "message" then
              (.content[]? | select((.type // "") == "output_text" or (.type // "") == "text") | (.text // ""))
            elif (.type // "") == "output_text" then
              (.text // "")
            else
              empty
            end
        ]
        | join("")
      )
      | if . == "" then null else . end;

    def response_tool_calls:
      [
        response_output[]?
        | if .type == "function_call" then
            {
              id: (.call_id // .id // "copilot-call-1"),
              name: (.name // ""),
              arguments: ((.arguments // {}) | if type == "string" then fromjson else . end)
            }
          elif .type == "message" then
            (.content[]?
              | select((.type // "") == "function_call")
              | {
                  id: (.call_id // .id // "copilot-call-1"),
                  name: (.name // ""),
                  arguments: ((.arguments // {}) | if type == "string" then fromjson else . end)
                })
          else
            empty
          end
      ];

    {
      assistant_text: response_text,
      tool_calls: response_tool_calls
    }
  ' <<<"$response_json"
}

provider_copilot_normalize_anthropic_response() {
  local response_json="$1"

  jq -c '
    {
      assistant_text: (
        [
          .content[]?
          | select((.type // "") == "text")
          | (.text // "")
        ]
        | join("")
        | if . == "" then null else . end
      ),
      tool_calls: (
        [
          .content[]?
          | select((.type // "") == "tool_use")
          | {
              id: (.id // "copilot-call-1"),
              name: (.name // ""),
              arguments: (.input // {})
            }
        ]
      )
    }
  ' <<<"$response_json"
}

provider_copilot_chat() {
  local request_json="$1"
  local auth_json api_base headers_json payload_json message response_json model family url

  auth_json="$(provider_copilot_get_active_auth_json)" || return 1
  api_base="$(provider_copilot_api_base_from_auth_json "$auth_json")" || return 1
  model="$(jq -r '.model // empty' <<<"$request_json")" || return 1
  family="$(provider_copilot_model_family "$model")" || return 1
  provider_copilot_enable_model_policy "$auth_json" "$model" >/dev/null 2>&1 || true

  case "$family" in
    anthropic)
      headers_json="$(provider_copilot_api_headers_json "$auth_json" "$request_json")" || return 1
      payload_json="$(provider_copilot_build_anthropic_payload_json "$request_json")" || return 1
      url="$(provider_copilot_trim_trailing_slash "$api_base")/v1/messages"
      ;;
    responses)
      headers_json="$(provider_copilot_api_headers_json "$auth_json" "$request_json")" || return 1
      payload_json="$(provider_copilot_build_responses_payload_json "$request_json")" || return 1
      url="$(provider_copilot_trim_trailing_slash "$api_base")/responses"
      ;;
    *)
      headers_json="$(provider_copilot_api_headers_json "$auth_json" "$request_json")" || return 1
      payload_json="$(provider_copilot_build_chat_payload_json "$request_json")" || return 1
      url="$(provider_copilot_trim_trailing_slash "$api_base")/chat/completions"
      ;;
  esac

  if baish_transcript_log_enabled; then
    baish_transcript_log_event "llm_request" "$(jq -cn --arg provider copilot --argjson payload "$payload_json" '{provider: $provider, payload: $payload}')"
  fi

  provider_copilot_http_request 'POST' "$url" "$headers_json" "$payload_json" || return 1

  if [[ "$BAISH_COPILOT_HTTP_STATUS" != '200' ]]; then
    message="$(provider_copilot_extract_error_message "$BAISH_COPILOT_HTTP_BODY")"
    printf 'BAISH Copilot chat request failed (HTTP %s): %s\n' "$BAISH_COPILOT_HTTP_STATUS" "$message" >&2
    return 1
  fi

  case "$family" in
    anthropic)
      if ! jq -e 'type == "object" and (.content | type == "array")' >/dev/null 2>&1 <<<"$BAISH_COPILOT_HTTP_BODY"; then
        printf 'BAISH Copilot chat response was invalid.\n' >&2
        return 1
      fi
      response_json="$(provider_copilot_normalize_anthropic_response "$BAISH_COPILOT_HTTP_BODY")" || {
        printf 'BAISH Copilot chat response could not be normalized.\n' >&2
        return 1
      }
      ;;
    responses)
      if ! jq -e 'type == "object" and ((.output? | type == "array") or (.response? | .output? | type == "array"))' >/dev/null 2>&1 <<<"$BAISH_COPILOT_HTTP_BODY"; then
        printf 'BAISH Copilot chat response was invalid.\n' >&2
        return 1
      fi
      response_json="$(provider_copilot_normalize_responses_response "$BAISH_COPILOT_HTTP_BODY")" || {
        printf 'BAISH Copilot chat response could not be normalized.\n' >&2
        return 1
      }
      ;;
    *)
      if ! jq -e 'type == "object" and (.choices | type == "array" and length > 0) and (.choices[0].message | type == "object")' >/dev/null 2>&1 <<<"$BAISH_COPILOT_HTTP_BODY"; then
        printf 'BAISH Copilot chat response was invalid.\n' >&2
        return 1
      fi
      response_json="$(provider_copilot_normalize_chat_response "$BAISH_COPILOT_HTTP_BODY")" || {
        printf 'BAISH Copilot chat response could not be normalized.\n' >&2
        return 1
      }
      ;;
  esac

  printf '%s\n' "$response_json"
}

# ─── Streaming support ──────────────────────────────────────────────

provider_copilot_has_streaming() {
  local model="${BAISH_ACTIVE_MODEL:-}"
  local family

  if [[ -z "$model" ]]; then
    printf 'false'
    return 0
  fi

  family="$(provider_copilot_model_family "$model")" || { printf 'false'; return 0; }

  case "$family" in
    chat_completions|anthropic)
      printf 'true'
      ;;
    *)
      printf 'false'
      ;;
  esac
}

provider_copilot_http_stream() {
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
provider_copilot_build_chat_payload_stream_json() {
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

# Build streaming payload for Anthropic (stream: true)
provider_copilot_build_anthropic_payload_stream_json() {
  local request_json="$1"

  jq -c '
    def system_blocks:
      [
        {type: "text", text: .system_prompt},
        {type: "text", text: .tool_use_instructions}
      ]
      + ((.skills // []) | map({type: "text", text: ("Loaded skill: " + .name + "\n" + .content)}));

    def assistant_content:
      ((if .content == null then [] else [{type: "text", text: .content}] end)
      + ((.tool_calls // []) | map({
          type: "tool_use",
          id: .id,
          name: .name,
          input: .arguments
        })));

    def map_message:
      if .role == "assistant" then
        {role: "assistant", content: assistant_content}
      elif .role == "tool" then
        {
          role: "user",
          content: [{
            type: "tool_result",
            tool_use_id: .tool_call_id,
            content: (.result | tojson)
          }]
        }
      else
        {
          role: .role,
          content: [{type: "text", text: .content}]
        }
      end;

    {
      model: .model,
      stream: true,
      max_tokens: 32000,
      system: system_blocks,
      tools: ((.tools // []) | map({
        name: .name,
        description: (.description // ""),
        input_schema: (.input_schema // {type: "object", properties: {}, additionalProperties: false})
      })),
      messages: ((.messages // []) | map(map_message))
    }
  ' <<<"$request_json"
}

# SSE parser for OpenAI chat_completions streaming format.
# Reads SSE from stdin, emits BAISH NDJSON events to stdout.
_copilot_parse_sse_chat() {
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

    # Check for finish_reason in the last choice or in usage events
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

# SSE parser for Anthropic messages streaming format.
# Reads SSE from stdin, emits BAISH NDJSON events to stdout.
_copilot_parse_sse_anthropic() {
  local line data_line event_type
  local -a content_block_types=()
  local -a content_block_ids=()
  local -a content_block_names=()
  local -a content_block_args=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == 'data: '* ]]; then
      data_line="${line#data: }"
    elif [[ "$line" == 'data:'* && "$line" != 'data: '* ]]; then
      data_line="${line#data:}"
    else
      continue
    fi

    [[ -z "$data_line" ]] && continue

    event_type="$(jq -r '.type // empty' <<<"$data_line" 2>/dev/null)" || continue

    case "$event_type" in
      content_block_start)
        local index block_type block_id block_name
        index="$(jq -r '.index // 0' <<<"$data_line" 2>/dev/null)" || continue
        block_type="$(jq -r '.content_block.type // empty' <<<"$data_line" 2>/dev/null)" || true
        block_id="$(jq -r '.content_block.id // empty' <<<"$data_line" 2>/dev/null)" || true
        block_name="$(jq -r '.content_block.name // empty' <<<"$data_line" 2>/dev/null)" || true

        content_block_types[$index]="$block_type"
        content_block_ids[$index]="$block_id"
        content_block_names[$index]="$block_name"
        content_block_args[$index]=''
        ;;

      content_block_delta)
        local index delta_type
        index="$(jq -r '.index // 0' <<<"$data_line" 2>/dev/null)" || continue
        delta_type="$(jq -r '.delta.type // empty' <<<"$data_line" 2>/dev/null)" || continue

        case "$delta_type" in
          text_delta)
            local delta_text
            delta_text="$(jq -r '.delta.text // empty' <<<"$data_line" 2>/dev/null)" || continue
            if [[ -n "$delta_text" ]]; then
              local escaped
              escaped="$(printf '%s' "$delta_text" | jq -Rs '.')" || continue
              printf '{"type":"delta","category":"text","content":%s}\n' "$escaped"
            fi
            ;;
          thinking_delta)
            local delta_thinking
            delta_thinking="$(jq -r '.delta.thinking // empty' <<<"$data_line" 2>/dev/null)" || continue
            if [[ -n "$delta_thinking" ]]; then
              local escaped
              escaped="$(printf '%s' "$delta_thinking" | jq -Rs '.')" || continue
              printf '{"type":"delta","category":"thinking","content":%s}\n' "$escaped"
            fi
            ;;
          input_json_delta)
            local delta_partial_json
            delta_partial_json="$(jq -r '.delta.partial_json // empty' <<<"$data_line" 2>/dev/null)" || continue
            if [[ -n "$delta_partial_json" ]]; then
              content_block_args[$index]+="$delta_partial_json"
              local escaped
              escaped="$(printf '%s' "$delta_partial_json" | jq -Rs '.')" || continue
              printf '{"type":"tool_call_delta","index":%s,"tool_call_id":"%s","name":"%s","arguments_delta":%s}\n' \
                "$index" "${content_block_ids[$index]}" "${content_block_names[$index]}" "$escaped"
            fi
            ;;
        esac
        ;;

      message_delta)
        local stop_reason
        stop_reason="$(jq -r '.delta.stop_reason // empty' <<<"$data_line" 2>/dev/null)" || true

        # Emit any pending tool calls with accumulated args
        local i
        for i in "${!content_block_types[@]}"; do
          if [[ "${content_block_types[$i]}" == "tool_use" && -n "${content_block_args[$i]}" && -n "${content_block_ids[$i]}" ]]; then
            local full_args_json
            full_args_json="$(jq -c '.' <<<"${content_block_args[$i]}" 2>/dev/null)" || full_args_json="{}"
            printf '{"type":"tool_call","tool_call_id":"%s","name":"%s","arguments":%s}\n' \
              "${content_block_ids[$i]}" "${content_block_names[$i]}" "$full_args_json"
          fi
        done

        if [[ -n "$stop_reason" && "$stop_reason" != 'null' ]]; then
          local mapped_reason
          case "$stop_reason" in
            end_turn) mapped_reason="stop" ;;
            tool_use) mapped_reason="tool_calls" ;;
            max_tokens) mapped_reason="length" ;;
            stop_sequence) mapped_reason="stop" ;;
            *) mapped_reason="stop" ;;
          esac
          printf '{"type":"done","finish_reason":"%s"}\n' "$mapped_reason"
        fi
        ;;

      message_stop)
        # Fallback final event if no stop_reason was seen
        printf '{"type":"done","finish_reason":"stop"}\n'
        ;;
    esac
  done
}

provider_copilot_chat_stream() {
  local request_json="$1"
  local auth_json api_base model family url headers_json payload_json

  auth_json="$(provider_copilot_get_active_auth_json)" || return 1
  api_base="$(provider_copilot_api_base_from_auth_json "$auth_json")" || return 1
  model="$(jq -r '.model // empty' <<<"$request_json")" || return 1
  family="$(provider_copilot_model_family "$model")" || return 1

  provider_copilot_enable_model_policy "$auth_json" "$model" >/dev/null 2>&1 || true

  case "$family" in
    anthropic)
      headers_json="$(provider_copilot_api_headers_json "$auth_json" "$request_json")" || return 1
      payload_json="$(provider_copilot_build_anthropic_payload_stream_json "$request_json")" || return 1
      url="$(provider_copilot_trim_trailing_slash "$api_base")/v1/messages"
      if baish_transcript_log_enabled; then
        baish_transcript_log_event "llm_request" "$(jq -cn --arg provider copilot --argjson payload "$payload_json" '{provider: $provider, payload: $payload}')"
      fi
      provider_copilot_http_stream 'POST' "$url" "$headers_json" "$payload_json" \
        | _copilot_parse_sse_anthropic
      ;;
    chat_completions)
      headers_json="$(provider_copilot_api_headers_json "$auth_json" "$request_json")" || return 1
      payload_json="$(provider_copilot_build_chat_payload_stream_json "$request_json")" || return 1
      url="$(provider_copilot_trim_trailing_slash "$api_base")/chat/completions"
      if baish_transcript_log_enabled; then
        baish_transcript_log_event "llm_request" "$(jq -cn --arg provider copilot --argjson payload "$payload_json" '{provider: $provider, payload: $payload}')"
      fi
      provider_copilot_http_stream 'POST' "$url" "$headers_json" "$payload_json" \
        | _copilot_parse_sse_chat
      ;;
    *)
      printf '{"type":"error","message":"Streaming not supported for model family: %s"}\n' "$family" >&2
      return 1
      ;;
  esac
}
