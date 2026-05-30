# BAISH

BAISH is a terminal AI coding agent. This context captures the product language used to talk about how BAISH connects to external AI services and chooses which one is currently in effect.

## Language

**Provider**:
A backend that BAISH can connect to and use for model listing, authentication, and chat. A Provider may be an external AI service or a local development backend.
_Avoid_: backend, integration, vendor

**Selected Provider**:
The Provider BAISH will use by default until the developer chooses a different one.
_Avoid_: temporary provider, current backend

**Active Provider**:
The Provider currently in effect for this BAISH process.
_Avoid_: selected provider, connected provider

**Provider Switch**:
An explicit developer action that changes the Active Provider now and updates the Selected Provider used by default in future runs.
_Avoid_: temporary switch, connect only

**Provider Credentials**:
The secret or token BAISH uses to authenticate to a Provider.
_Avoid_: session transcript, model selection

**Provider Discovery**:
The mechanism BAISH uses to find which Providers are available without relying on a fixed built-in list.
_Avoid_: hardcoded registry, manual list only

**Provider Metadata**:
The explicit descriptive data a Provider exposes so BAISH can discover it and present it safely in the provider picker.
_Avoid_: filename-only discovery, implicit guessing

**Provider Picker**:
The interactive list BAISH shows when the developer runs `/provider` to choose a Provider.
_Avoid_: hardcoded menu, model picker

**Provider Validation**:
A small authenticated request BAISH uses to confirm that Provider Credentials and the chosen model are actually usable.
_Avoid_: model listing, optimistic connection

**Selectable Provider**:
A Provider that appears in the Provider Picker and can be chosen directly by the developer.
_Avoid_: hidden provider, invalid provider

**Kilo Gateway**:
The Kilo Provider exposed through BAISH. It is an OpenAI-compatible gateway that lists models through its own model catalog and authenticates with Provider Credentials.
_Avoid_: Kilo Code Gateway, Kilo AI Gateway

**Provider ID**:
The unique stable identifier a Provider exposes in Provider Metadata and uses in its function prefix, auth state, and selection flow.
_Avoid_: duplicate ID, display label

**Interactive Override**:
An explicit in-session developer choice that takes precedence over process defaults for the current BAISH process.
_Avoid_: startup default, silent fallback

## Example dialogue

- Dev: "Which Provider is BAISH using right now?"
- Domain expert: "Check the Active Provider for this process."
- Dev: "If I switch to another one, what happens next time I launch BAISH?"
- Domain expert: "The newly Selected Provider becomes the default for future runs."