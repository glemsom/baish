#!/usr/bin/env bash
# BAISH — Tool execution engine
# Executes tool calls and returns standardized JSON results

source "${BASH_SOURCE%/*}/../agent/config.sh"

# Tool result helpers
baish_tool_success_json() {
    local tool_name="$1"
    local data_json="$2"
    jq -n --arg tool "${tool_name}" --argjson data "${data_json}" \
        '{"ok": true, "tool": $tool, "data": $data}'
}

baish_tool_error_json() {
    local tool_name="$1"
    local code="$2"
    local message="$3"
    jq -n --arg tool "${tool_name}" --arg code "${code}" --arg message "${message}" \
        '{"ok": false, "tool": $tool, "error": {"code": $code, "message": $message}}'
}

# Main tool dispatcher
baish_tool_execute() {
    local tool_name="$1"
    local args_json="$2"

    case "${tool_name}" in
        read)
            baish_tool_read "${args_json}"
            ;;
        write)
            baish_tool_write "${args_json}"
            ;;
        edit)
            baish_tool_edit "${args_json}"
            ;;
        bash)
            baish_tool_bash "${args_json}"
            ;;
        *)
            baish_tool_error_json "${tool_name}" "UNKNOWN_TOOL" "Unknown tool: ${tool_name}"
            ;;
    esac
}

# Return OpenAI-compatible function-calling schemas for all tools
# Each tool follows the OpenAI tools format:
#   {type: "function", function: {name, description, parameters}}
baish_tool_schemas() {
    # Use a heredoc to avoid quoting issues, then pipe through jq to validate
    # and pretty-print. The jq -c at the end compacts it to one line.
    cat <<'BAISH_EOJSON' | jq -c '.'
[
  {
    "type": "function",
    "function": {
      "name": "read",
      "description": "Read file contents. Supports offset and limit for partial reads.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "File path (relative to launch directory)"
          },
          "offset": {
            "type": "integer",
            "description": "1-indexed line to start reading from"
          },
          "limit": {
            "type": "integer",
            "description": "Maximum number of lines to read"
          }
        },
        "required": ["path"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "write",
      "description": "Write content to a file. Uses atomic write (temp file + rename). Creates parent directories if needed.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "File path (relative to launch directory)"
          },
          "content": {
            "type": "string",
            "description": "Content to write to the file"
          }
        },
        "required": ["path", "content"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "edit",
      "description": "Edit a file using exact text replacement. Supports multiple disjoint edits in one call. Each edit replaces oldText with newText. All edits are validated against the original file before any are applied.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "File path (relative to launch directory)"
          },
          "edits": {
            "type": "array",
            "description": "Array of edits to apply (each edit must have exactly one occurrence of oldText in the file)",
            "items": {
              "type": "object",
              "properties": {
                "oldText": {
                  "type": "string",
                  "description": "Exact text to replace (must appear exactly once in the file)"
                },
                "newText": {
                  "type": "string",
                  "description": "Replacement text"
                }
              },
              "required": ["oldText", "newText"]
            }
          }
        },
        "required": ["path", "edits"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "bash",
      "description": "Execute a shell command in the launch directory with inherited environment. Supports optional env variable overrides.",
      "parameters": {
        "type": "object",
        "properties": {
          "command": {
            "type": "string",
            "description": "Shell command to execute"
          },
          "env": {
            "type": "object",
            "description": "Optional environment variable overrides as key-value pairs",
            "additionalProperties": {
              "type": "string"
            }
          }
        },
        "required": ["command"]
      }
    }
  }
]
BAISH_EOJSON
}
