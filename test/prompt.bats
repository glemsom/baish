#!/usr/bin/env bats

load test_helper.bash

setup() {
  REPO_ROOT="$(repo_root)"
}

@test "secret prompt works when stdout is captured by command substitution" {
  local prompt_script

  prompt_script="$BATS_TEST_TMPDIR/prompt-command-substitution.sh"
  cat >"$prompt_script" <<'EOF'
#!/usr/bin/env bash
source "__REPO_ROOT__/lib/prompt.sh"
secret="$(baish_prompt_secret 'Enter secret: ')"
printf 'secret=%s\n' "$secret"
EOF
  sed -i "s|__REPO_ROOT__|$REPO_ROOT|g" "$prompt_script"
  chmod +x "$prompt_script"

  run bash -lc 'script -qec "$1" /dev/null <<<"swordfish"' bash "$prompt_script"

  [ "$status" -eq 0 ]
  [[ "$output" == *'secret=swordfish'* ]]
  [[ "$output" != *'BAISH cannot prompt for hidden input without an interactive terminal.'* ]]
}
