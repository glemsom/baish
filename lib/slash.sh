#!/usr/bin/env bash

baish_session_reset() {
  declare -ga BAISH_SESSION_SKILL_NAMES=()
  declare -ga BAISH_SESSION_SKILL_PATHS=()
  declare -ga BAISH_SESSION_SKILL_CONTENTS=()
  declare -gA BAISH_SESSION_SKILL_INDEX=()
  declare -ga BAISH_SESSION_MESSAGES=()

  BAISH_SESSION_EXIT_REQUESTED=0
  BAISH_SESSION_INITIALIZED=1
}

baish_session_init() {
  if [[ -z "${BAISH_SESSION_INITIALIZED:-}" ]]; then
    baish_session_reset
  fi
}

baish_slash_parse_reset() {
  declare -ga BAISH_SLASH_COMMANDS=()
  declare -ga BAISH_SLASH_ARGS=()

  BAISH_SLASH_REMAINING_TEXT=''
  BAISH_SLASH_PARSE_ERROR=''
  BAISH_SLASH_TOKEN_COMMAND=''
  BAISH_SLASH_TOKEN_ARG=''
  BAISH_SLASH_TOKEN_ERROR=''
}

baish_slash_parse_token() {
  local token="$1"
  local skill_name

  BAISH_SLASH_TOKEN_COMMAND=''
  BAISH_SLASH_TOKEN_ARG=''
  BAISH_SLASH_TOKEN_ERROR=''

  case "$token" in
    /connect)
      BAISH_SLASH_TOKEN_COMMAND='connect'
      return 0
      ;;
    /quit|/exit)
      BAISH_SLASH_TOKEN_COMMAND='quit'
      return 0
      ;;
    /model)
      BAISH_SLASH_TOKEN_COMMAND='model'
      return 0
      ;;
    /skill:*)
      skill_name="${token#/skill:}"
      if [[ -z "$skill_name" ]]; then
        BAISH_SLASH_TOKEN_ERROR='BAISH requires a skill name for /skill:<skill>.'
        return 1
      fi
      BAISH_SLASH_TOKEN_COMMAND='skill'
      BAISH_SLASH_TOKEN_ARG="$skill_name"
      return 0
      ;;
    *)
      BAISH_SLASH_TOKEN_ERROR="Unknown slash command: $token"
      return 1
      ;;
  esac
}

