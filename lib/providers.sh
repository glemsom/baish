#!/usr/bin/env bash

baish_provider_discovery_reset() {
  declare -ga BAISH_PROVIDER_IDS=()
  declare -gA BAISH_PROVIDER_METADATA_JSON=()
  BAISH_PROVIDER_DISCOVERY_DONE=0
}

baish_provider_discovery_init() {
  if [[ -z "${BAISH_PROVIDER_DISCOVERY_DONE:-}" ]]; then
    baish_provider_discovery_reset
  fi
}

baish_provider_discovery_list_files() {
  local providers_dir="${BAISH_REPO_ROOT:-}/lib/providers"
  local nullglob_was_set=0
  local path
  local -a provider_files=()

  if [[ -z "${BAISH_REPO_ROOT:-}" ]]; then
    printf 'BAISH provider discovery requires BAISH_REPO_ROOT to be set.\n' >&2
    return 1
  fi

  if [[ ! -d "$providers_dir" ]]; then
    printf 'BAISH provider discovery could not find %s\n' "$providers_dir" >&2
    return 1
  fi

  if shopt -q nullglob; then
    nullglob_was_set=1
  fi
  shopt -s nullglob

  for path in "$providers_dir"/*.sh; do
    provider_files+=("$path")
  done

  if (( nullglob_was_set == 0 )); then
    shopt -u nullglob
  fi

  if (( ${#provider_files[@]} == 0 )); then
    printf 'BAISH provider discovery found no provider files in %s\n' "$providers_dir" >&2
    return 1
  fi

  printf '%s\n' "${provider_files[@]}" | sort
}

baish_provider_metadata_normalize() {
  local provider_id="$1"
  local metadata_json="$2"

  if ! jq -e '
    type == "object"
    and (.id? | type == "string" and length > 0)
    and (.desc? | type == "string" and length > 0)
    and ((.label? == null) or (.label | type == "string" and length > 0))
    and ((.selectable? == null) or (.selectable | type == "boolean"))
  ' >/dev/null 2>&1 <<<"$metadata_json"; then
    printf 'BAISH provider %s returned invalid metadata. Required fields: id, desc.\n' "$provider_id" >&2
    return 1
  fi

  if [[ "$(jq -r '.id' <<<"$metadata_json")" != "$provider_id" ]]; then
    printf 'BAISH provider discovery requires metadata id to match filename/function prefix: %s\n' "$provider_id" >&2
    return 1
  fi

  jq -cn \
    --argjson metadata "$metadata_json" \
    --arg provider_id "$provider_id" \
    '
      $metadata
      + {
          "id": $provider_id,
          "label": (if ($metadata | has("label")) then $metadata.label else $provider_id end),
          "selectable": (if ($metadata | has("selectable")) then $metadata.selectable else true end)
        }
    '
}

baish_provider_discovery_validate_required_actions() {
  local provider_id="$1"
  local action function_name
  local -a required_actions=(metadata auth list_models chat)

  for action in "${required_actions[@]}"; do
    function_name="provider_${provider_id}_${action}"
    if ! declare -F "$function_name" >/dev/null 2>&1; then
      printf 'BAISH provider %s is missing required action: %s\n' "$provider_id" "$action" >&2
      return 1
    fi
  done
}

baish_provider_discovery_load_file() {
  local path="$1"
  local stem before_file after_file provider_functions_raw provider_ids_raw provider_id metadata_function metadata_json normalized_json metadata_declared_id
  local -a provider_functions=() provider_ids=()

  stem="${path##*/}"
  stem="${stem%.sh}"

  before_file="$(mktemp)" || return 1
  after_file="$(mktemp)" || {
    rm -f -- "$before_file"
    return 1
  }

  declare -F | awk '{print $3}' | sort >"$before_file"

  # shellcheck source=/dev/null
  if ! source "$path"; then
    rm -f -- "$before_file" "$after_file"
    printf 'BAISH provider discovery failed while sourcing %s\n' "$path" >&2
    return 1
  fi

  declare -F | awk '{print $3}' | sort >"$after_file"
  provider_functions_raw="$(comm -13 "$before_file" "$after_file" | grep '^provider_' || true)"
  rm -f -- "$before_file" "$after_file"

  if [[ -z "$provider_functions_raw" ]]; then
    printf 'BAISH provider file must define exactly one provider: %s\n' "$path" >&2
    return 1
  fi

  while IFS= read -r provider_function; do
    [[ -z "$provider_function" ]] && continue
    provider_functions+=("$provider_function")
  done <<<"$provider_functions_raw"

  provider_ids_raw="$(printf '%s\n' "${provider_functions[@]}" | sed -n 's/^provider_\([^_][^_]*\)_.*/\1/p' | sort -u)"
  while IFS= read -r provider_id; do
    [[ -z "$provider_id" ]] && continue
    provider_ids+=("$provider_id")
  done <<<"$provider_ids_raw"

  if (( ${#provider_ids[@]} != 1 )); then
    printf 'BAISH provider file must define exactly one provider: %s\n' "$path" >&2
    return 1
  fi

  provider_id="${provider_ids[0]}"
  if [[ "$provider_id" != "$stem" ]]; then
    printf 'BAISH provider discovery requires filename stem, metadata id, and function prefix to match: %s\n' "$path" >&2
    return 1
  fi

  if printf '%s\n' "${provider_functions[@]}" | grep -Evq "^provider_${provider_id}_"; then
    printf 'BAISH provider file may only define provider_%s_* functions: %s\n' "$provider_id" "$path" >&2
    return 1
  fi

  baish_provider_discovery_validate_required_actions "$provider_id" || return 1

  metadata_function="provider_${provider_id}_metadata"
  if ! metadata_json="$($metadata_function)"; then
    printf 'BAISH provider %s metadata function failed.\n' "$provider_id" >&2
    return 1
  fi

  metadata_declared_id="$(jq -r '.id // empty' <<<"$metadata_json" 2>/dev/null || true)"
  if [[ -n "$metadata_declared_id" && -n "${BAISH_PROVIDER_METADATA_JSON[$metadata_declared_id]+x}" ]]; then
    printf 'BAISH provider discovery found duplicate provider id: %s\n' "$metadata_declared_id" >&2
    return 1
  fi

  if [[ -n "${BAISH_PROVIDER_METADATA_JSON[$provider_id]+x}" ]]; then
    printf 'BAISH provider discovery found duplicate provider id: %s\n' "$provider_id" >&2
    return 1
  fi

  normalized_json="$(baish_provider_metadata_normalize "$provider_id" "$metadata_json")" || return 1

  BAISH_PROVIDER_IDS+=("$provider_id")
  BAISH_PROVIDER_METADATA_JSON["$provider_id"]="$normalized_json"
}

baish_provider_discover() {
  local path selectable_count=0 metadata_json

  baish_provider_discovery_init
  if [[ "${BAISH_PROVIDER_DISCOVERY_DONE:-0}" == '1' ]]; then
    return 0
  fi

  baish_provider_discovery_reset
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    baish_provider_discovery_load_file "$path" || return 1
  done < <(baish_provider_discovery_list_files)

  for path in "${BAISH_PROVIDER_IDS[@]}"; do
    metadata_json="${BAISH_PROVIDER_METADATA_JSON[$path]}"
    if [[ "$(jq -r '.selectable' <<<"$metadata_json")" == 'true' ]]; then
      selectable_count=$(( selectable_count + 1 ))
    fi
  done

  if (( selectable_count == 0 )); then
    printf 'BAISH provider discovery requires at least one selectable provider.\n' >&2
    return 1
  fi

  BAISH_PROVIDER_DISCOVERY_DONE=1
}

baish_provider_metadata_json() {
  local provider_id="$1"

  baish_provider_discover || return 1

  if [[ -z "$provider_id" || -z "${BAISH_PROVIDER_METADATA_JSON[$provider_id]+x}" ]]; then
    printf 'BAISH does not know provider: %s\n' "$provider_id" >&2
    return 1
  fi

  printf '%s\n' "${BAISH_PROVIDER_METADATA_JSON[$provider_id]}"
}

baish_provider_all_metadata_json() {
  local provider_id
  local -a metadata_entries=()

  baish_provider_discover || return 1

  for provider_id in "${BAISH_PROVIDER_IDS[@]}"; do
    metadata_entries+=("${BAISH_PROVIDER_METADATA_JSON[$provider_id]}")
  done

  if (( ${#metadata_entries[@]} == 0 )); then
    printf '[]\n'
    return 0
  fi

  printf '%s\n' "${metadata_entries[@]}" | jq -s '.'
}

baish_provider_has_env_auth() {
  local provider="$1"
  local function_name="provider_${provider}_has_env_auth"

  if declare -F "$function_name" >/dev/null 2>&1; then
    "$function_name"
    return $?
  fi

  return 1
}
