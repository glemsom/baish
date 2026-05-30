#!/usr/bin/env bats

load test_helper.bash

setup() {
  REPO_ROOT="$(repo_root)"
  TEST_REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$TEST_REPO/lib/providers"
}

write_provider_file() {
  local name="$1"
  local content="$2"

  cat >"$TEST_REPO/lib/providers/$name.sh" <<EOF
#!/usr/bin/env bash
$content
EOF
}

valid_provider_body() {
  local id="$1"
  local label="$2"
  local desc="$3"
  local selectable="${4:-true}"

  cat <<EOF
provider_${id}_metadata() {
  jq -cn --arg id "$id" --arg provider_label "$label" --arg provider_desc "$desc" --argjson selectable $selectable '{"id": \$id, "label": \$provider_label, "desc": \$provider_desc, "selectable": \$selectable}'
}
provider_${id}_auth() { :; }
provider_${id}_list_models() { printf '[]\n'; }
provider_${id}_chat() { printf '{"assistant_text":null,"tool_calls":[]}\n'; }
provider_${id}_chat_stream() { printf '{"type":"done","finish_reason":"stop"}\n'; }
EOF
}

# Helper: write a minimal valid provider with a custom metadata id
write_provider_with_metadata_id() {
  local filename="$1"
  local metadata_id="$2"
  local label="$3"
  local desc="$4"

  cat >"$TEST_REPO/lib/providers/${filename}.sh" <<BODY
#!/usr/bin/env bash
provider_${filename}_metadata() {
  jq -cn --arg id "$metadata_id" --arg provider_label "$label" --arg provider_desc "$desc" '{"id": \$id, "label": \$provider_label, "desc": \$provider_desc, "selectable": true}'
}
provider_${filename}_auth() { :; }
provider_${filename}_list_models() { printf '[]\n'; }
provider_${filename}_chat() { printf '{"assistant_text":null,"tool_calls":[]}\n'; }
provider_${filename}_chat_stream() { printf '{"type":"done","finish_reason":"stop"}\n'; }
BODY
}

# Helper: write a provider with an empty description
write_provider_with_empty_desc() {
  local filename="$1"

  cat >"$TEST_REPO/lib/providers/${filename}.sh" <<BODY
#!/usr/bin/env bash
provider_${filename}_metadata() {
  jq -cn '{"id":"'"$filename"'","label":"'"$filename"'","desc":"","selectable":true}'
}
provider_${filename}_auth() { :; }
provider_${filename}_list_models() { printf '[]\n'; }
provider_${filename}_chat() { printf '{"assistant_text":null,"tool_calls":[]}\n'; }
provider_${filename}_chat_stream() { printf '{"type":"done","finish_reason":"stop"}\n'; }
BODY
}

run_provider_discover() {
  run bash -lc '
    source "$1/lib/providers.sh"
    BAISH_REPO_ROOT="$2"
    baish_provider_discovery_reset
    baish_provider_discover
    discovery_status=$?
    if (( discovery_status != 0 )); then
      exit "$discovery_status"
    fi
    printf -- "\n--\n"
    for provider_id in "${BAISH_PROVIDER_IDS[@]}"; do
      printf "%s\t%s\n" "$provider_id" "${BAISH_PROVIDER_METADATA_JSON[$provider_id]}"
    done
  ' bash "$REPO_ROOT" "$TEST_REPO"
}

@test "dynamic provider discovery succeeds for valid providers" {
  write_provider_file alpha "$(valid_provider_body alpha Alpha 'Alpha provider')"
  write_provider_file beta "$(valid_provider_body beta Beta 'Beta provider')"

  run_provider_discover

  [ "$status" -eq 0 ]
  [[ "$output" == *$'--\nalpha\t'* ]]
  [[ "$output" == *$'beta\t'* ]]
  [[ "$output" == *'"label":"Alpha"'* ]]
  [[ "$output" == *'"label":"Beta"'* ]]
}

@test "provider discovery fails on duplicate ids" {
  write_provider_file alpha "$(valid_provider_body alpha Alpha 'Alpha provider')"
  write_provider_with_metadata_id beta "alpha" "Beta" "Duplicate provider"

  run_provider_discover

  [ "$status" -ne 0 ]
  [[ "$output" == *'duplicate provider id: alpha'* ]]
}

@test "provider discovery fails on missing metadata" {
  write_provider_file alpha $'provider_alpha_auth() { :; }\nprovider_alpha_list_models() { printf "[]\\n"; }\nprovider_alpha_chat() { printf "{\\"assistant_text\\":null,\\"tool_calls\\":[]}\\n"; }'

  run_provider_discover

  [ "$status" -ne 0 ]
  [[ "$output" == *'missing required action: metadata'* ]]
}

@test "provider discovery fails on empty desc" {
  write_provider_with_empty_desc alpha

  run_provider_discover

  [ "$status" -ne 0 ]
  [[ "$output" == *'returned invalid metadata'* ]]
}

@test "provider discovery fails on missing required provider actions" {
  write_provider_file alpha $'provider_alpha_metadata() { printf "{\\"id\\":\\"alpha\\",\\"desc\\":\\"Alpha provider\\"}\\n"; }\nprovider_alpha_auth() { :; }\nprovider_alpha_chat() { printf "{\\"assistant_text\\":null,\\"tool_calls\\":[]}\\n"; }'

  run_provider_discover

  [ "$status" -ne 0 ]
  [[ "$output" == *'missing required action: list_models'* ]]
}

@test "provider discovery fails on filename id prefix mismatch" {
  write_provider_file beta "$(valid_provider_body alpha Alpha 'Alpha provider')"

  run_provider_discover

  [ "$status" -ne 0 ]
  [[ "$output" == *'filename stem, metadata id, and function prefix to match'* ]]
}

@test "provider discovery fails when zero selectable providers are found" {
  write_provider_file alpha "$(valid_provider_body alpha Alpha 'Alpha provider' false)"

  run_provider_discover

  [ "$status" -ne 0 ]
  [[ "$output" == *'at least one selectable provider'* ]]
}
