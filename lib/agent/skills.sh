#!/usr/bin/env bash
# BAISH — Skills system
# Loads skills from project-local (./.baish/skills/<name>/SKILL.md) or
# user-global (~/.baish/skills/<name>/SKILL.md). Project-local overrides
# user-global. Skills persist across /new resets.

# Load a skill by name. Sets BAISH_SESSION_SKILL_NAMES and
# BAISH_SESSION_SKILL_CONTENTS. Idempotent — skips if already loaded.
# Args: skill_name [skills_root]
# skills_root defaults to BAISH_LAUNCH_DIR for project-local and
# HOME/.baish for user-global.
baish_skill_load() {
    local skill_name="$1"
    local skills_root="${2:-}"

    if [[ -z "${skill_name}" ]]; then
        baish_print_error "Skill name is required"
        return 1
    fi

    # Idempotent: skip if already loaded
    local i
    for i in "${!BAISH_SESSION_SKILL_NAMES[@]}"; do
        if [[ "${BAISH_SESSION_SKILL_NAMES[$i]}" == "${skill_name}" ]]; then
            baish_debug "Skill '${skill_name}' already loaded, skipping"
            return 0
        fi
    done

    # Resolve skill file path: project-local takes precedence over user-global
    local skill_file
    skill_file=$(baish_skill_resolve "${skill_name}" "${skills_root}")

    if [[ -z "${skill_file}" || ! -f "${skill_file}" ]]; then
        baish_print_error "Skill '${skill_name}' not found (checked project-local and user-global)"
        return 1
    fi

    # Read skill content
    local skill_content
    skill_content=$(cat "${skill_file}")

    # Append to session arrays
    BAISH_SESSION_SKILL_NAMES+=("${skill_name}")
    BAISH_SESSION_SKILL_CONTENTS+=("${skill_content}")

    baish_debug "Skill loaded: ${skill_name} from ${skill_file}"
    return 0
}

# Resolve skill file path. Project-local overrides user-global.
# Returns the path to the SKILL.md file, or empty string if not found.
# Args: skill_name [skills_root]
baish_skill_resolve() {
    local skill_name="$1"
    local skills_root="${2:-}"

    local launch_dir="${skills_root:-${BAISH_LAUNCH_DIR:-$(pwd)}}"
    local home_dir="${HOME}"

    # Check project-local first (takes precedence)
    local local_path="${launch_dir}/.baish/skills/${skill_name}/SKILL.md"
    if [[ -f "${local_path}" ]]; then
        echo "${local_path}"
        return 0
    fi

    # Check user-global
    local global_path="${home_dir}/.baish/skills/${skill_name}/SKILL.md"
    if [[ -f "${global_path}" ]]; then
        echo "${global_path}"
        return 0
    fi

    return 1
}
