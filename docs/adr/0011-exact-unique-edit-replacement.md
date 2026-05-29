# Exact unique edit replacement

BAISH V1 will implement the `edit` tool as an exact text replacement that succeeds only when the requested `oldText` appears exactly once in the target file. This favors deterministic, reviewable edits over line-range, regex, or patch application, and forces the model to read enough surrounding context before changing a file.
