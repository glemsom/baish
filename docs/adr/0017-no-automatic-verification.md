# No automatic verification

BAISH V1 will not instruct the model to run tests, builds, or other verification commands unless the developer explicitly asks for verification. This keeps autonomous execution focused on requested work and avoids unexpected long-running or side-effectful commands, accepting that final responses will remain concise and will not call out unrun verification by default.
