# shellcheck shell=bash
# Copy files to a Tailscale device over SSH (scp). Invoked from the Dolphin
# servicemenu with the selected paths as arguments (%F). Unlike Taildrop this
# works with tagged devices; it only needs key-based SSH login to the target.

title="Send via SSH"
icon=network-server
dir=${TAILNET_SEND_SSH_DIR:-Downloads}

if [ "$#" -eq 0 ]; then
  fail "No files were selected."
fi

# Keep stderr out of the JSON: the CLI warns there on client/daemon version
# mismatches even when the command succeeds.
if ! status=$(tailscale status --json 2>/dev/null) || [ -z "$status" ]; then
  fail "Could not read Tailscale status:

$(tailscale status 2>&1 | tail -n 3)"
fi

# The tag is the IPv4 address, and name and label are the host name. Only
# online Linux/macOS peers are likely to run sshd.
read_peers < <(
  printf '%s\n' "$status" | jq -r '
    [.Peer // {} | .[]
      | select(.Online == true and (.OS == "linux" or .OS == "macOS"))
      | {ip: ([(.TailscaleIPs // [])[] | select(contains(":") | not)][0]), name: .HostName}
      | select(.ip != null)]
    | sort_by(.name | ascii_downcase)
    | .[] | .ip, .name, .name'
)

what=$(describe_selection "$@")
pick_target "No SSH-capable Tailscale devices are online." "Send $what to:"

# shellcheck disable=SC2088 # literal ~, for display only
case $dir in
  /*) shown_dir=$dir ;;
  *) shown_dir="~/$dir" ;;
esac

# mkdir and scp share one connection, so the target is only connected to
# and authenticated with once. The keepalive stops a transfer to a peer
# that went away from hanging forever.
ctl_dir=$(mktemp -d -t ssh-send.XXXXXX)
trap 'ssh -o ControlPath="$ctl_dir/master" -O exit "$target" 2>/dev/null || true; rm -rf -- "$ctl_dir"' EXIT

ssh_opts=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=accept-new
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
  -o ControlMaster=auto
  -o ControlPath="$ctl_dir/master"
  -o ControlPersist=60
)

no_key_hint() {
  if printf '%s\n' "$1" | grep -q 'Permission denied'; then
    echo "Key-based SSH login to $target_name is required."
  fi
}

notify_progress "Sending $what to $target_name…"

# The remote command goes through the remote login shell, which may not be
# bash, so quote the directory the POSIX way.
# shellcheck disable=SC2029
if ! out=$(ssh "${ssh_opts[@]}" "$target" "mkdir -p -- '${dir//\'/\'\\\'\'}'" 2>&1); then
  send_failed "$out" "$(no_key_hint "$out")"
fi

# scp -r sends directories as-is; existing files with the same name are
# overwritten.
if ! out=$(scp "${ssh_opts[@]}" -r -p -- "$@" "$target:$dir/" 2>&1); then
  send_failed "$out" "$(no_key_hint "$out")"
fi

notify_sent "Sent $what to $target_name:$shown_dir"
