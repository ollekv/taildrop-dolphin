# shellcheck shell=bash
# Send files to a Tailscale device via Taildrop. Invoked from the Dolphin
# servicemenu with the selected paths as arguments (%F).

title="Send with Taildrop"

fail() {
  kdialog --title "$title" --error "$1"
  exit 1
}

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

# kdialog --menu takes <tag> <label> pairs; tag is the IP, label the name.
mapfile -t menu < <(
  printf '%s\n' "$targets" | awk -F '\t' '
    NF >= 2 && $3 !~ /^offline/ {
      print $1
      print ($3 == "" ? $2 : $2 " (" $3 ")")
    }'
)

if [ "${#menu[@]}" -eq 0 ]; then
  fail "No Taildrop targets are online."
fi

if [ "$#" -eq 1 ]; then
  prompt="Send \"$(basename -- "$1")\" to:"
else
  prompt="Send $# items to:"
fi

target=$(kdialog --title "$title" --menu "$prompt" "${menu[@]}") || exit 0

target_name=$target
for ((i = 0; i < ${#menu[@]}; i += 2)); do
  if [ "${menu[i]}" = "$target" ]; then
    target_name=${menu[i + 1]% (*}
    break
  fi
done

tmpdir=$(mktemp -d -t taildrop-send.XXXXXX)
trap 'rm -rf -- "$tmpdir"' EXIT

# tailscale file cp cannot send directories, so zip them first. Each archive
# gets its own subdirectory so identically named folders don't collide.
files=()
n=0
for path in "$@"; do
  if [ -d "$path" ]; then
    path=$(realpath -- "$path")
    name=$(basename -- "$path")
    [ "$path" = / ] && name=root
    n=$((n + 1))
    mkdir -p -- "$tmpdir/$n"
    archive="$tmpdir/$n/$name.zip"
    if ! out=$(cd -- "$(dirname -- "$path")" && zip -qr "$archive" -- "$name" 2>&1); then
      notify-send -a Taildrop -i dialog-error -u critical \
        "Taildrop failed" "Could not zip \"$name\": $out"
      exit 1
    fi
    files+=("$archive")
  else
    files+=("$path")
  fi
done

if out=$(tailscale file cp "${files[@]}" "$target:" 2>&1); then
  if [ "$#" -eq 1 ]; then
    what="\"$(basename -- "$1")\""
  else
    what="$# items"
  fi
  notify-send -a Taildrop -i document-send \
    "Taildrop" "Sent $what to $target_name"
else
  notify-send -a Taildrop -i dialog-error -u critical \
    "Taildrop failed" "Could not send to $target_name: $(printf '%s\n' "$out" | tr '\r' '\n' | grep -v '^\s*$' | tail -n 3)"
  exit 1
fi
