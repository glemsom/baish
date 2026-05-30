# Status Footer plan for BAISH

## Goal

Add an interactive-only idle-state **Status Footer** to `baish` so that:
- the input line is directly above the footer while BAISH is idle
- the footer is visible on the first idle screen after startup
- the footer is redrawn whenever BAISH returns to the idle input state
- the footer reflows on `SIGWINCH`
- the footer shows:
  - **Launch Directory** as a home-shortened absolute path
  - **Provider Label**
  - **Model ID**
- the footer uses explicit fallbacks when values cannot be resolved

Target visual shape:

```text
❯
───────────────────────────────────────────────────
~/project · GitHub Copilot · gpt-5
```

## Progress

- [x] Phase 1 complete: added `lib/footer.sh`, sourced it from `lib/main.sh`, and covered the new footer helpers with `test/footer.bats`.
- [x] Phase 2 complete: replaced baseline whole-line clipping with deterministic per-field truncation in Launch Directory → Model ID → Provider Label order, with focused formatter tests in `test/footer.bats`.
- [x] Phase 3 complete: added explicit idle-screen lifecycle helpers in `lib/readline.sh` (`draw`, `leave`, `redraw`) and covered their terminal-control output in `test/readline_slash.bats`.
- [x] Phase 4 complete: integrated the idle-screen lifecycle into `baish_readline_loop`, including first-idle draw, leave-before-processing, redraw-on-return, interrupt recovery redraw, and interactive cleanup coverage in `test/readline_slash.bats`.
- [x] Phase 5 complete: added a `SIGWINCH` redraw path in `lib/readline.sh` using the current idle prompt state, plus focused handler coverage and a PTY-backed resize trap test in `test/readline_slash.bats`.
- [x] Phase 6 complete: footer rendering now refreshes provider/model from existing active-state sources at draw time, with focused state-refresh coverage in `test/footer.bats` and an interactive redraw regression in `test/readline_slash.bats`.
- [x] Phase 7 complete: footer redraw/render now degrades to explicit fallback footer content instead of failing, with regression coverage in `test/footer.bats` and `test/readline_slash.bats`.
- [x] Phase 8 complete: added launcher-level regression coverage for interactive startup footer rendering and confirmed the footer stays absent in non-interactive mode in `test/mock_provider.bats`.
- [x] Phase 9 complete: documented the shipped interactive Status Footer behavior, fallbacks, and redraw rules in `README.md`.

## Resolved product decisions

- Footer is **idle-state only**, not a full-screen pinned TUI.
- Footer is **interactive-only**. Non-interactive mode stays unchanged.
- Startup header **stays**. Footer appears on the first idle screen after it.
- Directory shown is the **Launch Directory** captured at startup.
- Directory rendering is **home-shortened absolute path**.
- Provider display uses **Provider Label**.
- Model display uses **Model ID**.
- Empty model renders as **`no model`**.
- Unknown provider label renders as **`unknown provider`**.
- Missing launch dir fallback is **`?`**.
- Footer stays **one line** and truncates fields instead of wrapping.
- Truncation priority: truncate **Launch Directory** first, then **Model ID**, then **Provider Label**.
- Divider is full terminal width, uses **`─`**, and has no side padding.
- Footer redraw rule: redraw whenever BAISH returns to the **Idle Input State**.
- On terminal resize, footer should **reflow on `SIGWINCH`**.
- During multiline drafting, the draft grows upward and the **active last input line** remains directly above the footer.

## Existing code touchpoints

- `lib/main.sh`
  - already sets `BAISH_ACTIVE_PROVIDER`
  - already sets `BAISH_ACTIVE_MODEL`
  - already sets `BAISH_LAUNCH_CWD`
  - prints the startup header before entering `baish_readline_loop`
- `lib/readline.sh`
  - owns the interactive loop
  - currently uses `read -e -r -p "$prompt"`
  - currently has no footer lifecycle and no `SIGWINCH` handling
- `lib/providers.sh`
  - already exposes provider metadata with `label`
