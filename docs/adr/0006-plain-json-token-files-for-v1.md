# Plain JSON token files for V1

BAISH V1 will persist provider credentials as plain JSON token files under `~/.baish/`, with token files created using restrictive permissions such as `chmod 600`. This is a deliberate simplicity trade-off for a Bash-first tool; OS keychain integration or encrypted credential storage can be added later if the project needs stronger local secret handling.
