# Cache-friendly context layout

BAISH V1 will build model requests with a stable prefix followed by session-specific content: base system prompt, tool definitions, provider instructions, explicitly loaded skills, then the current conversation. This preserves user control over context while making repeated requests more likely to benefit from provider-side token caching when the unchanged prefix remains byte-stable across turns.
