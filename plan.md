# Implementation plan

## Goal

Add dynamic multi-provider support to BAISH, introduce the interactive `/provider` command, and add Kilo Gateway as a first-class provider.

## Constraints and agreed behavior

- Providers are discovered dynamically from `lib/providers/*.sh`
- All provider files are sourced once at startup
- Discovery is cached for the process
- Startup fails fast if:
  - a provider file is invalid
  - required metadata is missing/invalid
  - required provider actions are missing
  - two providers share the same `id`
  - filename stem, metadata `id`, and function prefix do not match
  - zero selectable providers are found
- Each provider file defines exactly one provider
- Provider metadata is returned by `provider_<id>_metadata` as JSON
- Required metadata fields:
  - `id`
  - `label`
  - `description`
  - `selectable`
- Extra metadata fields are allowed
- `/provider` is an interactive picker like `/model`
- `/provider:<name>` fails with a helpful message
- `/provider`, `/connect`, and `/model` perform transactional reconfiguration
- Successful provider/model reconfiguration starts a fresh chat
- Same provider/model selection is a no-op unless setup is broken and repaired
- Trailing chat text after `/provider` is sent only if the switch succeeds
- Kilo Gateway uses prompted hidden API-key entry, persisted to `~/.baish/auth/kilo.json`
- `KILO_API_KEY` overrides saved Kilo auth for the current process only
- Kilo uses:
  - `GET https://api.kilo.ai/api/gateway/models`
  - `POST https://api.kilo.ai/api/gateway/chat/completions`
- Kilo tool calling is enabled from day one
- Kilo validation uses the exact selected model and a tiny `chat/completions` request with prompt `Respond with exactly: OK`
- Any successful HTTP 200 validation response counts as success

## Step 1: provider discovery and startup loading

Update startup/provider infrastructure so BAISH can discover providers dynamically.

Files:
- `lib/main.sh`
- new helper module if needed, likely `lib/providers.sh`

Tasks:
- Add provider discovery helper(s) that:
  - enumerate `lib/providers/*.sh`
  - source each file
  - call `provider_<id>_metadata`
  - validate metadata shape and required fields
  - validate filename stem = metadata `id` = function prefix
  - validate required provider functions exist: metadata, auth, list_models, chat
  - detect duplicate ids
  - cache normalized provider metadata for process use
- Replace hardcoded provider sourcing in `lib/main.sh` with dynamic loading
- Fail startup fast with clear error messages on discovery/contract violations

## Step 2: generic secret prompt helper

Add a reusable hidden-input helper for provider credentials.

Files:
- likely new helper in `lib/readline.sh` or a small new module such as `lib/prompt.sh`
- `lib/main.sh` to source it if needed

Tasks:
- Add generic secret prompt function that:
  - prints a prompt
  - reads hidden input without echo
  - restores terminal state safely
  - returns cancellation/failure cleanly
- Keep it small and provider-agnostic

## Step 3: interactive provider picker

Implement `/provider` as an interactive provider switcher.

Files:
- `lib/slash.sh`
- `lib/main.sh`
- `README.md`
- tests in `test/readline_slash.bats`

Tasks:
- Extend slash parsing to recognize `/provider`
- Add helpful explicit error for `/provider:<name>`
- Add provider completion candidate for `/provider`
- Add provider picker helper using cached discovered metadata
- Row format should include:
  - label
  - id
  - description
  - `(active)` marker when applicable
- Sort selectable providers case-insensitively by label
- Show only `selectable: true` providers in the picker
- On picker cancel:
  - print `Provider selection cancelled.`
  - make no changes
- Update startup header and README command docs to include `/provider`

## Step 4: transactional provider/model reconfiguration

Refactor reconfiguration flow so provider and model changes are applied only after success.

Files:
- `lib/slash.sh`
- `lib/agent.sh`
- `lib/state.sh`
- tests in:
  - `test/readline_slash.bats`
  - `test/state_logging.bats`

Tasks:
- Add a transactional switch flow for `/provider`:
  1. choose provider
  2. if same provider and setup healthy, no-op
  3. otherwise connect/authenticate selected provider
  4. choose model
  5. validate provider/model if provider requires it
  6. persist provider/model
  7. override in-process active provider/model
  8. reset conversation messages
  9. keep loaded skills
  10. send trailing text as first message if present
- Make `/connect` reconnect the active provider and choose a model
- Make `/model` reselect the active provider model
- For `/connect` and `/model`, successful actual reconfiguration should also reset the chat
- Same-provider/model no-op should preserve current chat
- Ensure explicit interactive provider/model choice overrides `BAISH_PROVIDER` / `BAISH_MODEL` for the current process
- Keep env credentials authoritative for the current process when present

