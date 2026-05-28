#!/usr/bin/env bash
# ── lib/skills.sh — Skill discovery and progressive disclosure ────
# Requires: config.sh sourced first (BAISH_SKILLS_DIR)

# ── Skill registry (populated by skills_discover) ──────────────────
declare -a _SKILL_NAMES=()
declare -A _SKILL_DESCRIPTIONS=()

# ── Parse YAML frontmatter field from SKILL.md ─────────────────────
# Args: file_path  field_name
# Returns: field value, or empty string if not found
_skills_parse_field() {
    local file="$1"
    local field="$2"

    # Extract content between first pair of --- markers (YAML frontmatter)
    local frontmatter
    frontmatter=$(sed -n '/^---$/,/^---$/p' "$file" | sed '1d;$d')

    if [[ -z "$frontmatter" ]]; then
        echo ""
        return 0
    fi

    # Look for "field: value" pattern
    local value
    value=$(echo "$frontmatter" | grep -i "^${field}:" | head -1 | sed "s/^${field}:[[:space:]]*//" | sed 's/^["'"'"']//;s/["'"'"']$//')
    echo "$value"
}

# ── Discover available skills ──────────────────────────────────────
# Scans BAISH_SKILLS_DIR for subdirectories containing SKILL.md.
# Populates _SKILL_NAMES and _SKILL_DESCRIPTIONS arrays.
skills_discover() {
    _SKILL_NAMES=()
    _SKILL_DESCRIPTIONS=()

    local skills_dir="${BAISH_SKILLS_DIR:-/root/.baish/skills}"

    if [[ ! -d "$skills_dir" ]]; then
        return 0
    fi

    local skill_dir
    for skill_dir in "$skills_dir"/*/; do
        # Skip if no directories matched (glob fallback)
        [[ -d "$skill_dir" ]] || continue

        local skill_file="${skill_dir}SKILL.md"
        if [[ ! -f "$skill_file" ]]; then
            continue
        fi

        # Extract name and description from frontmatter
        local name description
        name=$(_skills_parse_field "$skill_file" "name")
        description=$(_skills_parse_field "$skill_file" "description")

        # Fallback: use directory name if no name field
        if [[ -z "$name" ]]; then
            name=$(basename "$skill_dir")
        fi

        # Fallback: empty description
        if [[ -z "$description" ]]; then
            description="No description available."
        fi

        _SKILL_NAMES+=("$name")
        _SKILL_DESCRIPTIONS["$name"]="$description"
    done
}

# ── Build skills discovery prompt ──────────────────────────────────
# Returns: text block listing available skills (name + description)
# This is appended to the system prompt so the AI knows which skills exist.
skills_build_discovery_prompt() {
    if [[ ${#_SKILL_NAMES[@]} -eq 0 ]]; then
        echo ""
        return 0
    fi

    local result="--- Available Skills ---\n"
    result+="You have access to the following skills. Use load_skill to load full instructions when needed:\n\n"

    local name
    for name in "${_SKILL_NAMES[@]}"; do
        local desc="${_SKILL_DESCRIPTIONS[$name]}"
        result+="- **${name}**: ${desc}\n"
    done

    result+="\nTo load a skill's full instructions, use: load_skill(skill_name=\"<name>\")"

    printf '%b' "$result"
}

# ── Get skill count ────────────────────────────────────────────────
skills_count() {
    echo "${#_SKILL_NAMES[@]}"
}

# ── Build JSON array of skills for API tools (alternative format) ──
# Returns: JSON array of {name, description} objects
skills_list_json() {
    local result="["
    local first=true
    local name

    for name in "${_SKILL_NAMES[@]}"; do
        local desc="${_SKILL_DESCRIPTIONS[$name]}"
        local skill_json
        skill_json=$(jq -n --arg name "$name" --arg desc "$desc" \
            '{name: $name, description: $desc}')

        if $first; then
            result+="$skill_json"
            first=false
        else
            result+=",$skill_json"
        fi
    done
    result+="]"
    echo "$result"
}
