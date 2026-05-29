# Bash provider functions

BAISH providers will be implemented as sourced Bash files that expose functions using a provider-specific naming convention, such as `provider_copilot_auth`, `provider_copilot_list_models`, and `provider_copilot_chat`. This keeps the V1 implementation simple and idiomatic for Bash while still isolating provider-specific behavior behind a small contract.
