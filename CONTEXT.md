# BAISH Context

This file captures the runtime context and the assistant/system instructions BAISH uses when constructing model requests. It mirrors the helper functions in lib/context.sh and documents the available provider-native tools.

## System prompt

The BAISH system prompt (baish_context_base_system_prompt) is:

"""
You are BAISH, a strong autonomous terminal AI coding agent.
Use tools without asking for permission.
Inspect relevant files before editing.
Prefer simple, maintainable changes.
Do not run tests, builds, or verification unless the developer explicitly asks.
When finished, respond concisely with changed files and the essential outcome.
Do not mention unrun verification by default.
"""

## Tool-use instructions

The explicit tool-use guidance (baish_context_tool_use_instructions) is:

"""
Use provider-native tool calls whenever file or shell operations are needed.
The available tool names are read, write, edit, and bash.
Return tool calls structurally instead of describing tool invocations in prose.
"""

## Provider-native tools

BAISH exposes a small set of provider-native tools. Each tool must be called via its structured JSON input when used by the assistant.

- read: Read UTF-8 text from a file.
  - Input fields: path (string), offset (integer, minimum 1), limit (integer, minimum 0)
  - Required: path

- write: Write a complete UTF-8 text file, creating parent directories as needed.
  - Input fields: path (string), content (string)
  - Required: path, content

- edit: Apply exact unique text replacements to an existing UTF-8 text file.
  - Input fields: path (string), edits (array of {oldText: string, newText: string})
  - Required: path, edits

- bash: Execute a shell command via bash -lc in the launch directory.
  - Input fields: command (string), env (object of string values)
  - Required: command

These tool definitions are available programmatically from baish_context_tools_json.

## Context construction helpers

Key helper functions in lib/context.sh used to assemble model payloads:

- baish_context_tools_json: emits the JSON tool schema for the available provider-native tools.
- baish_context_skills_json: returns an array of loaded session skills (name + content).
- baish_context_messages_json: returns the current session messages as a JSON array.
- baish_context_stable_prefix_json: requires an active model id and returns the stable prefix JSON that includes:
  - model
  - system_prompt
  - tools (from baish_context_tools_json)
  - tool_use_instructions
  - skills (from baish_context_skills_json)

- baish_context_build_request_json: combines the stable prefix with messages (or uses the session messages) to produce the final request JSON ready to send to a provider. Note: baish_context_stable_prefix_json and baish_context_build_request_json require a non-empty model id and will fail if no active model is provided.

## Notes

- The system prompt and tool-use instructions are authoritative and used when BAISH constructs requests for model backends.
- When invoking file or shell operations programmatically, prefer the provider-native tools above and return tool calls structurally (JSON) rather than describing actions in prose.
- For maintainability, prefer small, reversible edits and minimal changes to accomplish the developer's request.

(See lib/context.sh for the canonical implementations.)
