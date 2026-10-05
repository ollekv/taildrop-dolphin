# shellcheck shell=bash
# Copy files to a Tailscale device over SSH (scp). Invoked from the Dolphin
# servicemenu with the selected paths as arguments (%F). Unlike Taildrop this
# works with tagged devices; it only needs key-based SSH login to the target.

title="Send via SSH"
dir=${TAILDROP_SSH_DIR:-Downloads}

ssh_opts=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=accept-new
)

fail() {
  kdialog --title "$title" --error "$1"
  exit 1
}

if [ "$#" -eq 0 ]; then
  fail "No files were selected."
fi

# Keep stderr out of the JSON: the CLI warns there on client/daemon version
# mismatches even when the command succeeds.
if ! status=$(tailscale status --json 2>/dev/null) || [ -z "$status" ]; then
  fail "Could not read Tailscale status:

$(tailscale status 2>&1 | tail -n 3)"
fi

# kdialog --menu takes <tag> <label> pairs; tag is the IPv4 address, label
# the host name. Only online Linux/macOS peers are likely to run sshd.
mapfile -t menu < <(
  printf '%s\n' "$status" | jq -r '
    [.Peer // {} | .[]
      | select(.Online == true and (.OS == "linux" or .OS == "macOS"))
      | {ip: ([.TailscaleIPs[] | select(contains(":") | not)][0]), name: .HostName}
      | select(.ip != null)]
    | sort_by(.name | ascii_downcase)
    | .[] | .ip, .name'
)

if [ "${#menu[@]}" -eq 0 ]; then
  fail "No SSH-capable Tailscale devices are online."
fi

if [ "$#" -eq 1 ]; then
  what="\"$(basename -- "$1")\""
else
  what="$# items"
fi

target=$(kdialog --title "$title" --menu "Send $what to:" "${menu[@]}") || exit 0

target_name=$target
for ((i = 0; i < ${#menu[@]}; i += 2)); do
  if [ "${menu[i]}" = "$target" ]; then
    target_name=${menu[i + 1]}
    break
  fi
done

# shellcheck disable=SC2088 # literal ~, for display only
case $dir in
  /*) shown_dir=$dir ;;
  *) shown_dir="~/$dir" ;;
esac

failed() {
  local msg
  msg=$(printf '%s\n' "$1" | tr '\r' '\n' | grep -v '^\s*$' | tail -n 3)
  if printf '%s\n' "$1" | grep -q 'Permission denied'; then
    msg="$msg
Key-based SSH login to $target_name is required."
  fi
  notify-send -a "$title" -i dialog-error -u critical \
    "Send via SSH failed" "Could not send to $target_name: $msg"
  exit 1
}

# The remote command goes through the remote shell, so quote the directory
# locally.
# shellcheck disable=SC2029
if ! out=$(ssh "${ssh_opts[@]}" "$target" "mkdir -p -- $(printf '%q' "$dir")" 2>&1); then
  failed "$out"
fi

# scp -r sends directories as-is; existing files with the same name are
# overwritten.
if ! out=$(scp "${ssh_opts[@]}" -r -p -- "$@" "$target:$dir/" 2>&1); then
  failed "$out"
fi

notify-send -a "$title" -i network-server \
  "Send via SSH" "Sent $what to $target_name:$shown_dir"
