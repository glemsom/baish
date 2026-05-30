#!/usr/bin/env bash

baish_log_enabled() {
  [[ "${BAISH_DEBUG:-0}" == "1" ]]
}

baish_log_file() {
  if [[ -n "${BAISH_LOG_FILE:-}" ]]; then
    printf '%s\n' "$BAISH_LOG_FILE"
    return 0
  fi

  local logs_dir timestamp

  logs_dir="$(baish_state_logs_dir)" || return 1
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  printf '%s/%s-%s.jsonl\n' "$logs_dir" "$timestamp" "$$"
}

baish_log_init() {
  if ! baish_log_enabled; then
    return 0
  fi

  local log_file

  mkdir -p -- "$(baish_state_logs_dir)" || return 1
  log_file="$(baish_log_file)" || return 1

  if [[ ! -e "$log_file" ]]; then
    : >"$log_file" || return 1
    chmod 600 "$log_file" || return 1
  fi

  BAISH_LOG_FILE="$log_file"
}

baish_log_sanitize_metadata() {
  local metadata_json="${1-}"
  local sanitized_metadata jq_status

  if [[ -z "$metadata_json" ]]; then
    metadata_json='{}'
  fi

  sanitized_metadata="$(jq -c '
    def scrub_object:
      with_entries(
        if (.key | test("token|authorization|auth_header|secret|password"; "i")) then
          .value = "[REDACTED]"
        elif (.key | test("prompt|response|stdout|stderr|content|transcript|source"; "i")) then
          .value = "[OMITTED]"
        else
          .
        end
      );

    if type != "object" then
      error("metadata must be a JSON object")
    else
      walk(
        if type == "object" then
          scrub_object
        elif type == "string" then
          if length > 500 then
            "[OMITTED_LARGE_STRING]"
          else
            .
          end
        else
          .
        end
      )
    end
  ' <<<"$metadata_json" 2>/dev/null)"
  jq_status=$?

  if [[ $jq_status -ne 0 ]]; then
    return "$jq_status"
  fi

  printf '%s\n' "$sanitized_metadata"
}

baish_log_event() {
  local event="$1"
  local metadata_json="${2-}"
  local sanitized_metadata entry_json

  if [[ -z "$metadata_json" ]]; then
    metadata_json='{}'
  fi

  if ! baish_log_enabled; then
    return 0
  fi

  if [[ -z "$event" ]]; then
    printf 'BAISH log events require an event name.\n' >&2
    return 1
  fi

  baish_log_init || return 1

  if ! sanitized_metadata="$(baish_log_sanitize_metadata "$metadata_json")"; then
    printf 'BAISH log metadata must be a JSON object.\n' >&2
    return 1
  fi

  entry_json="$(jq -cn \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg event "$event" \
    --argjson pid "$$" \
    --argjson metadata "$sanitized_metadata" \
    '{timestamp: $timestamp, pid: $pid, event: $event, metadata: $metadata}')" || return 1

  printf '%s\n' "$entry_json" >>"$BAISH_LOG_FILE"
}

# Transcript logging (opt-in via BAISH_LOG_TRANSCRIPTS=1)
baish_transcript_log_enabled() {
  [[ "${BAISH_LOG_TRANSCRIPTS:-0}" == "1" ]]
}

baish_transcript_logs_dir() {
  local root
  root="$(baish_state_root)" || return 1
  printf '%s/logs/transcripts\n' "$root"
}

baish_transcript_log_file() {
  if [[ -n "${BAISH_TRANSCRIPT_LOG_FILE:-}" ]]; then
    printf '%s\n' "$BAISH_TRANSCRIPT_LOG_FILE"
    return 0
  fi

  local logs_dir timestamp

  logs_dir="$(baish_transcript_logs_dir)" || return 1
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  printf '%s/%s-%s.jsonl\n' "$logs_dir" "$timestamp" "$$"
}

baish_transcript_log_init() {
  if ! baish_transcript_log_enabled; then
    return 0
  fi

  local log_file

  mkdir -p -- "$(baish_transcript_logs_dir)" || return 1
  log_file="$(baish_transcript_log_file)" || return 1

  if [[ ! -e "$log_file" ]]; then
    : >"$log_file" || return 1
    chmod 600 "$log_file" || return 1
  fi

  BAISH_TRANSCRIPT_LOG_FILE="$log_file"
}

baish_transcript_log_event() {
  local event="$1"
  local metadata_json="${2-}"
  local entry_json

  if [[ -z "$metadata_json" ]]; then
    metadata_json='{}'
  fi

  if ! baish_transcript_log_enabled; then
    return 0
  fi

  if [[ -z "$event" ]]; then
    printf 'BAISH transcript events require an event name.\n' >&2
    return 1
  fi

  baish_transcript_log_init || return 1

  # No sanitization for transcripts - log raw metadata
  entry_json="$(jq -cn \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg event "$event" \
    --argjson pid "$$" \
    --argjson metadata "$metadata_json" \
    '{timestamp: $timestamp, pid: $pid, event: $event, metadata: $metadata}')" || return 1

  printf '%s\n' "$entry_json" >>"$BAISH_TRANSCRIPT_LOG_FILE"
}
