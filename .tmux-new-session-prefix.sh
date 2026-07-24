#!/bin/sh
# Prefix a freshly created session with its order number "(<n>) ".
#
# Invoked from the session-created hook. Arg 1: new session name, Arg 2: new
# session id (rename target). #{q:...} in the hook shell-quotes both args.
#
# Next position = max existing leading number + 1 (append at end, never collides
# with an existing number, even when earlier sessions were killed leaving gaps).

name="$1"
sid="$2"

# Already prefixed with "(<n>) " -> leave it (resurrect restore, manual, etc.).
num="$(printf '%s' "$name" | sed -n 's/^(\([0-9][0-9]*\)) .*/\1/p')"
[ -n "$num" ] && exit 0

max=0
for n in $(tmux list-sessions -F '#{session_name}' 2>/dev/null \
  | sed -n 's/^(\([0-9][0-9]*\)) .*/\1/p'); do
  [ "$n" -gt "$max" ] 2>/dev/null && max="$n"
done
next=$((max + 1))

tmux rename-session -t "$sid" "($next) $name"
