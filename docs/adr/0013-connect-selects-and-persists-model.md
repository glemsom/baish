# Connect selects and persists model

BAISH V1 will have `/connect` authenticate the provider and ask the developer to choose a model, then persist that selected model under `~/.baish/` for future sessions. This favors an explicit first-run setup experience over hidden provider defaults, while keeping general configuration limited to environment variables and BAISH-owned state.
