# Copilot provider behind provider interface

BAISH V1 will support GitHub Copilot as the only provider, but the agent loop will call it through a provider interface rather than hardcoding Copilot details throughout the codebase. This adds a small amount of structure now so future providers can be added without rewriting the TUI, slash command handling, or tool execution flow.
