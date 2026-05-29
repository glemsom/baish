#!/usr/bin/env bash

baish_check_runtime_dependencies() {
  local -a issues=()

  if [[ "$(uname -s 2>/dev/null || true)" != "Linux" ]]; then
    issues+=("GNU/Linux is required")
  fi

  if [[ -z "${BASH_VERSINFO[*]-}" || "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    issues+=("bash >= 4 is required")
  fi

  baish_collect_command_issue mktemp "GNU coreutils (checked via mktemp)" issues
  if command -v mktemp >/dev/null 2>&1; then
    local mktemp_version
    mktemp_version="$(mktemp --version 2>/dev/null || true)"
    if [[ "$mktemp_version" != *"GNU coreutils"* ]]; then
      issues+=("GNU coreutils is required")
    fi
  fi

  baish_collect_gnu_tool_issue sed 'GNU sed' 'GNU sed' issues
  baish_collect_gnu_awk_issue issues
  baish_collect_gnu_tool_issue grep 'GNU grep' 'GNU grep' issues
  baish_collect_command_issue curl curl issues
  baish_collect_command_issue jq jq issues
  baish_collect_command_issue fzf fzf issues
  baish_collect_command_issue bat bat issues

  if ((${#issues[@]} == 0)); then
    return 0
  fi

  printf 'BAISH cannot start because required runtime dependencies are missing or unsupported:\n' >&2
  printf '  - %s\n' "${issues[@]}" >&2
  return 1
}

baish_collect_command_issue() {
  local command_name="$1"
  local label="$2"
  local issues_name="$3"
  local -n issues_ref="$issues_name"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    issues_ref+=("$label")
  fi
}

baish_collect_gnu_tool_issue() {
  local command_name="$1"
  local version_pattern="$2"
  local label="$3"
  local issues_name="$4"
  local -n issues_ref="$issues_name"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    issues_ref+=("$label")
    return
  fi

  local version_output
  version_output="$("$command_name" --version 2>/dev/null || true)"
  if [[ "$version_output" != *"$version_pattern"* ]]; then
    issues_ref+=("$label")
  fi
}

baish_collect_gnu_awk_issue() {
  local issues_name="$1"
  local -n issues_ref="$issues_name"

  local version_output

  if command -v gawk >/dev/null 2>&1; then
    version_output="$(gawk --version 2>/dev/null || true)"
    if [[ "$version_output" == *"GNU Awk"* ]]; then
      return
    fi
  fi

  if command -v awk >/dev/null 2>&1; then
    version_output="$(awk --version 2>/dev/null || true)"
    if [[ "$version_output" == *"GNU Awk"* ]]; then
      return
    fi
  fi

  issues_ref+=("GNU awk/gawk")
}
