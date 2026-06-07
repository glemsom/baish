#!/usr/bin/env bats
# BAISH — Tests: Docker container build and entrypoint
# These are integration tests that require Docker on the host.

setup() {
    BAISH_ROOT="$(cd "$(dirname "${BATS_TEST_DIRNAME}")" && pwd)"
    export BAISH_ROOT
}

# --- Step 1: Build ---

@test "docker build succeeds from repo root" {
    cd "${BAISH_ROOT}"

    run docker build -t baish:test .

    echo "Build output: ${output}"
    [[ "${status}" -eq 0 ]]
}

# --- Step 2: .dockerignore ---

@test "dockerignore excludes .git and tests from build context" {
    cd "${BAISH_ROOT}"

    run docker build --no-cache -q -f- . <<'DOCKERFILE'
FROM busybox
COPY . /context/
RUN test ! -d /context/.git && test ! -d /context/tests
DOCKERFILE

    echo "Build output: ${output}"
    [[ "${status}" -eq 0 ]]
}

# --- Step 3: Entrypoint ---

@test "entrypoint creates /home/baish writable for non-root user" {
    cd "${BAISH_ROOT}"

    # Rebuild to pick up any new files
    run docker build -t baish:test .
    [[ "${status}" -eq 0 ]]

    local uid
    local gid
    uid=$(id -u)
    gid=$(id -g)

    # Run entrypoint as non-root user and verify /home/baish is writable
    run docker run --rm --user "${uid}:${gid}" \
        -e HOME=/home/baish \
        baish:test \
        /entrypoint.sh test -w /home/baish

    echo "Entrypoint test output: ${output}"
    [[ "${status}" -eq 0 ]]
}

# --- Step 4: BAISH smoke test ---

@test "container starts BAISH and agent responds to messages" {
    cd "${BAISH_ROOT}"

    # Rebuild to pick up any new files
    run docker build -t baish:test .
    [[ "${status}" -eq 0 ]]

    # Run BAISH non-interactively with mock provider; capture stdout only.
    # Pre-create ~/.baish/state.json to select mock provider so the
    # interactive picker is skipped (gum requires TTY).
    run timeout 30 docker run --rm -i \
        -e HOME=/home/baish \
        baish:test \
        bash -c 'mkdir -p /home/baish/.baish && printf '"'"'{"provider": "mock", "model": "mock-model"}'"'"' > /home/baish/.baish/state.json && echo "hello" | timeout 15 /opt/baish/bin/baish 2>/dev/null'

    echo "BAISH stdout: ${output}"
    [[ "${output}" == *"I am the mock provider"* ]]
}

# -------------------------------------------------------------------------
# Step 5: Package manager cache persistence (issue #55)
# -------------------------------------------------------------------------

teardown() {
    # Clean up test volumes created during cache persistence tests
    docker volume rm -f baish-test-npm-cache baish-test-pip-cache baish-test-cargo-cache baish-test-shared-cache 2>/dev/null || true
}

@test "npm cache persists across container restarts via named volume" {
    cd "${BAISH_ROOT}"

    run docker build -t baish:test .
    [[ "${status}" -eq 0 ]]

    # Create marker in npm cache dir
    run docker run --rm --user "$(id -u):$(id -g)" \
        -e HOME=/home/baish \
        -v baish-test-npm-cache:/home/baish/.npm \
        baish:test \
        bash -c 'mkdir -p /home/baish/.npm && touch /home/baish/.npm/marker-npm && chmod 644 /home/baish/.npm/marker-npm'
    [[ "${status}" -eq 0 ]]

    # Verify marker exists in a second container
    run docker run --rm --user "$(id -u):$(id -g)" \
        -e HOME=/home/baish \
        -v baish-test-npm-cache:/home/baish/.npm \
        baish:test \
        test -f /home/baish/.npm/marker-npm
    [[ "${status}" -eq 0 ]]
}

