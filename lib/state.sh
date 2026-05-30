#!/usr/bin/env bash

baish_state_root() {
  if [[ -z "${HOME:-}" ]]; then
    printf 'BAISH requires HOME to determine its state directory.\n' >&2
    return 1
  fi

  printf '%s/.baish\n' "$HOME"
}

baish_state_auth_dir() {
  local root
  root="$(baish_state_root)" || return 1
  printf '%s/auth\n' "$root"
}

baish_state_logs_dir() {
  local root
  root="$(baish_state_root)" || return 1
  printf '%s/logs\n' "$root"
}

baish_state_skills_dir() {
  local root
  root="$(baish_state_root)" || return 1
  printf '%s/skills\n' "$root"
}

baish_state_file() {
  local root
  root="$(baish_state_root)" || return 1
  printf '%s/state.json\n' "$root"
}

baish_state_auth_file() {
  local provider="$1"
  local auth_dir

  if [[ -z "$provider" ]]; then
    printf 'BAISH requires a provider name for auth state.\n' >&2
    return 1
  fi

  auth_dir="$(baish_state_auth_dir)" || return 1
  printf '%s/%s.json\n' "$auth_dir" "$provider"
}

baish_state_init() {
  local root auth_dir skills_dir

  root="$(baish_state_root)" || return 1
  auth_dir="$(baish_state_auth_dir)" || return 1
  skills_dir="$(baish_state_skills_dir)" || return 1

  mkdir -p -- "$root" "$auth_dir" "$skills_dir" || return 1

  if [[ "${BAISH_DEBUG:-0}" == "1" ]]; then
    mkdir -p -- "$(baish_state_logs_dir)" || return 1
  fi
}

baish_state_read_json_file() {
  local path="$1"
  local json

  if [[ ! -f "$path" ]]; then
    printf '{}\n'
    return 0
  fi

  if ! json="$(jq -c '.' "$path" 2>/dev/null)"; then
    printf 'BAISH state file is not valid JSON: %s\n' "$path" >&2
    return 1
  fi

  printf '%s\n' "$json"
}

baish_state_write_json_file() {
  local path="$1"
  local json="$2"
  local mode="${3:-600}"
  local directory normalized_json temp_file

  directory="$(dirname -- "$path")"
  mkdir -p -- "$directory" || return 1

  if ! normalized_json="$(printf '%s' "$json" | jq '.' 2>/dev/null)"; then
    printf 'BAISH cannot write invalid JSON to %s\n' "$path" >&2
    return 1
  fi

  temp_file="$(mktemp "$directory/.baish.tmp.XXXXXX")" || return 1

  if ! printf '%s\n' "$normalized_json" >"$temp_file"; then
    rm -f -- "$temp_file"
    return 1
  fi

  if ! chmod "$mode" "$temp_file"; then
    rm -f -- "$temp_file"
    return 1
  fi

  if ! mv -f -- "$temp_file" "$path"; then
    rm -f -- "$temp_file"
    return 1
  fi
}

baish_state_get_string_field() {
  local path="$1"
  local field="$2"
  local json

  json="$(baish_state_read_json_file "$path")" || return 1
  jq -r --arg field "$field" '.[$field] // "" | if type == "string" then . else "" end' <<<"$json"
}

baish_state_selected_provider() {
  baish_state_get_string_field "$(baish_state_file)" 'selected_provider'
}

baish_state_selected_model() {
  baish_state_get_string_field "$(baish_state_file)" 'selected_model'
}

baish_state_set_selected_provider() {
  local provider="$1"
  local current_json next_json

  current_json="$(baish_state_read_json_file "$(baish_state_file)")" || return 1
  next_json="$(jq -cn --argjson current "$current_json" --arg provider "$provider" '$current + {selected_provider: $provider}')" || return 1
  baish_state_write_json_file "$(baish_state_file)" "$next_json" 600
}

baish_state_set_selected_model() {
  local model="$1"
  local current_json next_json

  current_json="$(baish_state_read_json_file "$(baish_state_file)")" || return 1
  next_json="$(jq -cn --argjson current "$current_json" --arg model "$model" '$current + {selected_model: $model}')" || return 1
  baish_state_write_json_file "$(baish_state_file)" "$next_json" 600
}

baish_state_set_selected_provider_model() {
  local provider="$1"
  local model="$2"
  local current_json next_json

  current_json="$(baish_state_read_json_file "$(baish_state_file)")" || return 1
  next_json="$(jq -cn --argjson current "$current_json" --arg provider "$provider" --arg model "$model" '$current + {selected_provider: $provider, selected_model: $model}')" || return 1
  baish_state_write_json_file "$(baish_state_file)" "$next_json" 600
}

baish_state_write_auth_json() {
  local provider="$1"
  local auth_json="$2"

  baish_state_write_json_file "$(baish_state_auth_file "$provider")" "$auth_json" 600
}

baish_state_read_auth_json() {
  baish_state_read_json_file "$(baish_state_auth_file "$1")"
}

baish_state_set_process_active_provider_model() {
  local provider="$1"
  local model="$2"

  BAISH_PROCESS_SELECTED_PROVIDER="$provider"
  BAISH_PROCESS_SELECTED_MODEL="$model"
  BAISH_ACTIVE_PROVIDER="$provider"
  BAISH_ACTIVE_MODEL="$model"
}

baish_config_active_provider() {
  if [[ -n "${BAISH_PROCESS_SELECTED_PROVIDER:-}" ]]; then
    printf '%s\n' "$BAISH_PROCESS_SELECTED_PROVIDER"
    return 0
  fi

  if [[ -n "${BAISH_PROVIDER:-}" ]]; then
    printf '%s\n' "$BAISH_PROVIDER"
    return 0
  fi

  local selected_provider
  selected_provider="$(baish_state_selected_provider)" || return 1
  if [[ -n "$selected_provider" ]]; then
    printf '%s\n' "$selected_provider"
    return 0
  fi

  printf 'copilot\n'
}

baish_config_active_model() {
  if [[ -n "${BAISH_PROCESS_SELECTED_MODEL:-}" ]]; then
    printf '%s\n' "$BAISH_PROCESS_SELECTED_MODEL"
    return 0
  fi

  if [[ -n "${BAISH_MODEL:-}" ]]; then
    printf '%s\n' "$BAISH_MODEL"
    return 0
  fi

  baish_state_selected_model
}
