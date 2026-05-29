# Project name
BAISH

## Description
A BASH AI Coding tool.

We want a AI Coding tool written in BASH, with a TUI. Similar to products like "Pi agent" or "Copilot" - but written in BASH instead.

## General
 - Keep it simple and easy to maintain
 - Use BASH, and terminal tools like `bat`, `jq` or similar when needed.

## Features for V1
 - Providers:
   - Copilot (Both for authentication and models)
   - Additional providers will be added later.
 - Support "slash" commands for:
   - /connect       -> To connect and authenticate towards LLM provider
   - /quit          -> Exit the TUI
   - /model         -> Select a different model from the provider
   - /skill:`skill` -> Load skill into context window

 - Simple BASH style tab completion for slash-commands 
   - Ensure we can do mutible TAB completions. Like, we might want to add two or more skills into the context

## Tools support for V1
 - read: For reading file content
 - write: For writing an entire file
 - edit: Make changes to a file
 - bash: Execute shell commands

 For tools - take inspiration for other AI Coding clients like `pi agent`

### Configration
 - Support environment-variables for configuration (Config file might be added later)