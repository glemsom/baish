#!/usr/bin/env bats

load test_helper.bash

setup() {
  REPO_ROOT="$(repo_root)"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  TEST_PROJECT="$BATS_TEST_TMPDIR/project"

  mkdir -p "$TEST_HOME" "$TEST_PROJECT"
  cd "$TEST_PROJECT"

  source "$REPO_ROOT/lib/tools.sh"

  HOME="$TEST_HOME"
  BAISH_LAUNCH_CWD="$TEST_PROJECT"
  BAISH_BASH_TIMEOUT=1
}

@test "read returns the full file" {
  printf 'alpha\nbeta\n' >"$TEST_PROJECT/file.txt"

  run baish_tool_read_json "$(jq -cn --arg path "$TEST_PROJECT/file.txt" '{path: $path}')"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.ok' <<<"$output")" = 'true' ]
  [ "$(jq -r '.data.content' <<<"$output")" = $'alpha\nbeta' ]
  [ "$(jq -r '.data.offset' <<<"$output")" = '1' ]
  [ "$(jq -r '.data.limit' <<<"$output")" = 'null' ]
  [ "$(jq -r '.data.line_count' <<<"$output")" = '2' ]
}

@test "read returns a line range" {
  printf 'one\ntwo\nthree\n' >"$TEST_PROJECT/range.txt"

  run baish_tool_read_json "$(jq -cn --arg path "$TEST_PROJECT/range.txt" '{path: $path, offset: 2, limit: 1}')"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.data.content' <<<"$output")" = 'two' ]
  [ "$(jq -r '.data.offset' <<<"$output")" = '2' ]
  [ "$(jq -r '.data.limit' <<<"$output")" = '1' ]
  [ "$(jq -r '.data.line_count' <<<"$output")" = '1' ]
}

@test "read treats limit zero as read-to-end" {
  printf 'one\ntwo\nthree\n' >"$TEST_PROJECT/read-to-end.txt"

  run baish_tool_read_json "$(jq -cn --arg path "$TEST_PROJECT/read-to-end.txt" '{path: $path, offset: 2, limit: 0}')"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.data.content' <<<"$output")" = $'two\nthree' ]
  [ "$(jq -r '.data.offset' <<<"$output")" = '2' ]
  [ "$(jq -r '.data.limit' <<<"$output")" = '0' ]
  [ "$(jq -r '.data.line_count' <<<"$output")" = '2' ]
}

@test "read rejects directories and binary files" {
  mkdir -p "$TEST_PROJECT/dir"
  printf 'text\0binary' >"$TEST_PROJECT/binary.bin"

  run baish_tool_read_json "$(jq -cn --arg path "$TEST_PROJECT/dir" '{path: $path}')"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ok' <<<"$output")" = 'false' ]
  [ "$(jq -r '.error.code' <<<"$output")" = 'is_directory' ]

  run baish_tool_read_json "$(jq -cn --arg path "$TEST_PROJECT/binary.bin" '{path: $path}')"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ok' <<<"$output")" = 'false' ]
  [ "$(jq -r '.error.code' <<<"$output")" = 'binary_unsupported' ]
}

@test "write creates parent directories and overwrites entire files" {
  run baish_tool_write_json "$(jq -cn --arg path "$TEST_PROJECT/nested/out.txt" --arg content 'first version' '{path: $path, content: $content}')"

  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/nested/out.txt" ]
  [ "$(cat "$TEST_PROJECT/nested/out.txt")" = 'first version' ]
  [ "$(jq -r '.data.created' <<<"$output")" = 'true' ]
  [ "$(jq -r '.data.overwritten' <<<"$output")" = 'false' ]

  run baish_tool_write_json "$(jq -cn --arg path "$TEST_PROJECT/nested/out.txt" --arg content 'second' '{path: $path, content: $content}')"

  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_PROJECT/nested/out.txt")" = 'second' ]
  [ "$(jq -r '.data.created' <<<"$output")" = 'false' ]
  [ "$(jq -r '.data.overwritten' <<<"$output")" = 'true' ]
}

