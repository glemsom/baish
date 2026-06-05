#!/usr/bin/env bash
# BAISH — TAB completion for readline
# Handles path completion (tokens starting with @) and
# slash command completion (tokens starting with /).

# Registered slash commands
BAISH_SLASH_COMMANDS=("/quit" "/exit" "/new" "/help" "/connect" "/provider" "/model")

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
