#!/bin/sh
# Swap session order numbers on rename.
#
# Sessions are named "(<n>) <label>". When a session is renamed to a number
# already used by another session, that other session is moved to the number
# the renamed session just vacated (a straight swap of the leading numbers).
#
# Invoked from tmux via the prefix-$ binding:
#   command-prompt ... "run-shell '/Users/lvenceslau/.tmux-rename-session.sh \"#S\" \"%%\"'"
# Arg 1: current (old) session name
# Arg 2: new session name typed in the prompt

old="$1"
new="$2"

# Extract the leading "(<n>)" number from a session name, or print empty.
extract_num() {
  printf '%s' "$1" | sed -n 's/^(\([0-9][0-9]*\)) .*/\1/p'
}

# Replace the leading "(<n>)" with "(<new>)", keeping the rest of the name.
replace_num() {
  printf '%s' "$1" | sed "s/^([0-9][0-9]*) /($2) /"
}

old_num="$(extract_num "$old")"
new_num="$(extract_num "$new")"

# No number in the new name, or the number is unchanged, or nothing to vacate:
# plain rename, nothing to swap.
if [ -z "$new_num" ] || [ -z "$old_num" ] || [ "$new_num" = "$old_num" ]; then
  tmux rename-session -t "$old" "$new"
  exit 0
fi

# Find another session currently occupying new_num (exclude the one being renamed).
other="$(tmux list-sessions -F '#{session_name}' 2>/dev/null \
  | grep "^($new_num) " | grep -vFx "$old" | head -n1)"

# Move the displaced session into the vacated number first, then rename.
if [ -n "$other" ]; then
  tmux rename-session -t "$other" "$(replace_num "$other" "$old_num")"
fi
tmux rename-session -t "$old" "$new"
