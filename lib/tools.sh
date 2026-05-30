#!/usr/bin/env bash

baish_tool_success_json() {
  local tool="$1"
  local data_json="$2"

  jq -cn --arg tool "$tool" --argjson data "$data_json" '{ok: true, tool: $tool, data: $data}'
}

baish_tool_error_json() {
  local tool="$1"
  local code="$2"
  local message="$3"

  jq -cn --arg tool "$tool" --arg code "$code" --arg message "$message" '{ok: false, tool: $tool, error: {code: $code, message: $message}}'
}

baish_tool_file_is_text() {
  local path="$1"

  if [[ ! -s "$path" ]]; then
    return 0
  fi

  LC_ALL=C grep -Iq . "$path"
}

baish_tool_json_string_file() {
  local path="$1"

  jq -Rs '.' <"$path"
}

baish_tool_file_line_count() {
  local path="$1"

  awk 'END { print NR + 0 }' "$path"
}

baish_tool_atomic_write_json_string() {
  local path="$1"
  local content_json="$2"
  local directory temp_file bytes existing_mode

  directory="$(dirname -- "$path")"
  mkdir -p -- "$directory" || return 1

  temp_file="$(mktemp "$directory/.baish.tmp.XXXXXX")" || return 1

  if ! printf '%s' "$content_json" | jq -jre 'if type == "string" then . else error("content must be a string") end' >"$temp_file"; then
    rm -f -- "$temp_file"
    return 1
  fi

  if [[ -e "$path" && ! -d "$path" ]]; then
    existing_mode="$(stat -c '%a' "$path" 2>/dev/null || true)"
    if [[ -n "$existing_mode" ]]; then
      chmod "$existing_mode" "$temp_file" || {
        rm -f -- "$temp_file"
        return 1
      }
    fi
  fi

  bytes="$(wc -c <"$temp_file")"
  bytes="${bytes//[[:space:]]/}"

  if ! mv -f -- "$temp_file" "$path"; then
    rm -f -- "$temp_file"
    return 1
  fi

  printf '%s\n' "$bytes"
}

baish_tool_read_json() {
  local request_json="$1"
  local path offset limit end_line content_json line_count data_json

  if ! jq -e '
    type == "object"
    and (.path? | type == "string" and length > 0)
    and ((.offset? == null) or (.offset | type == "number" and floor == . and . >= 1))
    and ((.limit? == null) or (.limit | type == "number" and floor == . and . >= 0))
  ' >/dev/null 2>&1 <<<"$request_json"; then
    baish_tool_error_json 'read' 'invalid_request' 'read requires {path:string, offset?:integer>=1, limit?:integer>=0}.'
    return 0
  fi

  path="$(jq -r '.path' <<<"$request_json")" || return 1
  offset="$(jq -r 'if .offset == null then 1 else (.offset | floor) end' <<<"$request_json")" || return 1
  limit="$(jq -r 'if .limit == null then "" else (.limit | floor | tostring) end' <<<"$request_json")" || return 1

  if [[ ! -e "$path" ]]; then
    baish_tool_error_json 'read' 'not_found' "File not found: $path"
    return 0
  fi

  if [[ -d "$path" ]]; then
    baish_tool_error_json 'read' 'is_directory' "Path is a directory: $path"
    return 0
  fi

  if [[ ! -f "$path" ]]; then
    baish_tool_error_json 'read' 'not_a_file' "Path is not a regular file: $path"
    return 0
  fi

  if ! baish_tool_file_is_text "$path"; then
    baish_tool_error_json 'read' 'binary_unsupported' "binary file not supported: $path"
    return 0
  fi

  if [[ -n "$limit" ]]; then
    if (( limit == 0 )); then
      content_json="$(sed -n "${offset},\$p" -- "$path" | jq -Rs '.')" || return 1
      line_count="$(sed -n "${offset},\$p" -- "$path" | awk 'END { print NR + 0 }')" || return 1
    else
      end_line=$(( offset + limit - 1 ))
      content_json="$(sed -n "${offset},${end_line}p" -- "$path" | jq -Rs '.')" || return 1
      line_count="$(sed -n "${offset},${end_line}p" -- "$path" | awk 'END { print NR + 0 }')" || return 1
    fi
  else
    content_json="$(baish_tool_json_string_file "$path")" || return 1
    line_count="$(baish_tool_file_line_count "$path")" || return 1
  fi

  data_json="$(jq -cn \
    --arg path "$path" \
    --argjson content "$content_json" \
    --argjson offset "$offset" \
    --argjson limit "${limit:-null}" \
    --argjson line_count "$line_count" \
    '{path: $path, content: $content, offset: $offset, limit: $limit, line_count: $line_count}')" || return 1

  baish_tool_success_json 'read' "$data_json"
}

