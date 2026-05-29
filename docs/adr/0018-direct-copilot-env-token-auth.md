# Direct Copilot auth from GH_TOKEN or GITHUB_TOKEN

BAISH V1 will prefer `GH_TOKEN`, then `GITHUB_TOKEN`, as direct bearer auth for `https://api.githubcopilot.com` when either is present, skipping the `/copilot_internal/v2/token` exchange and avoiding device-flow prompts in `/connect`. In this env-token mode BAISH persists metadata-only Copilot auth state under `~/.baish/auth/copilot.json` without storing the env secret, while preserving the existing device-flow path for sessions where no env token is available.
