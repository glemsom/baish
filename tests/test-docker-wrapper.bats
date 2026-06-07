#!/usr/bin/env bats
# BAISH — Tests: Docker wrapper function (issue #54)
# These tests verify the baish-wrapper.sh shell function that wraps
# docker run with all necessary bind mounts, env forwarding, and
# UID/GID matching.

setup() {
    BAISH_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
    export BAISH_ROOT

    # Create a temp home to test first-time-user and env forwarding
    TEST_HOME="$(mktemp -d)"
    export TEST_HOME
    export HOME="${TEST_HOME}"

    # Create a fake docker binary that records its invocation
    FAKE_DOCKER_DIR="$(mktemp -d)"
    export FAKE_DOCKER_DIR
    export DOCKER_RECORD_FILE="${FAKE_DOCKER_DIR}/docker-call.txt"
    cat > "${FAKE_DOCKER_DIR}/docker" <<'SCRIPT'
#!/usr/bin/env bash
# Write raw args (no prefix) to record file for test assertions
printf '%s\n' "$*" >> "${DOCKER_RECORD_FILE}"
exit 0
SCRIPT
    chmod +x "${FAKE_DOCKER_DIR}/docker"
    # Prepend fake docker to PATH
    PATH="${FAKE_DOCKER_DIR}:${PATH}"
    export PATH

    # Create common host files/dirs so conditional mounts work
    touch "${HOME}/.gitconfig"
    mkdir -p "${HOME}/.ssh"

    # Remove any pre-existing ~/.baish to test clean-state scenarios
    rm -rf "${HOME}/.baish"

    # Source the wrapper under test
    source "${BAISH_ROOT}/docker/baish-wrapper.sh"
}

teardown() {
    rm -rf "${TEST_HOME}" "${FAKE_DOCKER_DIR}"
}

# -------------------------------------------------------------------------
# Helper: read the docker invocation record
# -------------------------------------------------------------------------
docker_called_with() {
    if [[ -f "${DOCKER_RECORD_FILE}" ]]; then
        cat "${DOCKER_RECORD_FILE}"
    fi
}

# Test: sourcing the file defines a baish shell function
@test "sourcing baish-wrapper.sh defines the baish function" {
    [[ "$(type -t baish)" == "function" ]]
}

# Test: baish pre-creates ~/.baish before running docker
@test "baish pre-creates ~/.baish directory before docker run" {
    # Ensure ~/.baish does not exist initially
    rm -rf "${HOME}/.baish"
    [[ ! -d "${HOME}/.baish" ]]

    # Create a workspace to pass as argument
    local workspace
    workspace="$(mktemp -d)"

    # Run baish (will use fake docker on PATH)
    run baish "${workspace}"

    # ~/.baish must exist now (pre-created by wrapper)
    [[ -d "${HOME}/.baish" ]]

    # docker must have been called
    local recorded
    recorded="$(docker_called_with)"
    echo "docker called with: ${recorded}"
    [[ -n "${recorded}" ]]

    rm -rf "${workspace}"
}

# Test: baish passes --user, --init, --rm, -it in docker run
@test "baish invokes docker run with required flags" {
    local workspace
    workspace="$(mktemp -d)"

    run baish "${workspace}"

    local recorded
    recorded="$(docker_called_with)"
    echo "docker called with: ${recorded}"
    [[ "${recorded}" == "run -it --rm --init "* ]]
    [[ "${recorded}" == *"--user $(id -u):$(id -g)"* ]]
    [[ "${recorded}" == *"-e HOME=/home/baish"* ]]
    [[ "${recorded}" == *"baish:latest"* ]]

    rm -rf "${workspace}"
}

# Test: baish mounts ~/.baish for state persistence
@test "baish mounts ~/.baish for state persistence" {
    local workspace
    workspace="$(mktemp -d)"

    run baish "${workspace}"

    local recorded
    recorded="$(docker_called_with)"
    echo "docker called with: ${recorded}"
    [[ "${recorded}" == *"-v ${HOME}/.baish:/home/baish/.baish"* ]]

    rm -rf "${workspace}"
}

# Test: baish mounts ~/.gitconfig read-only
@test "baish mounts ~/.gitconfig read-only" {
    local workspace
    workspace="$(mktemp -d)"

    run baish "${workspace}"

    local recorded
    recorded="$(docker_called_with)"
    echo "docker called with: ${recorded}"
    [[ "${recorded}" == *"-v ${HOME}/.gitconfig:/home/baish/.gitconfig:ro"* ]]

    rm -rf "${workspace}"
}

# Test: baish mounts ~/.ssh and forwards SSH_AUTH_SOCK
@test "baish forwards SSH agent socket" {
    local workspace
    workspace="$(mktemp -d)"
    local test_sock="${TEST_HOME}/ssh-agent.sock"
    touch "${test_sock}"
    export SSH_AUTH_SOCK="${test_sock}"

    run baish "${workspace}"

    local recorded
    recorded="$(docker_called_with)"
    echo "docker called with: ${recorded}"
    [[ "${recorded}" == *"-v ${test_sock}:/ssh-agent"* ]]
    [[ "${recorded}" == *"-e SSH_AUTH_SOCK=/ssh-agent"* ]]

    unset SSH_AUTH_SOCK
    rm -rf "${workspace}"
}

