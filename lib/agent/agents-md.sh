#!/usr/bin/env bash
# BAISH — Agent Instructions (AGENTS.md) loading
# Loads ~/.baish/AGENTS.md (global) and ./AGENTS.md (project) at process start,
# concatenates them (global first, then project) into a single user message,
# and injects it between skills and conversation messages.
# Loaded once — survives /new resets.

# Global variable holding the concatenated AGENTS.md content.
# Empty when neither file exists or both are empty.
BAISH_AGENTS_MD_CONTENT=""

# Array tracking which files were loaded (file paths).
# Empty when no files were loaded.
BAISH_AGENTS_MD_LOADED_FILES=()

# Initialize agent instructions: load and concatenate global then project AGENTS.md.
# Called once at process start. Missing or empty files are silently skipped.
baish_agents_md_init() {
    local global_file="${HOME}/.baish/AGENTS.md"
    local project_file="./AGENTS.md"

    local parts=()
    BAISH_AGENTS_MD_LOADED_FILES=()

    # Load global file first
    if [[ -f "${global_file}" && -s "${global_file}" ]]; then
        parts+=("$(cat "${global_file}")")
        BAISH_AGENTS_MD_LOADED_FILES+=("${global_file}")
        baish_debug "Loaded global AGENTS.md from ${global_file}"
    fi

    # Load project file second
    if [[ -f "${project_file}" && -s "${project_file}" ]]; then
        parts+=("$(cat "${project_file}")")
        BAISH_AGENTS_MD_LOADED_FILES+=("${project_file}")
        baish_debug "Loaded project AGENTS.md from ${project_file}"
    fi

    # Concatenate with blank line separator if both exist
    local combined=""
    local part
    for part in "${parts[@]}"; do
        if [[ -n "${combined}" ]]; then
            combined+=$'\n\n'
        fi
        combined+="${part}"
    done

    BAISH_AGENTS_MD_CONTENT="${combined}"

    if [[ -n "${BAISH_AGENTS_MD_CONTENT}" ]]; then
        baish_debug "AGENTS.md content loaded (${#BAISH_AGENTS_MD_CONTENT} characters)"
    else
        baish_debug "No AGENTS.md content loaded (no files found or both empty)"
    fi
}

# Get the loaded AGENTS.md content. Returns empty string if none was loaded.
baish_agents_md_get_content() {
    echo "${BAISH_AGENTS_MD_CONTENT}"
}

# Get an array of AGENTS.md file paths that were loaded.
# Returns each path on its own line (for capture into array).
baish_agents_md_get_loaded_files() {
    local f
    for f in "${BAISH_AGENTS_MD_LOADED_FILES[@]}"; do
        echo "${f}"
    done
}