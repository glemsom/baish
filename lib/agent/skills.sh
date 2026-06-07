#!/usr/bin/env bash
# BAISH — Skills system
# Loads skills from project-local (./.baish/skills/<name>/SKILL.md) or
# user-global (~/.baish/skills/<name>/SKILL.md). Project-local overrides
# user-global. Skills persist across /new resets.
#
# At startup, baish scans available skills and injects their names and
# descriptions into the system prompt so the model knows what's available.
# Skills are loaded on-demand via /skill:<name> for progressive disclosure.

# Cache of available skills: associative array mapping name -> description
# Populated by baish_skill_scan_available at startup.
BAISH_SKILL_CATALOG_XML=""

# Load a skill by name. Sets BAISH_SESSION_SKILL_NAMES and
# BAISH_SESSION_SKILL_CONTENTS. Idempotent — skips if already loaded.
# Args: skill_name [skills_root]
# skills_root defaults to BAISH_LAUNCH_DIR for project-local and
# HOME/.baish for user-global.
baish_skill_load() {
    local skill_name="$1"
    local skills_root="${2:-}"

    if [[ -z "${skill_name}" ]]; then
        baish_output_error "Skill name is required"
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
        baish_output_error "Skill '${skill_name}' not found (checked project-local and user-global)"
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

# Scan all skill directories and build the catalog XML block injected into
# the system prompt. Project-local skills override user-global skills.
# Sets BAISH_SKILL_CATALOG_XML. Called once at startup.
baish_skill_scan_available() {
    local launch_dir="${BAISH_LAUNCH_DIR:-$(pwd)}"
    local home_dir="${HOME}"
    local -A seen_names
    local -a catalog_entries
    local dir

    # Helper: scan a single directory for SKILL.md files
    _baish_skill_scan_dir() {
        local base="$1"
        local skills_dir="${base}/.baish/skills"

        if [[ ! -d "${skills_dir}" ]]; then
            return
        fi

        local skill_dir
        for skill_dir in "${skills_dir}"/*/; do
            [[ -d "${skill_dir}" ]] || continue
            local skill_file="${skill_dir}SKILL.md"
            [[ -f "${skill_file}" ]] || continue

            local name
            name=$(basename "${skill_dir}")

            # Skip if already seen (project-local overrides)
            [[ -n "${seen_names[$name]:-}" ]] && continue
            seen_names[$name]=1

            # Parse frontmatter for name (may differ from directory name) and description
            local fm_name fm_desc
            _baish_skill_parse_frontmatter "${skill_file}"
            local display_name="${fm_name:-$name}"
            local display_desc="${fm_desc:-}"

            catalog_entries+=("${display_name}" "${display_desc}" "${skills_dir}/${name}/SKILL.md")
        done
    }

    # Scan project-local first, then global. Project-local takes precedence
    # because global entries are skipped if already seen.
    _baish_skill_scan_dir "${launch_dir}"
    _baish_skill_scan_dir "${home_dir}"

    # Populate global available skill names array for TAB completion
    BAISH_AVAILABLE_SKILL_NAMES=()

    # Build XML block
    if [[ ${#catalog_entries[@]} -eq 0 ]]; then
        BAISH_SKILL_CATALOG_XML=""
        return
    fi

    local xml="<available_skills>"$'\n'
    local i
    for (( i = 0; i < ${#catalog_entries[@]}; i += 3 )); do
        local entry_name="${catalog_entries[$i]}"
        local entry_desc="${catalog_entries[$i+1]}"
        local entry_location="${catalog_entries[$i+2]}"
        xml+="  <skill>"$'\n'
        xml+="    <name>${entry_name}</name>"$'\n'
        xml+="    <description>${entry_desc}</description>"$'\n'
        xml+="    <location>${entry_location}</location>"$'\n'
        xml+="  </skill>"$'\n'
        BAISH_AVAILABLE_SKILL_NAMES+=("${entry_name}")
    done
    xml+="</available_skills>"

    BAISH_SKILL_CATALOG_XML="${xml}"
    baish_debug "Skill catalog built: ${#catalog_entries[@]} skills"
}

# Internal: parse YAML frontmatter from a SKILL.md file.
# Sets fm_name and fm_desc in the caller's scope.
# Frontmatter is between --- delimiters at the top of the file.
_baish_skill_parse_frontmatter() {
    local file="$1"
    fm_name=""
    fm_desc=""

    local in_fm=0
    local line
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" == "---" ]]; then
            if (( in_fm == 0 )); then
                in_fm=1
                continue
            else
                break
            fi
        fi

        if (( in_fm == 1 )); then
            case "${line}" in
                name:*)
                    fm_name="${line#name:}"
                    fm_name="${fm_name# }"  # strip leading space
                    fm_name="${fm_name%\r}" # strip carriage return
                    ;;
                description:*)
                    fm_desc="${line#description:}"
                    fm_desc="${fm_desc# }"
                    fm_desc="${fm_desc%\r}"
                    ;;
            esac
        fi
    done < "${file}"
}

# Get the pre-built skill catalog XML for injection into the system prompt.
baish_skill_get_catalog() {
    echo "${BAISH_SKILL_CATALOG_XML}"
}

# Get count of available skills for startup summary.
baish_skill_count_available() {
    if [[ -z "${BAISH_SKILL_CATALOG_XML}" ]]; then
        echo 0
        return
    fi
    echo "${BAISH_SKILL_CATALOG_XML}" | grep -c '<skill>' || echo 0
}