- `lib/state.sh`
  - allows Active Model to be empty
- `test/readline_slash.bats`
  - already covers readline behavior and is the most natural place for new footer tests
- `test/prompt.bats`
  - shows how to use `script` for PTY-backed tests

## Implementation approach

### 1. Add footer-specific helpers ✅

Create a new module, preferably `lib/footer.sh`, and source it from `lib/main.sh`.

Keep footer logic out of `lib/readline.sh` as much as possible so redraw and formatting rules stay isolated.

Recommended helpers:

- `baish_footer_terminal_width`
  - derive width from `COLUMNS`
  - fallback to a sane width if `COLUMNS` is unset/invalid
- `baish_footer_home_shorten_path`
  - convert `/home/user/x` to `~/x`
- `baish_footer_launch_directory_text`
  - read from `BAISH_LAUNCH_CWD`
  - fallback to `?`
- `baish_footer_provider_label_text`
  - resolve `BAISH_ACTIVE_PROVIDER`
  - call `baish_provider_metadata_json` if possible
  - extract `.label`
  - fallback to `unknown provider`
- `baish_footer_model_text`
  - use `BAISH_ACTIVE_MODEL`
  - fallback to `no model`
- `baish_footer_divider_line`
  - emit exactly terminal-width `─` characters
- `baish_footer_format_status_line`
  - join `dir · provider · model`
  - enforce one-line truncation policy
- `baish_footer_render_lines`
  - produce the two footer lines: divider + status line

### 2. Implement one-line truncation deterministically ✅

Do not let terminal wrapping decide layout.

Implement a helper that:
- computes available width for the status line
- preserves both separators ` · ` when possible
- truncates fields with an ellipsis
- truncates in this order:
  1. Launch Directory
  2. Model ID
  3. Provider Label

Notes for the agent:
- keep the algorithm deterministic and unit-testable
- avoid field dropping and avoid wrapping
- if width is extremely small, still return a single line clipped to width

### 3. Introduce explicit footer lifecycle in the interactive readline loop ✅

`read -p` alone is not enough anymore because the input must sit **above** the footer.

The implementation should add explicit lifecycle helpers in or around `lib/readline.sh`:
- draw footer before entering an idle read
- clear/move past footer before BAISH prints non-idle output
- redraw footer after BAISH returns to idle

Recommended helper responsibilities:
- `baish_readline_draw_idle_screen`
  - render prompt line position
  - render divider + footer below it
  - place the cursor back on the input line
- `baish_readline_leave_idle_screen`
  - remove or move past the footer region before slash/agent output starts
- `baish_readline_redraw_idle_screen`
  - used after slash commands, agent completion, agent failure, interrupt recovery, and resize

Important design constraint:
- preserve the existing multiline-draft model based on repeated reads and continuation handling
- do **not** try to convert BAISH into a full-screen terminal app

### 4. Adjust the read loop to use the footer lifecycle ✅

Update `lib/readline.sh` so that in **interactive** mode:
- after startup header and before the first `read`, draw the idle screen
- before processing an entered line, leave the idle screen so normal output can print cleanly
- after processing finishes, redraw the idle screen
- on interrupt recovery, redraw the idle screen
- on EOF/exit, clean up terminal state without leaving broken cursor placement

Keep non-interactive mode unchanged.

### 5. Add `SIGWINCH` handling ✅

Extend the interactive loop with a `SIGWINCH` trap.

Expected behavior:
- when `SIGWINCH` arrives in interactive mode, redraw the idle footer for the new width
- if the user is mid-input, it is acceptable that already-entered text may not reflow perfectly
- prioritize correct footer width and getting the cursor back to a usable input state

Implementation note:
- keep resize handling best-effort and simple
- avoid adding extra runtime dependencies if ANSI control sequences and shell state are enough

### 6. Keep active state refresh simple ✅

Footer content should reflect current process state.

Implemented by refreshing provider/model from existing config/state accessors during footer formatting rather than introducing a separate footer cache.

