#!/usr/bin/env bats
# BAISH — Unit tests: staged progress pipeline

setup() {
    BAISH_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
    export BAISH_ROOT

    # Source modules
    source "${BAISH_ROOT}/lib/agent/config.sh"
    source "${BAISH_ROOT}/lib/agent/output.sh"
}

@test "baish_output_pipeline_init sets initial stage variable" {
    baish_output_pipeline_init
    # Verify the stage variable is set (to empty string)
    [[ "${BAISH_PIPELINE_CURRENT_STAGE}" == "" ]]
    # Verify the skip flag is 0 (BAISH_DEBUG defaults to 0)
    [[ "${BAISH_PIPELINE_SKIP}" == "0" ]]
}

@test "baish_output_pipeline_stage advances through stages" {
    baish_output_pipeline_init
    baish_output_pipeline_stage "parse"
    [[ "${BAISH_PIPELINE_CURRENT_STAGE}" == "parse" ]]
    baish_output_pipeline_stage "think"
    [[ "${BAISH_PIPELINE_CURRENT_STAGE}" == "think" ]]
    baish_output_pipeline_stage "execute"
    [[ "${BAISH_PIPELINE_CURRENT_STAGE}" == "execute" ]]
    baish_output_pipeline_stage "done"
    [[ "${BAISH_PIPELINE_CURRENT_STAGE}" == "done" ]]
}

@test "baish_output_pipeline_stage error sets error state" {
    baish_output_pipeline_init
    baish_output_pipeline_stage "error"
    [[ "${BAISH_PIPELINE_CURRENT_STAGE}" == "error" ]]
}

@test "baish_output_pipeline_stage rejects invalid stage name" {
    baish_output_pipeline_init
    # Capture stderr output (function writes to stderr on error)
    local result
    result=$(baish_output_pipeline_stage "bogus" 2>&1) || true
    # Should not change state on invalid input
    [[ "${BAISH_PIPELINE_CURRENT_STAGE}" != "bogus" ]]
    # Should report error
    [[ "${result}" == *"Invalid pipeline stage"* ]]
}

@test "pipeline renders to stderr not stdout" {
    baish_output_pipeline_init
    # Capture stderr output (function renders to stderr)
    local stderr_output
    stderr_output=$(baish_output_pipeline_stage "think" 2>&1)
    # Capture stdout (should be empty)
    local stdout_output
    stdout_output=$(baish_output_pipeline_stage "think" 2>/dev/null)
    # stdout should be empty — pipeline goes to stderr
    [[ -z "${stdout_output}" ]]
}

@test "pipeline output contains expected stage labels" {
    baish_output_pipeline_init
    local output
    output=$(baish_output_pipeline_stage "parse" 2>&1) || true
    [[ "${output}" == *"Parsing"* ]]
    [[ "${output}" == *"🔍"* ]]

    output=$(baish_output_pipeline_stage "think" 2>&1) || true
    [[ "${output}" == *"Reasoning"* ]]
    [[ "${output}" == *"🧠"* ]]

    output=$(baish_output_pipeline_stage "execute" 2>&1) || true
    [[ "${output}" == *"Executing"* ]]
    [[ "${output}" == *"⚙️"* ]]

    output=$(baish_output_pipeline_stage "done" 2>&1) || true
    [[ "${output}" == *"Done"* ]]
    [[ "${output}" == *"✅"* ]]

    output=$(baish_output_pipeline_stage "error" 2>&1) || true
    [[ "${output}" == *"Failed"* ]]
    [[ "${output}" == *"❌"* ]]
}

@test "pipeline uses ▸ separators between stages" {
    baish_output_pipeline_init
    local output
    output=$(baish_output_pipeline_stage "think" 2>&1) || true
    [[ "${output}" == *"▸"* ]]
}

@test "pipeline shows all stages in output" {
    baish_output_pipeline_init
    local output
    output=$(baish_output_pipeline_stage "execute" 2>&1) || true
    # Should contain 🔍 (parse) labels
    [[ "${output}" == *"🔍"* ]]
    # Should contain 🧠 (think) labels
    [[ "${output}" == *"🧠"* ]]
    # Should contain ⚙️ (execute) labels
    [[ "${output}" == *"⚙️"* ]]
    # Should contain ✅ (done) labels
    [[ "${output}" == *"✅"* ]]
}

@test "BAISH_DEBUG=1 suppresses pipeline rendering" {
    BAISH_DEBUG=1
    baish_output_pipeline_init
    [[ "${BAISH_PIPELINE_SKIP}" == "1" ]]
    [[ "${BAISH_USE_PIPELINE}" == "0" ]]

    # Call stage directly (not in subshell) to update state
    baish_output_pipeline_stage "parse"
    # State should still be updated even when skipping
    [[ "${BAISH_PIPELINE_CURRENT_STAGE}" == "parse" ]]
}

@test "baish_output_pipeline_cleanup resets pipeline state" {
    baish_output_pipeline_init
    baish_output_pipeline_stage "think"
    [[ "${BAISH_PIPELINE_CURRENT_STAGE}" == "think" ]]

    baish_output_pipeline_cleanup
    # After cleanup, state should be reset
    [[ -z "${BAISH_PIPELINE_CURRENT_STAGE}" ]]
    [[ "${BAISH_USE_PIPELINE}" == "0" ]]
}

@test "pipeline pipeline_init respects BAISH_DEBUG env variable" {
    BAISH_DEBUG=1
    baish_output_pipeline_init
    [[ "${BAISH_USE_PIPELINE}" == "0" ]]
    [[ "${BAISH_PIPELINE_SKIP}" == "1" ]]
}

@test "pipeline outputs carriage return and clear-line prefix" {
    baish_output_pipeline_init
    local output
    output=$(baish_output_pipeline_stage "think" 2>&1) || true
    # Should start with \r\033[K (carriage return + clear-to-end-of-line)
    [[ "${output}" == $'\r\033[K'* ]]
}
