# Provider-native tool calling

BAISH V1 will use provider-native tool/function calling as the intended protocol for model-requested tools, with the Copilot implementation required to verify the exact supported request and response format during implementation. This avoids brittle text parsing and keeps tool execution structurally separated from assistant prose, while accepting that Copilot-specific research is needed before final wiring.
