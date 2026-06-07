#!/usr/bin/env bash
# BAISH — Docker wrapper function
# Source this file to get a `baish` shell function that launches
# BAISH inside a Docker container with proper bind mounts, UID/GID
# matching, and environment forwarding.
#
# Usage:
#   source docker/baish-wrapper.sh
#   baish [directory]

baish() {
    local dir="${1:-$PWD}"

    # Ensure directory exists
    if [[ ! -d "${dir}" ]]; then
        echo "baish: directory not found: ${dir}" >&2
        return 1
    fi

    # Pre-create ~/.baish on the host so the bind mount doesn't
    # create a root-owned directory (first-time user support).
    mkdir -p "${HOME}/.baish"

    # Collect forwarded environment variables (BAISH_* + terminal vars)
    local env_flags=()

    # Forward HOME (for UID/GID matching the baish user in container)
    env_flags+=(-e HOME=/home/baish)

    # Forward terminal variables
    env_flags+=(-e TERM="${TERM:-xterm-256color}")
    if [[ -n "${COLUMNS:-}" ]]; then
        env_flags+=(-e COLUMNS="${COLUMNS}")
    fi
    if [[ -n "${LINES:-}" ]]; then
        env_flags+=(-e LINES="${LINES}")
    fi

    # Forward all BAISH_* environment variables from the host
    local line
    while IFS= read -r line; do
        if [[ "${line}" == BAISH_* ]]; then
            env_flags+=(-e "${line}")
        fi
    done < <(env)

    # Forward SSH_AUTH_SOCK
    if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
        env_flags+=(-v "${SSH_AUTH_SOCK}:/ssh-agent" -e SSH_AUTH_SOCK=/ssh-agent)
    fi

    # Build bind mount flags (only mount paths that exist on the host
    # to avoid docker creating root-owned directories)
    local mount_flags=()
    mount_flags+=(-v "${HOME}/.baish:/home/baish/.baish")
    mount_flags+=(-v "${dir}:/workspace")
    if [[ -f "${HOME}/.gitconfig" ]]; then
        mount_flags+=(-v "${HOME}/.gitconfig:/home/baish/.gitconfig:ro")
    fi
    if [[ -d "${HOME}/.ssh" ]]; then
        mount_flags+=(-v "${HOME}/.ssh:/home/baish/.ssh:ro")
    fi
    mount_flags+=(-v "baish-npm-cache:/home/baish/.npm")
    mount_flags+=(-v "baish-pip-cache:/home/baish/.cache/pip")
    mount_flags+=(-v "baish-cargo-cache:/home/baish/.cargo/registry")

    # Mount the host Docker socket for Docker-in-Docker support (if available).
    # This lets the agent run docker and docker-compose commands on the host's
    # Docker daemon from inside the container.
    if [[ -S /var/run/docker.sock ]]; then
        mount_flags+=(-v /var/run/docker.sock:/var/run/docker.sock)

        # Add the Docker socket's group as a supplementary group so the
        # non-root container user can read/write the socket. The GID is
        # detected dynamically from the host's socket file.
        local docker_gid
        docker_gid="$(stat -c '%g' /var/run/docker.sock 2>/dev/null)"
        if [[ -n "${docker_gid}" ]]; then
            mount_flags+=(--group-add "${docker_gid}")
        fi

        # Forward the host Docker daemon API version so the client inside
        # the container negotiates the correct protocol version, avoiding
        # client/daemon version mismatches.
        local daemon_api_version
        daemon_api_version="$(docker version --format '{{.Server.APIVersion}}' 2>/dev/null)"
        if [[ -n "${daemon_api_version}" ]]; then
            env_flags+=(-e DOCKER_API_VERSION="${daemon_api_version}")
        fi
    fi

    # Build and run the docker command.
    # NOTE: --privileged enables host escape via the Docker socket, so this
    # is blast-radius reduction, not a security sandbox. See README.
    docker run \
        -it \
        --rm \
        --init \
        --privileged \
        --user "$(id -u):$(id -g)" \
        "${env_flags[@]}" \
        "${mount_flags[@]}" \
        baish:latest \
        /workspace
}
