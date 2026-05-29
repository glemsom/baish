#!/usr/bin/env bats

load test_helper.bash

setup() {
  REPO_ROOT="$(repo_root)"
  TEST_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$TEST_HOME"
  source "$REPO_ROOT/lib/state.sh"
  source "$REPO_ROOT/lib/log.sh"
  unset BAISH_DEBUG
  unset BAISH_MODEL
  unset BAISH_PROVIDER
  unset BAISH_LOG_FILE
  HOME="$TEST_HOME"
}

@test "state init creates ~/.baish directories and skips logs by default" {
  baish_state_init

  [ -d "$TEST_HOME/.baish" ]
  [ -d "$TEST_HOME/.baish/auth" ]
  [ -d "$TEST_HOME/.baish/skills" ]
  [ ! -e "$TEST_HOME/.baish/logs" ]
}

@test "persisted model is used when BAISH_MODEL is unset" {
  local active_model

  baish_state_init
  baish_state_set_selected_provider_model 'copilot' 'persisted-model'
  active_model="$(baish_config_active_model)"

  [ "$active_model" = 'persisted-model' ]
}

@test "BAISH_MODEL overrides persisted model for the current process" {
  local active_model

  baish_state_init
  baish_state_set_selected_provider_model 'copilot' 'persisted-model'
  BAISH_MODEL='env-model'
  active_model="$(baish_config_active_model)"

  [ "$active_model" = 'env-model' ]
}

@test "auth token files are written with restrictive permissions" {
  baish_state_init
  baish_state_write_auth_json 'copilot' '{"access_token":"secret-token","refresh_token":"refresh-token"}'

  auth_file="$TEST_HOME/.baish/auth/copilot.json"

  [ -f "$auth_file" ]
  [ "$(stat -c '%a' "$auth_file")" = '600' ]
}

@test "debug logging writes metadata-only redacted json lines when enabled" {
  local logged_event logged_url logged_status logged_token logged_stdout

  BAISH_DEBUG=1
  baish_state_init
  baish_log_init
  baish_log_event 'provider_http' '{"url":"https://api.example.test/chat","status_code":200,"token":"secret-token","stdout":"tool output should not persist"}'

  [ -f "$BAISH_LOG_FILE" ]
  [ "$(stat -c '%a' "$BAISH_LOG_FILE")" = '600' ]
  [ -d "$TEST_HOME/.baish/logs" ]

  logged_event="$(jq -r '.event' "$BAISH_LOG_FILE")"
  logged_url="$(jq -r '.metadata.url' "$BAISH_LOG_FILE")"
  logged_status="$(jq -r '.metadata.status_code' "$BAISH_LOG_FILE")"
  logged_token="$(jq -r '.metadata.token' "$BAISH_LOG_FILE")"
  logged_stdout="$(jq -r '.metadata.stdout' "$BAISH_LOG_FILE")"

  [ "$logged_event" = 'provider_http' ]
  [ "$logged_url" = 'https://api.example.test/chat' ]
  [ "$logged_status" = '200' ]
  [ "$logged_token" = '[REDACTED]' ]
  [ "$logged_stdout" = '[OMITTED]' ]
}