@test "edit succeeds with a unique exact match and batch applies replacements" {
  printf 'hello world\ncolor=red\n' >"$TEST_PROJECT/edit.txt"

  run baish_tool_edit_json "$(jq -cn --arg path "$TEST_PROJECT/edit.txt" '{path: $path, edits: [{oldText: "hello world", newText: "hello bash"}, {oldText: "color=red", newText: "color=blue"}]}')"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.ok' <<<"$output")" = 'true' ]
  [ "$(cat "$TEST_PROJECT/edit.txt")" = $'hello bash\ncolor=blue' ]
  [ "$(jq -r '.data.replacements' <<<"$output")" = '2' ]
}

@test "edit fails when oldText is missing or duplicated and leaves file unchanged" {
  printf 'repeat\nrepeat\n' >"$TEST_PROJECT/duplicate.txt"

  run baish_tool_edit_json "$(jq -cn --arg path "$TEST_PROJECT/duplicate.txt" '{path: $path, edits: [{oldText: "missing", newText: "new"}]}')"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ok' <<<"$output")" = 'false' ]
  [ "$(jq -r '.error.code' <<<"$output")" = 'old_text_not_found' ]
  [ "$(cat "$TEST_PROJECT/duplicate.txt")" = $'repeat\nrepeat' ]

  run baish_tool_edit_json "$(jq -cn --arg path "$TEST_PROJECT/duplicate.txt" '{path: $path, edits: [{oldText: "repeat", newText: "once"}]}')"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ok' <<<"$output")" = 'false' ]
  [ "$(jq -r '.error.code' <<<"$output")" = 'old_text_not_unique' ]
  [ "$(cat "$TEST_PROJECT/duplicate.txt")" = $'repeat\nrepeat' ]
}

@test "edit batch is atomic when one replacement fails" {
  printf 'alpha\nbeta\n' >"$TEST_PROJECT/atomic-edit.txt"

  run baish_tool_edit_json "$(jq -cn --arg path "$TEST_PROJECT/atomic-edit.txt" '{path: $path, edits: [{oldText: "alpha", newText: "ALPHA"}, {oldText: "missing", newText: "MISSING"}]}')"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.ok' <<<"$output")" = 'false' ]
  [ "$(cat "$TEST_PROJECT/atomic-edit.txt")" = $'alpha\nbeta' ]
}

@test "bash captures stdout stderr and exit code" {
  run baish_tool_bash_json "$(jq -cn '{command: "printf stdout; printf stderr >&2; exit 7"}')"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.ok' <<<"$output")" = 'true' ]
  [ "$(jq -r '.data.stdout' <<<"$output")" = 'stdout' ]
  [ "$(jq -r '.data.stderr' <<<"$output")" = 'stderr' ]
  [ "$(jq -r '.data.exit_code' <<<"$output")" = '7' ]
  [ "$(jq -r '.data.timed_out' <<<"$output")" = 'false' ]
}

@test "bash merges per-call env and runs from the launch directory" {
  mkdir -p "$TEST_PROJECT/subdir"
  cd "$TEST_PROJECT/subdir"

  run baish_tool_bash_json "$(jq -cn --arg root "$TEST_PROJECT" '{command: "printf \"%s|%s\" \"$PWD\" \"$DEMO_VALUE\"", env: {DEMO_VALUE: "visible"}}')"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.data.stdout' <<<"$output")" = "$TEST_PROJECT|visible" ]
}

@test "bash timeout returns exit code 124 and timed_out true" {
  run baish_tool_bash_json "$(jq -cn '{command: "sleep 2"}')"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.ok' <<<"$output")" = 'true' ]
  [ "$(jq -r '.data.exit_code' <<<"$output")" = '124' ]
  [ "$(jq -r '.data.timed_out' <<<"$output")" = 'true' ]
}
