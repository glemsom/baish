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

baish_session_reset_context_window() {
  declare -ga BAISH_SESSION_MESSAGES=()
  printf 'Started new chat.\n'
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
    /provider)
      BAISH_SLASH_TOKEN_COMMAND='provider'
      return 0
      ;;
    /provider:*)
      BAISH_SLASH_TOKEN_ERROR='BAISH does not support /provider:<name>. Use /provider to open the provider picker.'
      return 1
      ;;
    /quit|/exit)
      BAISH_SLASH_TOKEN_COMMAND='quit'
      return 0
      ;;
    /new)
      BAISH_SLASH_TOKEN_COMMAND='new'
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

baish_text_is_blank() {
  local text="$1"

  [[ -z "$text" || "$text" =~ ^[[:space:]]+$ ]]
}

baish_slash_split_token_separator() {
  local input="$1"
  local length index separator_start char

  BAISH_SLASH_SPLIT_TOKEN=''
  BAISH_SLASH_SPLIT_SEPARATOR=''
  BAISH_SLASH_SPLIT_REST=''

  length="${#input}"
  index=0

  while (( index < length )); do
    char="${input:index:1}"
    if [[ "$char" =~ [[:space:]] ]]; then
      break
    fi
    ((index += 1))
  done

  BAISH_SLASH_SPLIT_TOKEN="${input:0:index}"
  separator_start=$index

  while (( index < length )); do
    char="${input:index:1}"
    if [[ ! "$char" =~ [[:space:]] ]]; then
      break
    fi
    ((index += 1))
  done

  BAISH_SLASH_SPLIT_SEPARATOR="${input:separator_start:index-separator_start}"
  BAISH_SLASH_SPLIT_REST="${input:index}"
}

