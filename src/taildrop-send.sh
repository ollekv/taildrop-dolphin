# shellcheck shell=bash
# Send files to a Tailscale device via Taildrop. Invoked from the Dolphin
# servicemenu with the selected paths as arguments (%F).

title="Send with Taildrop"
icon=document-send

if [ "$#" -eq 0 ]; then
  fail "No files were selected."
fi

# `tailscale file cp --targets` prints one peer per line:
#   <ip>\t<name>[\t<detail>]
# where <detail> is only present for "offline; last seen ..." or
# "unknown-status" peers.
if ! targets=$(tailscale file cp --targets 2>&1); then
  fail "Could not list Taildrop targets:

$targets

If this is a permission error, set your user as the Tailscale operator
(programs.taildrop-dolphin.operator, or: sudo tailscale set --operator=\$USER)."
fi

# Unknown-status peers stay in the menu, with the status in the label.
read_peers < <(
  printf '%s\n' "$targets" | awk -F '\t' '
    NF >= 2 && $3 !~ /^offline/ {
      print $1
      print $2
      print ($3 == "" ? $2 : $2 " (" $3 ")")
    }'
)

what=$(describe_selection "$@")
pick_target "No Taildrop targets are online." "Send $what to:"
notify_progress "Sending $what to $target_name…"

# Progress output would only end up in the captured error messages.
cp_opts=(--update-interval=0)

# tailscale file cp cannot send directories, so each one is streamed as a
# zip archive, without a temporary copy. -1 favours speed over size. (Zip
# can't store symlinks as links (-y) when writing to a pipe, so they are
# followed.)
files=()
for path in "$@"; do
  if [ -d "$path" ]; then
    path=$(realpath -- "$path")
    parent=$(dirname -- "$path")
    entry=$(basename -- "$path")
    name=$entry
    if [ "$path" = / ]; then
      entry=.
      name=root
    fi
    if ! out=$(
      {
        cd -- "$parent" &&
          zip -qr -1 - -- "$entry" |
          tailscale file cp "${cp_opts[@]}" --name "$name.zip" - "$target:"
      } 2>&1
    ); then
      send_failed "$out"
    fi
  else
    files+=("$path")
  fi
done

if [ "${#files[@]}" -gt 0 ] &&
  ! out=$(tailscale file cp "${cp_opts[@]}" "${files[@]}" "$target:" 2>&1); then
  send_failed "$out"
fi

notify_sent "Sent $what to $target_name"
