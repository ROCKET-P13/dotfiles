#!/bin/sh
# Render the tmux session list for status-left, numbered to match M-1..M-9.
# Active session = yellow pill (U+E0B6 / U+E0B4 dividers), others = plain yellow text.
# Arg 1: current session id, expanded by tmux via #{session_id} in the #() call.
cur="$1"
tmux list-sessions -F '#{session_id}	#{session_name}' 2>/dev/null | awk -F'\t' -v cur="$cur" '
{
  if ($1 == cur)
    printf "#[fg=#b8bb26,bg=#1d2021]\356\202\266#[fg=#1d2021,bg=#b8bb26,bold] %s #[fg=#b8bb26,bg=#1d2021,nobold]\356\202\264#[default]", $2
  else
    printf "#[fg=#b8bb26,bg=#1d2021] %s #[default]", $2
}'
