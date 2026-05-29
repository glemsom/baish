# Copilot device flow with BAISH state directory

BAISH V1 will authenticate GitHub Copilot using an interactive device code flow and persist the resulting provider auth state under `~/.baish/` for reuse in later sessions. This avoids depending on GitHub CLI while giving `/connect` a terminal-native authentication experience and a clear home for BAISH-owned state.
