---
status: superseded by ADR-0019
---

# Copilot provider behind provider interface

BAISH V1 originally supported GitHub Copilot as the only real provider, with the agent loop calling it through a provider interface rather than hardcoding Copilot details throughout the codebase. That decision established the provider boundary, but its Copilot-only scope is now superseded by ADR-0019, which generalizes BAISH to validated dynamic multi-provider discovery.