baish_slash_parse_line() {
  local input="$1"
  local rest token separator

  baish_slash_parse_reset
  rest="$input"

  while [[ "$rest" == /* ]]; do
    baish_slash_split_token_separator "$rest"
    token="$BAISH_SLASH_SPLIT_TOKEN"
    separator="$BAISH_SLASH_SPLIT_SEPARATOR"
    rest="$BAISH_SLASH_SPLIT_REST"

    if ! baish_slash_parse_token "$token"; then
      BAISH_SLASH_PARSE_ERROR="$BAISH_SLASH_TOKEN_ERROR"
      return 1
    fi

    BAISH_SLASH_COMMANDS+=("$BAISH_SLASH_TOKEN_COMMAND")
    BAISH_SLASH_ARGS+=("$BAISH_SLASH_TOKEN_ARG")

    if [[ -z "$separator" ]]; then
      BAISH_SLASH_REMAINING_TEXT=''
      return 0
    fi

    if baish_text_is_blank "$rest"; then
      BAISH_SLASH_REMAINING_TEXT=''
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
    if baish_text_is_blank "$rest"; then
      return 0
    fi

    if [[ "$rest" != /* ]]; then
      return 1
    fi

    baish_slash_split_token_separator "$rest"
    token="$BAISH_SLASH_SPLIT_TOKEN"
    separator="$BAISH_SLASH_SPLIT_SEPARATOR"
    rest="$BAISH_SLASH_SPLIT_REST"

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

baish_provider_selection_entries() {
  local active_provider="$1"
  local metadata_json

  metadata_json="$(baish_provider_all_metadata_json)" || return 1
  jq -r --arg active_provider "$active_provider" '
    map(select(.selectable == true))
    | sort_by((.label // .id) | ascii_downcase)
    | .[]
    | [
        ((.label // .id) + " — " + .desc + (if .id == $active_provider then " (active)" else "" end)),
        .id
      ]
    | @tsv
  ' <<<"$metadata_json"
}

baish_provider_select_interactive() {
  local active_provider entries selection fzf_status selected_provider

  active_provider="$(baish_config_active_provider 2>/dev/null || true)"
  entries="$(baish_provider_selection_entries "$active_provider")" || return 1

  if [[ -z "$entries" ]]; then
    printf 'BAISH provider picker does not have any selectable providers.\n' >&2
    return 1
  fi

  fzf_status=0
  selection="$(printf '%s\n' "$entries" | fzf --prompt='provider> ' --with-nth=1 --delimiter=$'\t')" || fzf_status=$?
  if [[ $fzf_status -ne 0 ]]; then
    printf 'Provider selection cancelled.\n' >&2
    return "$fzf_status"
  fi

  selected_provider="${selection#*$'\t'}"
  if [[ "$selected_provider" == "$selection" || -z "$selected_provider" ]]; then
    selected_provider="$selection"
  fi

  printf '%s\n' "$selected_provider"
}

baish_model_pick_interactive() {
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

  printf '%s\n' "$selected_model"
}

baish_model_select_interactive() {
  local provider="${1:-}"
  local selected_model

  if [[ -z "$provider" ]]; then
    provider="$(baish_config_active_provider)" || return 1
  fi

  selected_model="$(baish_model_pick_interactive "$provider")" || return 1
  baish_state_set_selected_provider_model "$provider" "$selected_model" || return 1
  baish_state_set_process_active_provider_model "$provider" "$selected_model" || return 1
  printf 'Selected model: %s\n' "$selected_model"
}

baish_provider_requires_validation() {
  local provider="$1"
  declare -F "provider_${provider}_validate_selection" >/dev/null 2>&1
}

baish_provider_validate_selection() {
  local provider="$1"
  local model="$2"

  if baish_provider_requires_validation "$provider"; then
    baish_provider_call "$provider" validate_selection "$model"
    return $?
  fi

  return 0
}

baish_provider_setup_healthy() {
  local provider="$1"
  local model="$2"
  local auth_file

  if [[ -z "$provider" || -z "$model" ]]; then
    return 1
  fi

  if baish_provider_has_env_auth "$provider"; then
    return 0
  fi

  auth_file="$(baish_state_auth_file "$provider")" || return 1
  [[ -f "$auth_file" ]]
}

baish_reconfigure_apply_selection() {
  local provider="$1"
  local model="$2"
  local previous_provider="$3"
  local previous_model="$4"
  local healthy_before="$5"
  local reset_chat="${6:-0}"

  baish_state_set_selected_provider_model "$provider" "$model" || return 1
  baish_state_set_process_active_provider_model "$provider" "$model" || return 1

  if [[ "$provider" == "$previous_provider" && "$model" == "$previous_model" && "$healthy_before" == '1' ]]; then
    return 10
  fi

  if [[ "$reset_chat" == '1' ]]; then
    baish_session_reset_context_window >/dev/null || return 1
    printf 'Started new chat.\n'
  fi

  return 0
}

baish_reconfigure_choose_model() {
  local provider="$1"
  local selected_model validation_status

  while true; do
    selected_model="$(baish_model_pick_interactive "$provider")" || return 1
    baish_provider_validate_selection "$provider" "$selected_model"
    validation_status=$?
    case "$validation_status" in
      0)
        printf '%s\n' "$selected_model"
        return 0
        ;;
      3)
        continue
        ;;
      *)
        return "$validation_status"
        ;;
    esac
  done
}

baish_connect_provider_interactive() {
  local provider="$1"
  local reset_chat="${2:-0}"
  local previous_provider previous_model healthy_before=0 selected_model apply_status

  previous_provider="$(baish_config_active_provider 2>/dev/null || true)"
  previous_model="$(baish_config_active_model 2>/dev/null || true)"
  if baish_provider_setup_healthy "$previous_provider" "$previous_model"; then
    healthy_before=1
  fi

  baish_provider_call "$provider" auth || return 1
  selected_model="$(baish_reconfigure_choose_model "$provider")" || return 1

  baish_reconfigure_apply_selection "$provider" "$selected_model" "$previous_provider" "$previous_model" "$healthy_before" "$reset_chat"
  apply_status=$?
  if [[ "$apply_status" != '0' && "$apply_status" != '10' ]]; then
    return "$apply_status"
  fi

  printf 'Selected model: %s\n' "$selected_model"
  printf 'Connected provider: %s\n' "$provider"

  return "$apply_status"
}

baish_connect_current_provider() {
  local provider status

  provider="$(baish_config_active_provider)" || return 1
  baish_connect_provider_interactive "$provider" 0
  status=$?
  if [[ "$status" == '10' ]]; then
    return 0
  fi
  return "$status"
}

baish_slash_connect_current_provider() {
  local provider status

  provider="$(baish_config_active_provider)" || return 1
  baish_connect_provider_interactive "$provider" 1
  status=$?
  if [[ "$status" == '10' ]]; then
    return 0
  fi
  return "$status"
}

baish_slash_model_select_interactive() {
  local provider previous_provider previous_model healthy_before=0 selected_model status

  provider="$(baish_config_active_provider)" || return 1
  previous_provider="$(baish_config_active_provider 2>/dev/null || true)"
  previous_model="$(baish_config_active_model 2>/dev/null || true)"
  if baish_provider_setup_healthy "$previous_provider" "$previous_model"; then
    healthy_before=1
  fi

  baish_provider_call "$provider" auth || return 1
  selected_model="$(baish_reconfigure_choose_model "$provider")" || return 1
  baish_reconfigure_apply_selection "$provider" "$selected_model" "$previous_provider" "$previous_model" "$healthy_before" 1
  status=$?
  if [[ "$status" != '0' && "$status" != '10' ]]; then
    return "$status"
  fi

  printf 'Selected model: %s\n' "$selected_model"
  if [[ "$status" == '10' ]]; then
    return 0
  fi
  return "$status"
}

baish_slash_select_provider() {
  local previous_provider previous_model healthy_before=0 selected_provider status

  selected_provider="$(baish_provider_select_interactive)" || return $?
  previous_provider="$(baish_config_active_provider 2>/dev/null || true)"
  previous_model="$(baish_config_active_model 2>/dev/null || true)"

  if baish_provider_setup_healthy "$previous_provider" "$previous_model"; then
    healthy_before=1
  fi

  if [[ "$selected_provider" == "$previous_provider" && "$healthy_before" == '1' ]]; then
    printf 'Active provider unchanged: %s\n' "$selected_provider"
    return 0
  fi

  baish_connect_provider_interactive "$selected_provider" 1
  status=$?
  if [[ "$status" != '0' && "$status" != '10' ]]; then
    return "$status"
  fi

  printf 'Selected provider: %s\n' "$selected_provider"
  if [[ "$status" == '10' ]]; then
    return 0
  fi
  return "$status"
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
  local -a command_candidates=(/connect /provider /quit /exit /new /model /skill:)

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
      baish_slash_connect_current_provider
      ;;
    provider)
      baish_slash_select_provider
      ;;
    quit)
      BAISH_SESSION_EXIT_REQUESTED=1
      return 0
      ;;
    new)
      baish_session_reset_context_window
      ;;
    model)
      baish_slash_model_select_interactive
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

  if baish_text_is_blank "$line"; then
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

  if ! baish_text_is_blank "$BAISH_SLASH_REMAINING_TEXT"; then
    baish_agent_run_user_message "$BAISH_SLASH_REMAINING_TEXT"
  fi
}
