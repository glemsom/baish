# BAISH

BAISH is a Bash-first terminal AI coding assistant. This context captures the product language used to describe the user-visible conversation, commands, and runtime state.

## Language

**Current request usage**:
The estimated size of the request BAISH would send to the model if the user submitted the next message now. It reflects the next outbound request, not the previous provider call.
_Avoid_: Last usage, historical usage, current window size

## Example dialogue

**Developer**: What does `/context` show?

**Domain expert**: It shows current request usage — the size of the next request BAISH would send right now.

**Developer**: So it is not the last call's usage?

**Domain expert**: Correct. It is forward-looking, not historical.
