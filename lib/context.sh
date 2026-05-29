#!/usr/bin/env bash

baish_context_base_system_prompt() {
  cat <<'EOF'
You are BAISH, a strong autonomous terminal AI coding agent.
Use tools without asking for permission.
Inspect relevant files before editing.
Prefer simple, maintainable changes.
Do not run tests, builds, or verification unless the developer explicitly asks.
When finished, respond concisely with changed files and the essential outcome.
Do not mention unrun verification by default.
EOF
}

baish_context_tool_use_instructions() {
  cat <<'EOF'
Use provider-native tool calls whenever file or shell operations are needed.
The available tool names are read, write, edit, and bash.
Return tool calls structurally instead of describing tool invocations in prose.
EOF
}

baish_context_tools_json() {
  jq -cn '
    [
      {
        name: "read",
        description: "Read UTF-8 text from a file.",
        input_schema: {
          type: "object",
          properties: {
            path: {type: "string"},
            offset: {type: "integer", minimum: 1},
            limit: {type: "integer", minimum: 0}
          },
          required: ["path"],
          additionalProperties: false
        }
      },
      {
        name: "write",
        description: "Write a complete UTF-8 text file, creating parent directories as needed.",
        input_schema: {
          type: "object",
          properties: {
            path: {type: "string"},
            content: {type: "string"}
          },
          required: ["path", "content"],
          additionalProperties: false
        }
      },
      {
        name: "edit",
        description: "Apply exact unique text replacements to an existing UTF-8 text file.",
        input_schema: {
          type: "object",
          properties: {
            path: {type: "string"},
            edits: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  oldText: {type: "string"},
                  newText: {type: "string"}
                },
                required: ["oldText", "newText"],
                additionalProperties: false
              }
            }
          },
          required: ["path", "edits"],
          additionalProperties: false
        }
      },
      {
        name: "bash",
        description: "Execute a shell command via bash -lc in the launch directory.",
        input_schema: {
          type: "object",
          properties: {
            command: {type: "string"},
            env: {
              type: "object",
              additionalProperties: {type: "string"}
            }
          },
          required: ["command"],
          additionalProperties: false
        }
      }
    ]
  '
}

baish_context_skills_json() {
  local skills_json='[]'
  local index

  baish_session_init

  for index in "${!BAISH_SESSION_SKILL_NAMES[@]}"; do
    skills_json="$(jq -cn \
      --argjson skills "$skills_json" \
      --arg name "${BAISH_SESSION_SKILL_NAMES[$index]}" \
      --arg content "${BAISH_SESSION_SKILL_CONTENTS[$index]}" \
      '$skills + [{name: $name, content: $content}]')" || return 1
  done

  printf '%s\n' "$skills_json"
}

baish_context_messages_json() {
  local messages_json='[]'
  local message_json

  baish_session_init

  for message_json in "${BAISH_SESSION_MESSAGES[@]}"; do
    messages_json="$(jq -cn --argjson messages "$messages_json" --argjson message "$message_json" '$messages + [$message]')" || return 1
  done

  printf '%s\n' "$messages_json"
}

baish_context_stable_prefix_json() {
  local model="$1"
  local tools_json skills_json system_prompt tool_use_instructions

  if [[ -z "$model" ]]; then
    printf 'BAISH context construction requires an active model.\n' >&2
    return 1
  fi

  tools_json="$(baish_context_tools_json)" || return 1
  skills_json="$(baish_context_skills_json)" || return 1
  system_prompt="$(baish_context_base_system_prompt)" || return 1
  tool_use_instructions="$(baish_context_tool_use_instructions)" || return 1

  jq -cn \
    --arg model "$model" \
    --arg system_prompt "$system_prompt" \
    --argjson tools "$tools_json" \
    --arg tool_use_instructions "$tool_use_instructions" \
    --argjson skills "$skills_json" \
    '{model: $model, system_prompt: $system_prompt, tools: $tools, tool_use_instructions: $tool_use_instructions, skills: $skills}'
}

baish_context_build_request_json() {
  local model="$1"
  local messages_json="${2-}"
  local stable_prefix_json

  if [[ -z "$messages_json" ]]; then
    messages_json="$(baish_context_messages_json)" || return 1
  fi

  stable_prefix_json="$(baish_context_stable_prefix_json "$model")" || return 1

  jq -cn --argjson stable_prefix "$stable_prefix_json" --argjson messages "$messages_json" '$stable_prefix + {messages: $messages}'
}