baish_tool_write_json() {
  local request_json="$1"
  local path content_json existed bytes data_json

  if ! jq -e '
    type == "object"
    and (.path? | type == "string" and length > 0)
    and (.content? | type == "string")
  ' >/dev/null 2>&1 <<<"$request_json"; then
    baish_tool_error_json 'write' 'invalid_request' 'write requires {path:string, content:string}.'
    return 0
  fi

  path="$(jq -r '.path' <<<"$request_json")" || return 1
  content_json="$(jq -c '.content' <<<"$request_json")" || return 1

  if [[ -d "$path" ]]; then
    baish_tool_error_json 'write' 'is_directory' "Path is a directory: $path"
    return 0
  fi

  if [[ -e "$path" ]]; then
    existed=1
  else
    existed=0
  fi

  bytes="$(baish_tool_atomic_write_json_string "$path" "$content_json")" || return 1

  data_json="$(jq -cn \
    --arg path "$path" \
    --argjson created "$(if (( existed == 0 )); then printf 'true'; else printf 'false'; fi)" \
    --argjson overwritten "$(if (( existed == 1 )); then printf 'true'; else printf 'false'; fi)" \
    --argjson bytes "$bytes" \
    '{path: $path, created: $created, overwritten: $overwritten, bytes: $bytes}')" || return 1

  baish_tool_success_json 'write' "$data_json"
}

baish_tool_edit_plan_json() {
  local request_json="$1"
  local original_content_json="$2"

  jq -cn \
    --argjson request "$request_json" \
    --argjson original "$original_content_json" \
    '
      def invalid($code; $message):
        {valid: false, code: $code, message: $message};

      def apply_replacements($text; $ranges):
        reduce ($ranges | sort_by(.start) | reverse[]) as $range
          ($text; .[:$range.start] + $range.newText + .[$range.end:]);

      if ($request | type) != "object" then
        invalid("invalid_request"; "edit requires {path:string, edits:[{oldText,newText}, ...]}.")
      elif (($request.path? | type) != "string") or (($request.path | length) == 0) then
        invalid("invalid_request"; "edit requires a non-empty string path.")
      elif (($request.edits? | type) != "array") then
        invalid("invalid_request"; "edit requires an edits array.")
      elif (($request.edits | length) == 0) then
        invalid("invalid_request"; "edit requires at least one replacement.")
      else
        ($request.edits | to_entries | map(
          .key as $index
          | .value as $edit
          | if ($edit | type) != "object" then
              invalid("invalid_request"; "edit entry \($index) must be an object.")
            elif (($edit.oldText? | type) != "string") then
              invalid("invalid_request"; "edit entry \($index) requires string oldText.")
            elif (($edit.newText? | type) != "string") then
              invalid("invalid_request"; "edit entry \($index) requires string newText.")
            elif (($edit.oldText | length) == 0) then
              invalid("invalid_request"; "edit entry \($index) oldText must not be empty.")
            else
              {
                valid: true,
                index: $index,
                oldText: $edit.oldText,
                newText: $edit.newText,
                starts: ($original | indices($edit.oldText))
              }
            end
        )) as $entries
        | if any($entries[]; .valid == false) then
            first($entries[] | select(.valid == false))
          else
            ($entries | map(
              if (.starts | length) == 0 then
                invalid("old_text_not_found"; "edit entry \(.index) oldText was not found exactly once.")
              elif (.starts | length) > 1 then
                invalid("old_text_not_unique"; "edit entry \(.index) oldText must appear exactly once.")
              else
                {
                  valid: true,
                  index: .index,
                  oldText: .oldText,
                  newText: .newText,
                  start: .starts[0],
                  end: (.starts[0] + (.oldText | length))
                }
              end
            )) as $located
            | if any($located[]; .valid == false) then
                first($located[] | select(.valid == false))
              else
                ($located | sort_by(.start)) as $sorted
                | reduce $sorted[] as $item
                    ({valid: true, previous_end: 0};
                     if (.valid | not) then
                       .
                     elif $item.start < .previous_end then
                       {valid: false, code: "overlapping_edits", message: "edit replacements overlap in the original file."}
                     else
                       .previous_end = $item.end
                     end)
                | if .valid == false then
                    .
                  else
                    {
                      valid: true,
                      replacements: ($sorted | length),
                      content: apply_replacements($original; $sorted)
                    }
                  end
              end
          end
      end
    '
}