# Test: baish forwards BAISH_* environment variables
@test "baish forwards BAISH_* environment variables" {
    local workspace
    workspace="$(mktemp -d)"

    # Set test BAISH_* vars
    export BAISH_DEBUG=1
    export BAISH_MAX_TOOL_ROUNDS=10
    export BAISH_BASH_TIMEOUT=300

    run baish "${workspace}"

    local recorded
    recorded="$(docker_called_with)"
    echo "docker called with: ${recorded}"
    [[ "${recorded}" == *"-e BAISH_DEBUG=1"* ]]
    [[ "${recorded}" == *"-e BAISH_MAX_TOOL_ROUNDS=10"* ]]
    [[ "${recorded}" == *"-e BAISH_BASH_TIMEOUT=300"* ]]

    unset BAISH_DEBUG BAISH_MAX_TOOL_ROUNDS BAISH_BASH_TIMEOUT
    rm -rf "${workspace}"
}

# Test: baish forwards TERM, COLUMNS, LINES
@test "baish forwards terminal environment variables" {
    local workspace
    workspace="$(mktemp -d)"

    export TERM=xterm-256color
    export COLUMNS=120
    export LINES=40

    run baish "${workspace}"

    local recorded
    recorded="$(docker_called_with)"
    echo "docker called with: ${recorded}"
    [[ "${recorded}" == *"-e TERM=xterm-256color"* ]]
    [[ "${recorded}" == *"-e COLUMNS=120"* ]]
    [[ "${recorded}" == *"-e LINES=40"* ]]

    unset TERM COLUMNS LINES
    rm -rf "${workspace}"
}

# Test: baish uses current directory as workspace when no argument given
@test "baish defaults to PWD as workspace when no argument" {
    local original_dir
    original_dir="$(mktemp -d)"
    mkdir -p "${original_dir}"

    # Run baish from the temp directory with no arguments
    cd "${original_dir}"
    run baish

    local recorded
    recorded="$(docker_called_with)"
    echo "docker called with: ${recorded}"
    [[ "${recorded}" == *"-v ${original_dir}:/workspace"* ]]

    rm -rf "${original_dir}"
}

# Test: baish passes workspace path as container argument
@test "baish passes workspace path as container argument" {
    local workspace
    workspace="$(mktemp -d)"

    run baish "${workspace}"

    local recorded
    recorded="$(docker_called_with)"
    echo "docker called with: ${recorded}"
    # The last argument should be /workspace (the dir inside container)
    [[ "${recorded}" == *" /workspace" ]]

    rm -rf "${workspace}"
}

# Test: concurrent sessions in different directories use same image but
# different workspace bind mounts (non-interference)
@test "concurrent baish sessions use correct workspace directories" {
    local dir_a
    dir_a="$(mktemp -d)"
    local dir_b
    dir_b="$(mktemp -d)"

    # Clear record
    rm -f "${DOCKER_RECORD_FILE}"

    # Run baish from dir_a
    cd "${dir_a}"
    run baish
    local recorded_a
    recorded_a="$(docker_called_with)"
    echo "session A docker called with: ${recorded_a}"
    [[ "${recorded_a}" == *"-v ${dir_a}:/workspace"* ]]

    # Clear and run from dir_b
    rm -f "${DOCKER_RECORD_FILE}"
    cd "${dir_b}"
    run baish
    local recorded_b
    recorded_b="$(docker_called_with)"
    echo "session B docker called with: ${recorded_b}"
    [[ "${recorded_b}" == *"-v ${dir_b}:/workspace"* ]]

    rm -rf "${dir_a}" "${dir_b}"
}

# Test: baish returns error for non-existent directory
@test "baish returns error for non-existent directory" {
    run baish "/nonexistent/path/12345"

    [[ "${status}" -ne 0 ]]
    [[ "${output}" == *"directory not found"* ]]
}

# Test: baish passes --privileged for Docker-in-Docker support
@test "baish passes --privileged for Docker-in-Docker" {
    local workspace
    workspace="$(mktemp -d)"

    run baish "${workspace}"

    local recorded
    recorded="$(docker_called_with)"
    echo "docker called with: ${recorded}"
    [[ "${recorded}" == *"--privileged"* ]]

    rm -rf "${workspace}"
}

# Test: baish mounts named volumes for package manager caches
@test "baish mounts named volumes for package caches" {
    local workspace
    workspace="$(mktemp -d)"

    run baish "${workspace}"

    local recorded
    recorded="$(docker_called_with)"
    echo "docker called with: ${recorded}"
    [[ "${recorded}" == *"-v baish-npm-cache:/home/baish/.npm"* ]]
    [[ "${recorded}" == *"-v baish-pip-cache:/home/baish/.cache/pip"* ]]
    [[ "${recorded}" == *"-v baish-cargo-cache:/home/baish/.cargo/registry"* ]]

    rm -rf "${workspace}"
}