baish_slash_parse_line() {
  local input="$1"
  local rest token separator

  baish_slash_parse_reset
  rest="$input"

  while [[ "$rest" == /* ]]; do
    token="$rest"
    separator=''
    rest=''

    if [[ "$token" =~ ^([^[:space:]]+)([[:space:]]*)(.*)$ ]]; then
      token="${BASH_REMATCH[1]}"
      separator="${BASH_REMATCH[2]}"
      rest="${BASH_REMATCH[3]}"
    fi

    if ! baish_slash_parse_token "$token"; then
      BAISH_SLASH_PARSE_ERROR="$BAISH_SLASH_TOKEN_ERROR"
      return 1
    fi

    BAISH_SLASH_COMMANDS+=("$BAISH_SLASH_TOKEN_COMMAND")
    BAISH_SLASH_ARGS+=("$BAISH_SLASH_TOKEN_ARG")

    if [[ -z "$separator" ]]; then
      BAISH_SLASH_REMAINING_TEXT="$rest"
      return 0
    fi

    if [[ "$rest" != /* ]]; then
      BAISH_SLASH_REMAINING_TEXT="$rest"
      return 0
    fi
  done

  BAISH_SLASH_REMAINING_TEXT="$rest"
}

baish_slash_prefix_is_command_sequence() {
  local prefix="$1"
  local rest token separator

  rest="$prefix"

  while true; do
    if [[ -z "$rest" || "$rest" =~ ^[[:space:]]+$ ]]; then
      return 0
    fi

    if [[ "$rest" != /* ]]; then
      return 1
    fi

    token="$rest"
    separator=''
    rest=''

    if [[ "$token" =~ ^([^[:space:]]+)([[:space:]]*)(.*)$ ]]; then
      token="${BASH_REMATCH[1]}"
      separator="${BASH_REMATCH[2]}"
      rest="${BASH_REMATCH[3]}"
    fi

    baish_slash_parse_token "$token" >/dev/null 2>&1 || return 1

    if [[ -z "$separator" ]]; then
      if [[ -z "$rest" ]]; then
        return 0
      fi
      return 1
    fi
  done
}

baish_provider_call() {
  local provider="$1"
  local action="$2"
  local function_name

  shift 2

  if [[ -z "$provider" || -z "$action" ]]; then
    printf 'BAISH provider dispatch requires provider and action.\n' >&2
    return 1
  fi

  function_name="provider_${provider}_${action}"

  if ! declare -F "$function_name" >/dev/null 2>&1; then
    printf 'BAISH provider does not support %s: %s\n' "$action" "$provider" >&2
    return 1
  fi

  "$function_name" "$@"
}

baish_provider_list_models_json() {
  local provider="$1"
  local models_json

  models_json="$(baish_provider_call "$provider" list_models)" || return 1

  if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$models_json"; then
    printf 'BAISH provider %s returned invalid model data.\n' "$provider" >&2
    return 1
  fi

  printf '%s\n' "$models_json"
}

baish_provider_models_to_tsv() {
  local models_json="$1"

  jq -r '
    if type != "array" then
      error("models must be an array")
    else
      .[]
      | if type == "string" then
          [., .]
        elif type == "object" then
          [
            (.label // .display_name // .name // .id // .model // (. | tostring)),
            (.id // .name // .model // .label // empty)
          ]
        else
          error("unsupported model entry")
        end
      | select(.[1] != null and .[1] != "")
      | @tsv
    end
  ' <<<"$models_json"
}

baish_model_select_interactive() {
  local provider="${1:-}"
  local models_json entries selection fzf_status selected_model

  if [[ -z "$provider" ]]; then
    provider="$(baish_config_active_provider)" || return 1
  fi

  models_json="$(baish_provider_list_models_json "$provider")" || return 1
  entries="$(baish_provider_models_to_tsv "$models_json")" || return 1

  if [[ -z "$entries" ]]; then
    printf 'BAISH provider %s did not return any selectable models.\n' "$provider" >&2
    return 1
  fi

  fzf_status=0
  selection="$(printf '%s\n' "$entries" | fzf --prompt='model> ' --with-nth=1 --delimiter=$'\t')" || fzf_status=$?
  if [[ $fzf_status -ne 0 ]]; then
    printf 'Model selection cancelled.\n' >&2
    return "$fzf_status"
  fi

  selected_model="${selection#*$'\t'}"
  if [[ "$selected_model" == "$selection" || -z "$selected_model" ]]; then
    selected_model="$selection"
  fi

  baish_state_set_selected_provider_model "$provider" "$selected_model" || return 1

  BAISH_ACTIVE_PROVIDER="$provider"
  if [[ -n "${BAISH_MODEL:-}" ]]; then
    BAISH_ACTIVE_MODEL="$BAISH_MODEL"
    printf 'Persisted model set to %s for provider %s; BAISH_MODEL keeps %s active in this process.\n' "$selected_model" "$provider" "$BAISH_MODEL"
  else
    BAISH_ACTIVE_MODEL="$selected_model"
    printf 'Selected model: %s\n' "$selected_model"
  fi
}

baish_connect_current_provider() {
  local provider

  provider="$(baish_config_active_provider)" || return 1
  baish_provider_call "$provider" auth || return 1
  baish_model_select_interactive "$provider" || return 1
  printf 'Connected provider: %s\n' "$provider"
}

baish_skill_project_path() {
  local skill_name="$1"
  printf '%s/.baish/skills/%s.md\n' "$PWD" "$skill_name"
}

baish_skill_user_path() {
  local skill_name="$1"
  local skills_dir

  skills_dir="$(baish_state_skills_dir)" || return 1
  printf '%s/%s.md\n' "$skills_dir" "$skill_name"
}

baish_skill_resolve_path() {
  local skill_name="$1"
  local project_path user_path

  project_path="$(baish_skill_project_path "$skill_name")"
  if [[ -f "$project_path" ]]; then
    printf '%s\n' "$project_path"
    return 0
  fi

  user_path="$(baish_skill_user_path "$skill_name")" || return 1
  if [[ -f "$user_path" ]]; then
    printf '%s\n' "$user_path"
    return 0
  fi

  printf 'BAISH could not find skill: %s\n' "$skill_name" >&2
  return 1
}

baish_skill_list_available() {
  local project_dir user_dir path skill_name nullglob_was_set=0
  declare -A seen=()

  baish_session_init

  if shopt -q nullglob; then
    nullglob_was_set=1
  fi
  shopt -s nullglob

  project_dir="$PWD/.baish/skills"
  for path in "$project_dir"/*.md; do
    skill_name="${path##*/}"
    skill_name="${skill_name%.md}"
    if [[ -n "$skill_name" && -z "${seen[$skill_name]+x}" ]]; then
      seen["$skill_name"]=1
      printf '%s\n' "$skill_name"
    fi
  done

  user_dir="$(baish_state_skills_dir)" || {
    if (( nullglob_was_set == 0 )); then
      shopt -u nullglob
    fi
    return 1
  }
  for path in "$user_dir"/*.md; do
    skill_name="${path##*/}"
    skill_name="${skill_name%.md}"
    if [[ -n "$skill_name" && -z "${seen[$skill_name]+x}" ]]; then
      seen["$skill_name"]=1
      printf '%s\n' "$skill_name"
    fi
  done

  if (( nullglob_was_set == 0 )); then
    shopt -u nullglob
  fi
}

