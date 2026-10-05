# shellcheck shell=bash
# Helpers shared by taildrop-send and ssh-send. The flake puts this file in
# front of each script, and the script sets $title and $icon.

# kdialog --menu takes <tag> <label> pairs; names maps a tag back to the
# plain device name for notifications.
menu=()
declare -A names=()
notify_id=

fail() {
  kdialog --title "$title" --error "$1"
  exit 1
}

# describe_selection <paths...>: "name" for one item, "N items" otherwise.
describe_selection() {
  if [ "$#" -eq 1 ]; then
    printf '"%s"' "$(basename -- "$1")"
  else
    printf '%s items' "$#"
  fi
}

# Reads <tag>, <name>, <label> line triples from stdin into menu and names.
read_peers() {
  local tag name label
  while IFS= read -r tag && IFS= read -r name && IFS= read -r label; do
    menu+=("$tag" "$label")
    names[$tag]=$name
  done
}

# pick_target <empty message> <prompt>: sets target and target_name, and
# exits quietly if the menu is cancelled.
pick_target() {
  if [ "${#menu[@]}" -eq 0 ]; then
    fail "$1"
  fi
  target=$(kdialog --title "$title" --menu "$2" "${menu[@]}") || exit 0
  if [ -z "$target" ]; then
    exit 0
  fi
  target_name=${names[$target]:-$target}
}

# Last few non-empty lines of command output, for error messages.
error_tail() {
  printf '%s\n' "$1" | tr '\r' '\n' | { grep -v '^\s*$' || true; } | tail -n 3
}

# notify <urgency> <icon> <summary> <body>: replaces the progress
# notification, if one was shown.
notify() {
  local args=(-a "$title" -u "$1" -i "$2")
  if [ -n "$notify_id" ]; then
    args+=(-r "$notify_id")
  fi
  notify-send "${args[@]}" "$3" "$4"
}

notify_progress() {
  notify_id=$(notify-send -a "$title" -i "$icon" -p "$title" "$1") || notify_id=
}

notify_sent() {
  notify normal "$icon" "$title" "$1"
}

# send_failed <output> [hint]
send_failed() {
  local msg
  msg=$(error_tail "$1")
  if [ -n "${2:-}" ]; then
    msg="$msg
$2"
  fi
  notify critical dialog-error "$title failed" "Could not send to $target_name: $msg"
  exit 1
}
