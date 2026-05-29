# Untruncated tool results

BAISH V1 will return complete tool output to the model rather than truncating or summarizing large reads and command results. This keeps tool behavior transparent and avoids hidden loss of information, while accepting that oversized results may exceed a provider context window; in that case BAISH should fail visibly with its own error instead of silently dropping or rewriting context.
