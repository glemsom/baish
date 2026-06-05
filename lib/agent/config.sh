#!/usr/bin/env bash
# BAISH — Configuration and defaults

# Maximum number of tool call rounds per user message
BAISH_MAX_TOOL_ROUNDS="${BAISH_MAX_TOOL_ROUNDS:-20}"

# Maximum total tool calls across the session
BAISH_MAX_TOOL_CALLS="${BAISH_MAX_TOOL_CALLS:-100}"

# Bash command execution timeout in seconds
BAISH_BASH_TIMEOUT="${BAISH_BASH_TIMEOUT:-120}"

# Debug logging flag
BAISH_DEBUG="${BAISH_DEBUG:-0}"

# ANSI color codes
BAISH_COLOR_RESET='\033[0m'
BAISH_COLOR_BOLD='\033[1m'
BAISH_COLOR_DIM='\033[2m'
BAISH_COLOR_RED='\033[31m'
BAISH_COLOR_GREEN='\033[32m'
BAISH_COLOR_YELLOW='\033[33m'
BAISH_COLOR_BLUE='\033[34m'
BAISH_COLOR_CYAN='\033[36m'

# Unicode icons
BAISH_ICON_READ='📖'
BAISH_ICON_WRITE='📝'
BAISH_ICON_EDIT='✏️'
BAISH_ICON_BASH='⚙️'
BAISH_ICON_INSPECT='📖'
BAISH_ICON_USE='🔧'

# Debug logging
baish_debug() {
    if [[ "$BAISH_DEBUG" == "1" ]]; then
        printf "${BAISH_COLOR_DIM}[DEBUG] %s${BAISH_COLOR_RESET}\n" "$*" >&2
    fi
}
