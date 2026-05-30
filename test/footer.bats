#!/usr/bin/env bats

load test_helper.bash

setup() {
  REPO_ROOT="$(repo_root)"
  TEST_HOME="$BATS_TEST_TMPDIR/home"

  mkdir -p "$TEST_HOME"
  HOME="$TEST_HOME"

  source "$REPO_ROOT/lib/state.sh"
  source "$REPO_ROOT/lib/footer.sh"
}

@test "footer shortens paths under HOME" {
  run baish_footer_home_shorten_path "$HOME/project"

  [ "$status" -eq 0 ]
  [ "$output" = '~/project' ]
}

@test "footer uses explicit launch directory fallback" {
  unset BAISH_LAUNCH_CWD

  run baish_footer_launch_directory_text

  [ "$status" -eq 0 ]
  [ "$output" = '?' ]
}

@test "footer uses explicit model fallback" {
  unset BAISH_ACTIVE_MODEL

  run baish_footer_model_text

  [ "$status" -eq 0 ]
  [ "$output" = 'no model' ]
}

@test "footer resolves provider label from provider metadata" {
  baish_provider_metadata_json() {
    printf '{"id":"demo","label":"Demo Provider"}\n'
  }
  BAISH_ACTIVE_PROVIDER='demo'

  run baish_footer_provider_label_text

  [ "$status" -eq 0 ]
  [ "$output" = 'Demo Provider' ]
}

@test "footer falls back when provider label cannot be resolved" {
  baish_provider_metadata_json() {
    return 1
  }
  BAISH_ACTIVE_PROVIDER='missing'

  run baish_footer_provider_label_text

  [ "$status" -eq 0 ]
  [ "$output" = 'unknown provider' ]
}

@test "footer divider spans the requested width" {
  run baish_footer_divider_line 5

  [ "$status" -eq 0 ]
  [ "$output" = '─────' ]
}

@test "footer render emits divider and status line" {
  baish_provider_metadata_json() {
    printf '{"id":"demo","label":"Demo Provider"}\n'
  }

  BAISH_LAUNCH_CWD="$HOME/project"
  BAISH_ACTIVE_PROVIDER='demo'
  BAISH_ACTIVE_MODEL='model-a'
  COLUMNS=80

  run baish_footer_render_lines

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '────────────────────────────────────────────────────────────────────────────────' ]
  [ "${lines[1]}" = '~/project · Demo Provider · model-a' ]
}

@test "footer render falls back to explicit footer text when formatter helpers fail" {
  baish_footer_divider_line() {
    return 1
  }

  baish_footer_format_status_line() {
    return 1
  }

  COLUMNS=12

  run baish_footer_render_lines

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '────────────' ]
  [ "${lines[1]}" = '? · unknown…' ]
}

@test "footer status line stays unchanged when width is sufficient" {
  baish_provider_metadata_json() {
    printf '{"id":"demo","label":"Demo Provider"}\n'
  }

  BAISH_LAUNCH_CWD='/tmp/project'
  BAISH_ACTIVE_PROVIDER='demo'
  BAISH_ACTIVE_MODEL='model-a'

  run baish_footer_format_status_line 38

  [ "$status" -eq 0 ]
  [ "$output" = '/tmp/project · Demo Provider · model-a' ]
}

@test "footer truncates launch directory before model and provider" {
  baish_provider_metadata_json() {
    printf '{"id":"demo","label":"Demo Provider"}\n'
  }

  BAISH_LAUNCH_CWD='/tmp/project'
  BAISH_ACTIVE_PROVIDER='demo'
  BAISH_ACTIVE_MODEL='model-a'

  run baish_footer_format_status_line 30

  [ "$status" -eq 0 ]
  [ "$output" = '/tm… · Demo Provider · model-a' ]
}

@test "footer truncates model before provider after launch directory is exhausted" {
  baish_provider_metadata_json() {
    printf '{"id":"demo","label":"Demo Provider"}\n'
  }

  BAISH_LAUNCH_CWD='/tmp/project'
  BAISH_ACTIVE_PROVIDER='demo'
  BAISH_ACTIVE_MODEL='model-a'

  run baish_footer_format_status_line 22

  [ "$status" -eq 0 ]
  [ "$output" = '… · Demo Provider · m…' ]
}

@test "footer keeps a single clipped line at very narrow widths" {
  baish_provider_metadata_json() {
    printf '{"id":"demo","label":"Demo Provider"}\n'
  }

  BAISH_LAUNCH_CWD='/tmp/project'
  BAISH_ACTIVE_PROVIDER='demo'
  BAISH_ACTIVE_MODEL='model-a'

  run baish_footer_format_status_line 5

  [ "$status" -eq 0 ]
  [ "$output" = '… · …' ]
}

@test "footer refreshes provider and model from current process state when rendering" {
  local output_file output status

  baish_provider_metadata_json() {
    case "$1" in
      demo)
        printf '{"id":"demo","label":"Demo Provider"}\n'
        ;;
      *)
        return 1
        ;;
    esac
  }

  BAISH_LAUNCH_CWD='/tmp/project'
  BAISH_PROCESS_SELECTED_PROVIDER='demo'
  BAISH_PROCESS_SELECTED_MODEL='model-live'
  BAISH_ACTIVE_PROVIDER='stale'
  BAISH_ACTIVE_MODEL='stale-model'

  output_file="$BATS_TEST_TMPDIR/footer-refresh-output"
  baish_footer_format_status_line 80 >"$output_file"
  status=$?
  output="$(<"$output_file")"

  [ "$status" -eq 0 ]
  [ "$output" = '/tmp/project · Demo Provider · model-live' ]
  [ "$BAISH_ACTIVE_PROVIDER" = 'demo' ]
  [ "$BAISH_ACTIVE_MODEL" = 'model-live' ]
}
