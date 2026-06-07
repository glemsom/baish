#!/usr/bin/env bash
# BAISH — Docker container entrypoint
# Creates /home/baish with correct ownership for the runtime --user,
# then hands off to the BAISH process (or any CMD).

set -e

HOME_DIR="${HOME:-/home/baish}"

# Create the home directory if it doesn't exist, owned by the current user.
# When --user is passed to docker run, the container's uid:gid may differ
# from the image's predefined baish user — we chown to whatever uid:gid
# the container is running as.
if [[ ! -d "${HOME_DIR}" ]]; then
    mkdir -p "${HOME_DIR}"
fi

# Ensure the home directory is owned by the current user/group.
# If /home/baish already exists as a bind mount from the host, this
# ensures the current user can write to it regardless of the owner on disk.
chown "$(id -u):$(id -g)" "${HOME_DIR}" 2>/dev/null || true

# Hand off to the command
exec "$@"