baish_skill_load() {
  local skill_name="$1"
  local skill_path skill_content skill_index

  baish_session_init

  if [[ -z "$skill_name" ]]; then
    printf 'BAISH requires a skill name for /skill:<skill>.\n' >&2
    return 1
  fi

  if [[ -n "${BAISH_SESSION_SKILL_INDEX[$skill_name]+x}" ]]; then
    printf 'Skill already loaded: %s\n' "$skill_name"
    return 0
  fi

  skill_path="$(baish_skill_resolve_path "$skill_name")" || return 1
  skill_content="$(<"$skill_path")" || return 1
  skill_index="${#BAISH_SESSION_SKILL_NAMES[@]}"

  BAISH_SESSION_SKILL_NAMES+=("$skill_name")
  BAISH_SESSION_SKILL_PATHS+=("$skill_path")
  BAISH_SESSION_SKILL_CONTENTS+=("$skill_content")
  BAISH_SESSION_SKILL_INDEX["$skill_name"]="$skill_index"

  printf 'Loaded skill: %s\n' "$skill_name"
}

baish_slash_completion_candidates() {
  local line="$1"
  local point="${2:-${#1}}"
  local before_cursor current_token prefix_context skill_name
  local -a command_candidates=(/connect /quit /exit /model /skill:)

  before_cursor="${line:0:point}"

  if [[ "$before_cursor" =~ (^|[[:space:]])([^[:space:]]*)$ ]]; then
    current_token="${BASH_REMATCH[2]}"
  else
    current_token="$before_cursor"
  fi

  prefix_context="${before_cursor:0:${#before_cursor}-${#current_token}}"

  if [[ -z "$current_token" || "$current_token" != /* ]]; then
    return 0
  fi

  if ! baish_slash_prefix_is_command_sequence "$prefix_context"; then
    return 0
  fi

  if [[ "$current_token" == /skill:* ]]; then
    while IFS= read -r skill_name; do
      if [[ "/skill:$skill_name" == "$current_token"* ]]; then
        printf '/skill:%s\n' "$skill_name"
      fi
    done < <(baish_skill_list_available)
    return 0
  fi

  for skill_name in "${command_candidates[@]}"; do
    if [[ "$skill_name" == "$current_token"* ]]; then
      printf '%s\n' "$skill_name"
    fi
  done
}

baish_slash_execute_command() {
  local command="$1"
  local argument="${2-}"

  case "$command" in
    connect)
      baish_connect_current_provider
      ;;
    quit)
      BAISH_SESSION_EXIT_REQUESTED=1
      return 0
      ;;
    model)
      baish_model_select_interactive
      ;;
    skill)
      baish_skill_load "$argument"
      ;;
    *)
      printf 'BAISH cannot execute unsupported slash command: %s\n' "$command" >&2
      return 1
      ;;
  esac
}

baish_slash_execute_commands() {
  local index

  baish_session_init

  for index in "${!BAISH_SLASH_COMMANDS[@]}"; do
    baish_slash_execute_command "${BAISH_SLASH_COMMANDS[$index]}" "${BAISH_SLASH_ARGS[$index]}" || return $?
    if [[ "${BAISH_SESSION_EXIT_REQUESTED:-0}" == "1" ]]; then
      return 0
    fi
  done
}

baish_process_input_line() {
  local line="$1"

  baish_session_init

  if [[ -z "$line" || "$line" =~ ^[[:space:]]+$ ]]; then
    return 0
  fi

  if ! baish_slash_parse_line "$line"; then
    printf '%s\n' "$BAISH_SLASH_PARSE_ERROR" >&2
    return 1
  fi

  baish_slash_execute_commands || return $?

  if [[ "${BAISH_SESSION_EXIT_REQUESTED:-0}" == "1" ]]; then
    return 0
  fi

  if [[ -n "$BAISH_SLASH_REMAINING_TEXT" ]]; then
    printf 'user> %s\n' "$BAISH_SLASH_REMAINING_TEXT"
    baish_agent_run_user_message "$BAISH_SLASH_REMAINING_TEXT"
  fi
}