## Step 5: Kilo Gateway provider

Add `lib/providers/kilo.sh` implementing the provider contract.

Files:
- new `lib/providers/kilo.sh`
- tests, likely new `test/kilo_provider.bats`

Tasks:
- Implement `provider_kilo_metadata` returning JSON with at least:
  - `id: "kilo"`
  - `label: "Kilo Gateway"`
  - `description: "OpenAI-compatible gateway with broad model catalog"`
  - `selectable: true`
  - `auth_env_var: "KILO_API_KEY"`
- Implement auth flow:
  - prefer `KILO_API_KEY` for current process
  - if env key absent, try saved key from `~/.baish/auth/kilo.json`
  - if no saved key, prompt with hidden input: `Enter Kilo API key:`
  - on saved-key rejection, prompt retry with helpful message
  - if env key is invalid, fail fast and do not prompt around it
  - only overwrite saved auth after successful validation
- Implement model listing:
  - `GET https://api.kilo.ai/api/gateway/models`
  - normalize OpenAI-compatible model response
  - show human-friendly name first, persist exact model id
  - expose all returned models
- Implement chat:
  - `POST https://api.kilo.ai/api/gateway/chat/completions`
  - OpenAI-style tools/tool_choice/parallel_tool_calls
  - parse assistant tool calls and text from OpenAI-compatible response
- Implement validation helper:
  - validate exact selected model with minimal request
  - prompt text: `Respond with exactly: OK`
  - any HTTP 200 counts as success
  - auth failure => keep selected model, re-prompt key
  - non-auth model/access failure => keep credentials, re-pick model

## Step 6: provider metadata for existing providers

Retrofit existing providers to satisfy the metadata contract.

Files:
- `lib/providers/copilot.sh`
- `lib/providers/mock.sh`
- tests

Tasks:
- Add `provider_copilot_metadata`
- Add `provider_mock_metadata`
- Ensure required functions exist and align with discovery validation
- Decide/select descriptions and labels that fit the picker

## Step 7: state and active process behavior

Keep persisted state compatible while making in-process overrides explicit.

Files:
- `lib/state.sh`
- `lib/slash.sh`
- tests

Tasks:
- Preserve current global selected model behavior for now
- Continue using `~/.baish/state.json` for selected provider/model persistence
- Ensure successful interactive selection updates process-active provider/model regardless of startup env defaults
- Keep `~/.baish/auth/kilo.json` untouched when env auth is used successfully

## Step 8: tests

Add and update tests to lock in the agreed behavior.

Files:
- `test/readline_slash.bats`
- `test/state_logging.bats`
- `test/mock_provider.bats`
- new `test/kilo_provider.bats`
- possibly startup/discovery coverage in a new focused bats file

Test coverage to add:
- dynamic provider discovery succeeds for valid providers
- startup fails on:
  - duplicate ids
  - missing metadata
  - empty metadata fields
  - missing required provider functions
  - filename/id/prefix mismatch
  - zero selectable providers
- `/provider` picker behavior
- `/provider:<name>` helpful error
- selectable-only provider list
- case-insensitive label sort
- active provider marker formatting
- transactional success/failure/cancel behavior
- trailing text behavior after `/provider`
- same-provider healthy no-op
- same-provider broken repaired => fresh chat
- `/connect` and `/model` fresh-chat behavior on real reconfiguration
- Kilo env override precedence
- Kilo saved-key fallback
- Kilo prompt/cancel behavior
- Kilo validation auth retry and model re-pick behavior
- Kilo tool-calling response normalization

## Step 9: docs polish

Align user docs with the new architecture.

Files:
- `README.md`
- possibly additional ADR edits if needed

Tasks:
- Document `/provider`
- Document dynamic provider behavior at a high level
- Document Kilo Gateway setup and `KILO_API_KEY`
- Update any README references that still imply Copilot is the only real provider
- Keep ADR-0019 and ADR-0003 consistent with implementation

## Verification

After implementation, run at least:

```bash
bats test/*.bats
bash -n bin/baish lib/*.sh lib/providers/*.sh test/test_helper.bash
```

If provider-specific tests are split out, run those directly as well.

## Suggested implementation order

1. provider discovery helper + startup loading
2. metadata functions for existing providers
3. `/provider` picker plumbing
4. transactional reconfiguration cleanup
5. generic secret prompt helper
6. Kilo provider
7. tests
8. README/doc updates
