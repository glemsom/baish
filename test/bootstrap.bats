#!/usr/bin/env bats

load test_helper.bash

setup() {
  REPO_ROOT="$(repo_root)"
}

@test "launcher fails fast with a clear dependency list" {
  stub_bin="$BATS_TEST_TMPDIR/missing-bin"
  mkdir -p "$stub_bin"
  ln -s /usr/bin/bash "$stub_bin/bash"
  ln -s /usr/bin/uname "$stub_bin/uname"

  run env PATH="$stub_bin" "$REPO_ROOT/bin/baish"

  [ "$status" -eq 1 ]
  [[ "$output" == *"BAISH cannot start because required runtime dependencies are missing or unsupported:"* ]]
  [[ "$output" == *"GNU coreutils (checked via mktemp)"* ]]
  [[ "$output" == *"GNU sed"* ]]
  [[ "$output" == *"GNU awk/gawk"* ]]
  [[ "$output" == *"GNU grep"* ]]
  [[ "$output" == *"curl"* ]]
  [[ "$output" == *"jq"* ]]
  [[ "$output" == *"fzf"* ]]
  [[ "$output" == *"bat"* ]]
}

@test "launcher starts when runtime dependencies are available" {
  stub_bin="$BATS_TEST_TMPDIR/runtime-bin"
  make_stub_command "$stub_bin" fzf 'exit 0'
  make_stub_command "$stub_bin" bat 'exit 0'
  make_stub_command "$stub_bin" gawk "if [[ \"\${1-}\" == \"--version\" ]]; then\n  printf 'GNU Awk 5.0\\n'\n  exit 0\nfi\nexit 0"

  run env PATH="$stub_bin:/usr/bin:/bin" "$REPO_ROOT/bin/baish"

  [ "$status" -eq 0 ]
  [ "$output" = "BAISH ready. Use /quit to exit." ]
}
