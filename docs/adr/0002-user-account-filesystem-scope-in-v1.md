# User account filesystem scope in V1

BAISH V1 will allow model-requested file and shell tools to operate anywhere the launching user account has permission, rather than limiting access to the current working directory or Git repository. This keeps the Bash implementation and agent behavior straightforward for V1, while intentionally accepting a larger safety boundary because BAISH is designed as a fully autonomous coding agent.
