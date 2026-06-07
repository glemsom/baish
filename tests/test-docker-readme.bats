#!/usr/bin/env bats
# BAISH — Tests: Docker README documentation (issue #57)
# These tests verify the README has complete Docker containerization
# setup instructions meeting the issue #57 acceptance criteria.

setup() {
    BAISH_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
    export BAISH_ROOT
    README="${BAISH_ROOT}/README.md"
}

# -------------------------------------------------------------------------
# Acceptance criterion: README includes a "Docker container" section
# with build prerequisites and commands
# -------------------------------------------------------------------------

@test "README has a Docker Containerization section" {
    grep -q "## Docker Containerization" "${README}"
}

@test "README lists Docker as a prerequisite" {
    grep -q "Prerequisites" "${README}"
    grep -i -q "Docker" "${README}"
}

@test "README includes docker build command" {
    grep -q "docker build -t baish:latest" "${README}"
}

@test "README shows build from repo root" {
    grep -q "docker build -t baish:latest \." "${README}"
}

# -------------------------------------------------------------------------
# Acceptance criterion: Wrapper setup instructions are clear enough
# for a first-time user to follow
# -------------------------------------------------------------------------

@test "README describes how to source the wrapper" {
    grep -q "source docker/baish-wrapper.sh" "${README}"
}

@test "README recommends adding source to .bashrc for persistence" {
    grep -q -i "\.bashrc" "${README}"
}

@test "README shows basic usage example" {
    grep -q "cd /path/to/your/project" "${README}"
    grep -q "baish" "${README}"
}

@test "README shows how to pass a directory argument" {
    grep -q "baish /path/to/your/project" "${README}"
}

# -------------------------------------------------------------------------
# Acceptance criterion: Linux-only caveat is documented
# -------------------------------------------------------------------------

@test "README documents SSH agent socket forwarding Linux limitation" {
    grep -q -i "SSH agent socket forwarding only works on Linux" "${README}"
}

# -------------------------------------------------------------------------
# Acceptance criterion: Docker-in-Docker security trade-off is documented
# -------------------------------------------------------------------------

@test "README has a Docker-in-Docker section" {
    grep -q "### Docker-in-Docker" "${README}"
}

@test "README documents --privileged security implications" {
    grep -q "grants the container full access to the host kernel" "${README}"
}

@test "README states the setup is blast-radius reduction, not a security sandbox" {
    grep -q "not a security sandbox" "${README}"
}

@test "README documents container escape risk" {
    grep -q "malicious or compromised agent" "${README}"
    grep -q "container escape" "${README}"
}

# -------------------------------------------------------------------------
# Content from issue: Rebuilding note
# -------------------------------------------------------------------------

@test "README has a note about rebuilding for custom toolchain versions" {
    grep -q -i "rebuild" "${README}"
}

# -------------------------------------------------------------------------
# Environment variables table
# -------------------------------------------------------------------------

@test "README documents BAISH environment variables used by container" {
    grep -q "BAISH_MAX_TOOL_ROUNDS" "${README}"
    grep -q "BAISH_BASH_TIMEOUT" "${README}"
    grep -q "BAISH_DEBUG" "${README}"
}

# -------------------------------------------------------------------------
# Wrapper details are documented
# -------------------------------------------------------------------------

@test "README documents what the wrapper does" {
    grep -q "### What the wrapper does" "${README}"
}