baish_tool_edit_json() {
  local request_json="$1"
  local path original_content_json plan_json bytes replacements data_json

  if ! jq -e '
    type == "object"
    and (.path? | type == "string" and length > 0)
    and (.edits? | type == "array")
  ' >/dev/null 2>&1 <<<"$request_json"; then
    baish_tool_error_json 'edit' 'invalid_request' 'edit requires {path:string, edits:[{oldText,newText}, ...]}.'
    return 0
  fi

  path="$(jq -r '.path' <<<"$request_json")" || return 1

  if [[ ! -e "$path" ]]; then
    baish_tool_error_json 'edit' 'not_found' "File not found: $path"
    return 0
  fi

  if [[ -d "$path" ]]; then
    baish_tool_error_json 'edit' 'is_directory' "Path is a directory: $path"
    return 0
  fi

  if [[ ! -f "$path" ]]; then
    baish_tool_error_json 'edit' 'not_a_file' "Path is not a regular file: $path"
    return 0
  fi

  if ! baish_tool_file_is_text "$path"; then
    baish_tool_error_json 'edit' 'binary_unsupported' "binary file not supported: $path"
    return 0
  fi

  original_content_json="$(baish_tool_json_string_file "$path")" || return 1
  plan_json="$(baish_tool_edit_plan_json "$request_json" "$original_content_json")" || return 1

  if [[ "$(jq -r '.valid' <<<"$plan_json")" != 'true' ]]; then
    baish_tool_error_json 'edit' "$(jq -r '.code' <<<"$plan_json")" "$(jq -r '.message' <<<"$plan_json")"
    return 0
  fi

  replacements="$(jq -r '.replacements' <<<"$plan_json")" || return 1
  bytes="$(baish_tool_atomic_write_json_string "$path" "$(jq -c '.content' <<<"$plan_json")")" || return 1

  data_json="$(jq -cn \
    --arg path "$path" \
    --argjson replacements "$replacements" \
    --argjson bytes "$bytes" \
    '{path: $path, replacements: $replacements, bytes: $bytes}')" || return 1

  baish_tool_success_json 'edit' "$data_json"
}

baish_tool_bash_json() {
  local request_json="$1"
  local command workdir timeout_seconds stdout_file stderr_file exit_code timed_out data_json
  local -a env_args=()

  if ! jq -e '
    type == "object"
    and (.command? | type == "string")
    and ((.env? == null) or (.env | type == "object" and all(to_entries[]; (.key | test("^[A-Za-z_][A-Za-z0-9_]*$")) and (.value | type == "string"))))
  ' >/dev/null 2>&1 <<<"$request_json"; then
    baish_tool_error_json 'bash' 'invalid_request' 'bash requires {command:string, env?:object<string,string>}.'
    return 0
  fi

  command="$(jq -r '.command' <<<"$request_json")" || return 1
  timeout_seconds="${BAISH_BASH_TIMEOUT:-120}"
  if [[ ! "$timeout_seconds" =~ ^[0-9]+$ ]] || (( timeout_seconds <= 0 )); then
    timeout_seconds=120
  fi

  workdir="${BAISH_LAUNCH_CWD:-$PWD}"

  while IFS= read -r entry_json; do
    [[ -z "$entry_json" ]] && continue
    env_args+=("$(jq -r '.key + "=" + .value' <<<"$entry_json")")
  done < <(jq -c '.env // {} | to_entries[]' <<<"$request_json")

  stdout_file="$(mktemp)" || return 1
  stderr_file="$(mktemp)" || {
    rm -f -- "$stdout_file"
    return 1
  }

  if timeout --signal=TERM --kill-after=5s "${timeout_seconds}s" env "${env_args[@]}" bash -lc "cd -- $(printf '%q' "$workdir") && /usr/local/bin/rtk $command" >"$stdout_file" 2>"$stderr_file"; then
    exit_code=0
    timed_out=false
  else
    exit_code=$?
    if [[ "$exit_code" == '124' ]]; then
      timed_out=true
    else
      timed_out=false
    fi
  fi

  data_json="$(jq -cn \
    --arg command "$command" \
    --argjson exit_code "$exit_code" \
    --argjson timed_out "$timed_out" \
    --rawfile stdout "$stdout_file" \
    --rawfile stderr "$stderr_file" \
    '{command: $command, exit_code: $exit_code, timed_out: $timed_out, stdout: $stdout, stderr: $stderr}')" || {
      rm -f -- "$stdout_file" "$stderr_file"
      return 1
    }

  rm -f -- "$stdout_file" "$stderr_file"

  baish_tool_success_json 'bash' "$data_json"
}

baish_tool_execute_json() {
  local tool_name="$1"
  local request_json="$2"

  case "$tool_name" in
    read)
      baish_tool_read_json "$request_json"
      ;;
    write)
      baish_tool_write_json "$request_json"
      ;;
    edit)
      baish_tool_edit_json "$request_json"
      ;;
    bash)
      baish_tool_bash_json "$request_json"
      ;;
    *)
      baish_tool_error_json "$tool_name" 'unsupported_tool' "Unsupported tool: $tool_name"
      ;;
  esac
}
