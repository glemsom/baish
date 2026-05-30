#!/usr/bin/env bash

baish_footer_terminal_width() {
  local columns="${COLUMNS:-}"

  if [[ "$columns" =~ ^[0-9]+$ ]] && (( columns > 0 )); then
    printf '%s\n' "$columns"
    return 0
  fi

  printf '80\n'
}

baish_footer_home_shorten_path() {
  local path="$1"

  if [[ -z "$path" ]]; then
    printf '\n'
    return 0
  fi

  if [[ -n "${HOME:-}" && "$path" == "$HOME" ]]; then
    printf '~\n'
    return 0
  fi

  if [[ -n "${HOME:-}" && "$path" == "$HOME/"* ]]; then
    printf '~/%s\n' "${path#"$HOME"/}"
    return 0
  fi

  printf '%s\n' "$path"
}

baish_footer_launch_directory_text() {
  if [[ -z "${BAISH_LAUNCH_CWD:-}" ]]; then
    printf '?\n'
    return 0
  fi

  baish_footer_home_shorten_path "$BAISH_LAUNCH_CWD"
}

baish_footer_refresh_active_state() {
  if [[ -n "${BAISH_PROCESS_SELECTED_PROVIDER:-}" ]]; then
    BAISH_ACTIVE_PROVIDER="$BAISH_PROCESS_SELECTED_PROVIDER"
  elif [[ -n "${BAISH_PROVIDER:-}" ]]; then
    BAISH_ACTIVE_PROVIDER="$BAISH_PROVIDER"
  fi

  if [[ "${BAISH_PROCESS_SELECTED_MODEL+x}" == 'x' ]]; then
    BAISH_ACTIVE_MODEL="${BAISH_PROCESS_SELECTED_MODEL}"
  elif [[ "${BAISH_MODEL+x}" == 'x' ]]; then
    BAISH_ACTIVE_MODEL="${BAISH_MODEL}"
  fi

  return 0
}

baish_footer_provider_label_text() {
  local provider_id="${BAISH_ACTIVE_PROVIDER:-}"
  local metadata_json label

  if [[ -z "$provider_id" ]]; then
    printf 'unknown provider\n'
    return 0
  fi

  if ! metadata_json="$(baish_provider_metadata_json "$provider_id" 2>/dev/null)"; then
    printf 'unknown provider\n'
    return 0
  fi

  label="$(jq -r '.label // "" | if type == "string" then . else "" end' <<<"$metadata_json" 2>/dev/null)"
  if [[ -z "$label" ]]; then
    printf 'unknown provider\n'
    return 0
  fi

  printf '%s\n' "$label"
}

baish_footer_model_text() {
  if [[ -z "${BAISH_ACTIVE_MODEL:-}" ]]; then
    printf 'no model\n'
    return 0
  fi

  printf '%s\n' "$BAISH_ACTIVE_MODEL"
}

baish_footer_clip_line() {
  local LC_ALL='C.UTF-8'
  local text="$1"
  local width="${2:-$(baish_footer_terminal_width)}"

  if ! [[ "$width" =~ ^[0-9]+$ ]]; then
    width="$(baish_footer_terminal_width)"
  fi

  if (( width <= 0 )); then
    printf '\n'
    return 0
  fi

  if (( ${#text} <= width )); then
    printf '%s\n' "$text"
    return 0
  fi

  if (( width == 1 )); then
    printf '…\n'
    return 0
  fi

  printf '%s…\n' "${text:0:width-1}"
}

baish_footer_truncate_text() {
  local text="$1"
  local width="$2"

  if ! [[ "$width" =~ ^[0-9]+$ ]]; then
    printf '\n'
    return 0
  fi

  baish_footer_clip_line "$text" "$width"
}

baish_footer_divider_line() {
  local width="${1:-$(baish_footer_terminal_width)}"
  local divider=''
  local index

  if ! [[ "$width" =~ ^[0-9]+$ ]]; then
    width="$(baish_footer_terminal_width)"
  fi

  for (( index = 0; index < width; index++ )); do
    divider+='─'
  done

  printf '%s\n' "$divider"
}

baish_footer_fallback_divider_line() {
  local width="${1:-80}"
  local divider=''
  local index

  if ! [[ "$width" =~ ^[0-9]+$ ]] || (( width < 0 )); then
    width=80
  fi

  for (( index = 0; index < width; index++ )); do
    divider+='─'
  done

  printf '%s\n' "$divider"
}

baish_footer_fallback_status_line() {
  local width="${1:-80}"

  if ! [[ "$width" =~ ^[0-9]+$ ]]; then
    width=80
  fi

  baish_footer_clip_line '? · unknown provider · no model' "$width"
}

baish_footer_format_status_line() {
  local LC_ALL='C.UTF-8'
  local width="${1:-$(baish_footer_terminal_width)}"
  local launch_dir provider_label model_id separator

  baish_footer_refresh_active_state
  local launch_dir_width provider_label_width model_id_width
  local total_width overflow reducible reduction status_line

  if ! [[ "$width" =~ ^[0-9]+$ ]]; then
    width="$(baish_footer_terminal_width)"
  fi

  if (( width <= 0 )); then
    printf '\n'
    return 0
  fi

  launch_dir="$(baish_footer_launch_directory_text)"
  provider_label="$(baish_footer_provider_label_text)"
  model_id="$(baish_footer_model_text)"
  separator=' · '

  launch_dir_width=${#launch_dir}
  provider_label_width=${#provider_label}
  model_id_width=${#model_id}
  total_width=$(( launch_dir_width + provider_label_width + model_id_width + (${#separator} * 2) ))
  overflow=$(( total_width - width ))

  if (( overflow > 0 )); then
    reducible=$(( launch_dir_width - 1 ))
    if (( reducible > 0 )); then
      reduction=$(( overflow < reducible ? overflow : reducible ))
      launch_dir_width=$(( launch_dir_width - reduction ))
      overflow=$(( overflow - reduction ))
    fi
  fi

  if (( overflow > 0 )); then
    reducible=$(( model_id_width - 1 ))
    if (( reducible > 0 )); then
      reduction=$(( overflow < reducible ? overflow : reducible ))
      model_id_width=$(( model_id_width - reduction ))
      overflow=$(( overflow - reduction ))
    fi
  fi

  if (( overflow > 0 )); then
    reducible=$(( provider_label_width - 1 ))
    if (( reducible > 0 )); then
      reduction=$(( overflow < reducible ? overflow : reducible ))
      provider_label_width=$(( provider_label_width - reduction ))
    fi
  fi

  launch_dir="$(baish_footer_truncate_text "$launch_dir" "$launch_dir_width")"
  provider_label="$(baish_footer_truncate_text "$provider_label" "$provider_label_width")"
  model_id="$(baish_footer_truncate_text "$model_id" "$model_id_width")"
  status_line="${launch_dir}${separator}${provider_label}${separator}${model_id}"

  baish_footer_clip_line "$status_line" "$width"
}

baish_footer_render_lines() {
  local width divider_line status_line

  width="$(baish_footer_terminal_width 2>/dev/null)"
  if ! [[ "$width" =~ ^[0-9]+$ ]] || (( width <= 0 )); then
    width=80
  fi

  if ! divider_line="$(baish_footer_divider_line "$width" 2>/dev/null)"; then
    divider_line="$(baish_footer_fallback_divider_line "$width")"
  fi

  if ! status_line="$(baish_footer_format_status_line "$width" 2>/dev/null)"; then
    status_line="$(baish_footer_fallback_status_line "$width")"
  fi

  printf '%s\n' "$divider_line"
  printf '%s\n' "$status_line"
}
