# Debug metadata without transcripts

BAISH V1 will not persist conversation transcripts by default, and `BAISH_DEBUG=1` will log internal events and provider metadata rather than full prompts, responses, or tool outputs. This supports troubleshooting Copilot and agent-loop behavior while avoiding accidental persistence of user code, chat history, or secrets.
