# Atomic file mutation tools

BAISH V1 will implement file mutation tools using atomic writes: prepare the new content in a temporary file in the target directory, then move it into place for both `write` and `edit`. This adds a small amount of Bash complexity to reduce the chance of partially written files if BAISH is interrupted during autonomous file changes.