State sources remain:
- `BAISH_LAUNCH_CWD`
- `BAISH_ACTIVE_PROVIDER`
- `BAISH_ACTIVE_MODEL`
- provider metadata lookup for label

Covered with:
- `test/footer.bats` verifying footer formatting refreshes stale active variables from current process-selected state
- `test/readline_slash.bats` verifying an interactive redraw after input processing shows the updated provider/model

### 7. Make redraw failures non-fatal ✅

The footer is UI.

If footer rendering cannot resolve data:
- use fallbacks
- do not terminate BAISH
- do not block input

If a provider metadata lookup fails during redraw, the session should continue and the footer should show `unknown provider`.

### 8. Add launcher-level regression coverage ✅

Close the last gap between helper/readline tests and the real launcher entrypoint.

Covered cases:
- interactive startup shows the startup header and first idle footer block
- non-interactive launcher output stays footer-free

Implemented in `test/mock_provider.bats` using the mock provider plus a PTY-backed `script` invocation for the interactive case.

### 9. Document the shipped Status Footer ✅

Now that the feature is implemented and covered, document the interactive footer in `README.md` so users can discover it without reading the source or test suite.

Documented details:
- footer appears on the interactive idle screen under the prompt
- footer fields are Launch Directory, Provider Label, and Model ID
- footer is interactive-only
- footer redraws on return to idle and reflows on resize
- explicit fallback text remains visible when values cannot be resolved

## Suggested file changes

- `lib/main.sh`
  - source `lib/footer.sh`
- `lib/footer.sh` (new)
  - formatting, fallbacks, truncation, footer text generation
- `lib/readline.sh`
  - integrate draw/leave/redraw lifecycle
  - install `SIGWINCH` handling
  - keep interactive-only behavior
- `test/readline_slash.bats`
  - add footer unit/integration coverage
- optional: `test/footer.bats` (new)
  - if footer formatting logic becomes large enough to deserve isolated tests

## Test plan

### Unit-style tests

Add tests for footer formatting helpers:
- home-shortening:
  - `/tmp/x` stays `/tmp/x`
  - `/home/test/project` becomes `~/project`
- fallbacks:
  - empty model -> `no model`
  - missing provider label -> `unknown provider`
  - missing launch dir -> `?`
- truncation:
  - full line fits unchanged when width is sufficient
  - narrow widths keep a single line
  - Launch Directory truncates before Model ID
  - Model ID truncates before Provider Label
  - divider width equals terminal width

### Interactive PTY tests

Use `script`-backed tests for at least these cases:
- first idle screen after startup contains:
  - startup header
  - divider line
  - footer line with provider label + model text
- footer is absent in non-interactive mode
- footer shows `no model` when Active Model is empty
- footer redraws after a slash command that changes selected model/provider

### Resize coverage

Prefer an automated test if reliable in CI; otherwise at minimum:
- unit-test the redraw path used by `SIGWINCH`
- verify that a resize-triggered redraw recalculates width from current `COLUMNS`

## Acceptance criteria

Another agent can consider the work done when all of these are true:
- interactive BAISH shows the startup header, then the first idle screen with footer
- idle prompt line is directly above the divider/footer area
- footer shows `launch dir · provider label · model id`
- empty model shows `no model`
- bad/missing provider label shows `unknown provider`
- footer stays one line and truncates instead of wrapping
- divider spans the full width using `─`
- footer redraws after slash commands, agent completion, agent failure, and interrupt recovery
- footer reflows on `SIGWINCH`
- non-interactive mode behavior is unchanged
- tests cover formatting and at least basic PTY rendering behavior

## Out of scope

- turning BAISH into a full-screen terminal UI
- changing tool-output rendering style
- introducing a mutable session `cwd` concept
- adding model display-name resolution separate from stored model id

## Handoff note for the implementing agent

Favor the simplest redraw strategy that works with Bash readline.

Do not overengineer a screen manager. A small footer module plus a careful redraw lifecycle in `lib/readline.sh` is the intended direction.