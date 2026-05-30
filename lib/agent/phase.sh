baish_agent_round_is_read_only() {
  local response_json="$1"

  jq -e '
    (.tool_calls | type == "array")
    and (.tool_calls | length > 0)
    and all(.tool_calls[]; .name == "read")
  ' >/dev/null 2>&1 <<<"$response_json"
}

baish_agent_collect_read_paths_json() {
  local response_json="$1"

  jq -c '
    [
      .tool_calls[]?
      | select(.name == "read")
      | .arguments.path?
      | select(type == "string" and length > 0)
    ]
    | reduce .[] as $path ([]; if index($path) == null then . + [$path] else . end)
  ' <<<"$response_json"
}

baish_agent_join_paths_for_display() {
  local paths_json="$1"

  jq -r '
    if type == "array" then
      join(", ")
    else
      ""
    end
  ' <<<"$paths_json"
}

baish_agent_phase_label() {
  local response_json="$1"

  if jq -e '(.phase? | type == "string" and length > 0)' >/dev/null 2>&1 <<<"$response_json"; then
    jq -r '.phase' <<<"$response_json"
    return 0
  fi

  if baish_agent_round_is_read_only "$response_json"; then
    printf 'Inspect files\n'
  else
    printf 'Use tools\n'
  fi
}