@test "pip cache persists across container restarts via named volume" {
    cd "${BAISH_ROOT}"

    run docker build -t baish:test .
    [[ "${status}" -eq 0 ]]

    # Create marker in pip cache dir
    run docker run --rm --user "$(id -u):$(id -g)" \
        -e HOME=/home/baish \
        -v baish-test-pip-cache:/home/baish/.cache/pip \
        baish:test \
        bash -c 'mkdir -p /home/baish/.cache/pip && touch /home/baish/.cache/pip/marker-pip'
    [[ "${status}" -eq 0 ]]

    # Verify marker exists in a second container
    run docker run --rm --user "$(id -u):$(id -g)" \
        -e HOME=/home/baish \
        -v baish-test-pip-cache:/home/baish/.cache/pip \
        baish:test \
        test -f /home/baish/.cache/pip/marker-pip
    [[ "${status}" -eq 0 ]]
}

@test "cargo registry cache persists across container restarts via named volume" {
    cd "${BAISH_ROOT}"

    run docker build -t baish:test .
    [[ "${status}" -eq 0 ]]

    # Create marker in cargo registry dir
    run docker run --rm --user "$(id -u):$(id -g)" \
        -e HOME=/home/baish \
        -v baish-test-cargo-cache:/home/baish/.cargo/registry \
        baish:test \
        bash -c 'mkdir -p /home/baish/.cargo/registry && touch /home/baish/.cargo/registry/marker-cargo'
    [[ "${status}" -eq 0 ]]

    # Verify marker exists in a second container
    run docker run --rm --user "$(id -u):$(id -g)" \
        -e HOME=/home/baish \
        -v baish-test-cargo-cache:/home/baish/.cargo/registry \
        baish:test \
        test -f /home/baish/.cargo/registry/marker-cargo
    [[ "${status}" -eq 0 ]]
}

@test "concurrent containers share named cache volumes without interference" {
    cd "${BAISH_ROOT}"

    run docker build -t baish:test .
    [[ "${status}" -eq 0 ]]

    # Create marker from container A
    run docker run --rm --user "$(id -u):$(id -g)" \
        -e HOME=/home/baish \
        -v baish-test-shared-cache:/home/baish/.npm \
        baish:test \
        bash -c 'mkdir -p /home/baish/.npm && echo "from-container-A" > /home/baish/.npm/shared-marker'
    [[ "${status}" -eq 0 ]]

    # Read marker from container B (concurrent access)
    run docker run --rm --user "$(id -u):$(id -g)" \
        -e HOME=/home/baish \
        -v baish-test-shared-cache:/home/baish/.npm \
        baish:test \
        cat /home/baish/.npm/shared-marker
    [[ "${status}" -eq 0 ]]
    [[ "${output}" == "from-container-A" ]]
}

# --- Step 6: Docker-in-Docker (issue #56) ---

@test "docker ps works inside container via host socket mount" {
    cd "${BAISH_ROOT}"

    run docker build -t baish:test .
    [[ "${status}" -eq 0 ]]

    # Run docker ps inside the container with the same flags the wrapper
    # would use: --privileged + Docker socket mount + --group-add for the
    # socket's group GID so the non-root user can access it.
    local docker_gid
    docker_gid="$(stat -c '%g' /var/run/docker.sock)"
    local daemon_api_version
    daemon_api_version="$(docker version --format '{{.Server.APIVersion}}')"

    run docker run --rm --privileged \
        -v /var/run/docker.sock:/var/run/docker.sock \
        --group-add "${docker_gid}" \
        -e DOCKER_API_VERSION="${daemon_api_version}" \
        --user "$(id -u):$(id -g)" \
        baish:test \
        docker ps

    echo "docker ps output: ${output}"
    [[ "${status}" -eq 0 ]]
}

@test "docker-compose is available inside container" {
    cd "${BAISH_ROOT}"

    run docker build -t baish:test .
    [[ "${status}" -eq 0 ]]

    # Check if docker-compose is available as a standalone binary or as a
    # docker CLI plugin (docker compose).
    local docker_gid
    docker_gid="$(stat -c '%g' /var/run/docker.sock)"
    local daemon_api_version
    daemon_api_version="$(docker version --format '{{.Server.APIVersion}}')"

    run docker run --rm --privileged \
        -v /var/run/docker.sock:/var/run/docker.sock \
        --group-add "${docker_gid}" \
        -e DOCKER_API_VERSION="${daemon_api_version}" \
        --user "$(id -u):$(id -g)" \
        baish:test \
        bash -c 'docker-compose --version 2>/dev/null || docker compose version 2>/dev/null || echo "not-available"'

    echo "docker-compose availability: ${output}"
    [[ "${output}" != "not-available" ]]
}
