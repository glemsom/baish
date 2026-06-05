#!/usr/bin/env bash
# BAISH — TAB completion for readline
# Handles path completion (tokens starting with @) and
# slash command completion (tokens starting with /).

# Registered slash commands
BAISH_SLASH_COMMANDS=("/quit" "/exit" "/new" "/help" "/connect" "/provider" "/model")

# Handle TAB completion during read -e prompts.
# Called via 'bind -x' when TAB is pressed in readline.
# Reads READLINE_LINE and READLINE_POINT, calls baish_complete_input,
# and updates the readline buffer with the completion result.
baish_tab_complete() {
    local before_cursor="${READLINE_LINE:0:$READLINE_POINT}"
    local after_cursor="${READLINE_LINE:$READLINE_POINT}"

    # Extract the current (last) token from before-cursor text
    local current_word
    current_word="${before_cursor##* }"

    # Nothing to complete (cursor at a space, or empty line)
    if [[ -z "${current_word}" ]]; then
        return
    fi

    local before_word="${before_cursor%${current_word}}"

    # Only handle completions for @-prefix (paths) and /-prefix (commands)
    if [[ "${current_word}" != @* && "${current_word}" != /* ]]; then
        return
    fi

    local completions
    completions=$(baish_complete_input "${current_word}" "${BAISH_LAUNCH_DIR:-$(pwd)}")

    if [[ -z "${completions}" ]]; then
        return
    fi

    # Count non-empty completion lines
    local count=0
    local comp
    while IFS= read -r comp; do
        [[ -z "${comp}" ]] && continue
        count=$((count + 1))
    done <<< "${completions}"

    if (( count == 1 )); then
        # Single match: replace the current word and move cursor past it
        local match
        match=$(echo "${completions}" | grep -m1 .)
        READLINE_LINE="${before_word}${match}${after_cursor}"
        READLINE_POINT=$(( ${#before_word} + ${#match} ))
    else
        # Multiple matches: find the longest common prefix
        local common
        common=$(echo "${completions}" | grep -m1 .)
        while IFS= read -r comp; do
            [[ -z "${comp}" ]] && continue
            while [[ "${comp}" != "${common}"* ]]; do
                common="${common%?}"
            done
        done <<< "${completions}"

        if [[ -n "${common}" && "${common}" != "${current_word}" ]]; then
            # Extend the current word to the common prefix
            READLINE_LINE="${before_word}${common}${after_cursor}"
            READLINE_POINT=$(( ${#before_word} + ${#common} ))
        else
            # No common extension — list all completions on stderr
            printf '\n' >&2
            local first=true
            while IFS= read -r comp; do
                [[ -z "${comp}" ]] && continue
                if [[ "${first}" == "true" ]]; then
                    printf '%s' "${comp}" >&2
                    first=false
                else
                    printf '  %s' "${comp}" >&2
                fi
            done <<< "${completions}"
            printf '\n' >&2
        fi
    fi
}

# Set up readline TAB completion.
# Registers baish_tab_complete as the handler for TAB keypresses
# so that @-prefixed path completion and /-prefixed command completion
# work inside 'read -e' prompts.
baish_setup_completion() {
    bind -x '"\\C-i": baish_tab_complete' 2>/dev/null || true
}

# Complete input for readline. Called by bash's completion system.
# Sets COMPREPLY array with possible completions.
# When called directly (e.g., from tests), prints completions to stdout.
# Args: current_word, launch_dir
baish_complete_input() {
    local word="$1"
    local launch_dir="${2:-$(pwd)}"

    if [[ "${word}" == @* ]]; then
        # Path completion: strip @ prefix, complete filesystem path
        local path_prefix="${word#@}"
        local completions
        completions=$(baish_complete_paths "${path_prefix}" "${launch_dir}")

        # If running in completion context (COMP_LINE is set), set COMPREPLY
        if [[ -n "${COMP_LINE:-}" ]]; then
            COMPREPLY=()
            local comp
            while IFS= read -r comp; do
                [[ -z "${comp}" ]] && continue
                COMPREPLY+=("@${comp}")
            done <<< "${completions}"
        else
            # Testing mode: prepend @ and print
            local comp
            while IFS= read -r comp; do
                [[ -z "${comp}" ]] && continue
                echo "@${comp}"
            done <<< "${completions}"
        fi
    elif [[ "${word}" == /* ]]; then
        # Slash command completion
        if [[ -n "${COMP_LINE:-}" ]]; then
            baish_complete_commands "${word}"
        else
            baish_complete_commands_stdout "${word}"
        fi
    else
        if [[ -n "${COMP_LINE:-}" ]]; then
            COMPREPLY=()
        fi
    fi
}

# Complete filesystem paths. Returns paths with directories having trailing /.
# Args: prefix, base_dir
baish_complete_paths() {
    local prefix="$1"
    local base_dir="$2"

    # Handle directory separators in prefix
    local search_dir search_prefix
    if [[ "${prefix}" == */ ]]; then
        # Prefix ends with /: list contents of that directory
        # Strip trailing slash to avoid double-slash in glob
        local dir_part="${prefix%/}"
        search_dir="${base_dir}/${dir_part}"
        search_prefix=""
    elif [[ "${prefix}" == */* ]]; then
        # prefix contains directory separators (not trailing)
        local dir_part
        dir_part=$(dirname "${prefix}")
        local base_part
        base_part=$(basename "${prefix}")
        search_dir="${base_dir}/${dir_part}"
        search_prefix="${base_part}"
    else
        search_dir="${base_dir}"
        search_prefix="${prefix}"
    fi

    if [[ ! -d "${search_dir}" ]]; then
        return
    fi

    local entry
    for entry in "${search_dir}"/${search_prefix}*; do
        [[ -e "${entry}" ]] || continue
        local relative="${entry#${base_dir}/}"
        # Strip leading ./
        relative="${relative#./}"
        if [[ -d "${entry}" ]]; then
            echo "${relative}/"
        else
            echo "${relative}"
        fi
    done
}

# Complete slash commands. Sets COMPREPLY (for readline context).
# Args: current_word (e.g., "/q" or "/skill:")
baish_complete_commands() {
    local word="$1"
    COMPREPLY=()

    # Check if this is a /skill: prefix completion
    if [[ "${word}" == /skill:* ]]; then
        local skill_prefix="${word#/skill:}"
        local skill_name
        for skill_name in "${BAISH_SESSION_SKILL_NAMES[@]}"; do
            if [[ "${skill_name}" == "${skill_prefix}"* ]]; then
                COMPREPLY+=("/skill:${skill_name}")
            fi
        done
        return
    fi

    # Standard slash command completion
    local cmd
    for cmd in "${BAISH_SLASH_COMMANDS[@]}"; do
        if [[ "${cmd}" == "${word}"* ]]; then
            COMPREPLY+=("${cmd}")
        fi
    done
}

# Complete slash commands, printing results to stdout (for testing).
# Args: current_word (e.g., "/q" or "/skill:")
baish_complete_commands_stdout() {
    local word="$1"

    # Check if this is a /skill: prefix completion
    if [[ "${word}" == /skill:* ]]; then
        local skill_prefix="${word#/skill:}"
        local skill_name
        for skill_name in "${BAISH_SESSION_SKILL_NAMES[@]}"; do
            if [[ "${skill_name}" == "${skill_prefix}"* ]]; then
                echo "/skill:${skill_name}"
            fi
        done
        return
    fi

    # Standard slash command completion
    local cmd
    for cmd in "${BAISH_SLASH_COMMANDS[@]}"; do
        if [[ "${cmd}" == "${word}"* ]]; then
            echo "${cmd}"
        fi
    done
}
