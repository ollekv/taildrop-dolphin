# dolphin-tailnet-send

Adds two entries to Dolphin's right-click **Share** menu on KDE Plasma 6, for
sending files to your other Tailscale devices:

- **Send with Taildrop…** uses
  [Taildrop](https://tailscale.com/kb/1106/taildrop). It works with phones,
  tablets and other desktops, but only between devices owned by the same user,
  and never with tagged devices.
- **Send via SSH…** copies files with `scp` over the tailnet. It works with
  any Linux or macOS device you can log in to with an SSH key, including
  tagged servers.

## Requirements

On the sending machine:

- Linux (`x86_64` or `aarch64`) with KDE Plasma 6 and Dolphin. Notifications
  need a notification daemon, which Plasma provides.
- Nix with flakes enabled. The packages bring their own `kdialog`, `zip`,
  `jq`, `ssh` and other tools.
- Tailscale running and logged in.

For **Send with Taildrop…**:

- Taildrop ("Send Files") enabled for your tailnet in the Tailscale admin
  console.
- The sending and receiving devices are owned by the same user, and neither
  is tagged.
- Your user is the Tailscale operator (see the `operator` option below), so
  `tailscale file cp` works without `sudo`.

For **Send via SSH…**, each target needs:

- an SSH server that accepts your key without a prompt, and
- SFTP enabled. Since OpenSSH 9.0, `scp` copies over the SFTP protocol. NixOS
  enables it by default (`services.openssh.allowSFTP`).

## Send with Taildrop…

1. Select one or more files or folders in Dolphin, right-click, then pick
   **Share → Send with Taildrop…**.
2. A kdialog menu lists the devices from `tailscale file cp --targets`. Offline
   peers are left out. Peers whose status is unknown are still listed, marked
   `(unknown-status)`. If no device is available, an error dialog is shown
   instead.
3. The files are sent with `tailscale file cp <files...> <ip>:`.
4. A "Sending…" notification appears, and it is replaced by the result when
   the send finishes.

`tailscale file cp` cannot send directories, so each selected folder is
zipped and streamed as `<name>.zip` while it is being sent. No temporary copy
is written to disk. Symlinks inside the folder are followed.

## Send via SSH…

1. Select files or folders, right-click, then pick **Share → Send via SSH…**.
2. A kdialog menu lists the online Linux and macOS peers from
   `tailscale status --json`. Tags make no difference here.
3. The files are copied with `scp -r -p` to `~/Downloads` on the target, using
   its Tailscale IPv4 address. The folder is created if it's missing. Folders
   are copied as folders, so nothing is zipped. Creating the folder and
   copying share one SSH connection, so you log in only once.
4. A "Sending…" notification appears, and it is replaced by the result when
   the copy finishes. If the target stops responding for about 45 seconds,
   the copy is aborted and reported as failed.

Requirements and behaviour:

- The target must run an SSH server with SFTP enabled, and you must be able
  to log in **with a key and without a prompt**. There is no terminal for a
  password prompt, so SSH runs with `BatchMode=yes`. Test this with
  `ssh -o BatchMode=yes <tailscale-ip> true`.
- The username, keys and other settings come from your `~/.ssh/config`. A
  `Host <tailscale-ip>` block, for example, can set a different `User`.
- Unknown host keys are accepted on first contact
  (`StrictHostKeyChecking=accept-new`), because the tailnet already
  authenticates the peer. Changed host keys are still refused.
- **Files with the same name in the destination are overwritten.**
- To use a different destination, set `TAILNET_SEND_SSH_DIR` in your session
  environment. Relative paths start from the remote home directory.

## Flake outputs

| Output | Contents |
| --- | --- |
| `packages.<system>.taildrop-send` | The `taildrop-send` script |
| `packages.<system>.ssh-send` | The `ssh-send` script |
| `packages.<system>.tailnet-send-servicemenu` | `share/kio/servicemenus/dolphin-tailnet-send.desktop` (both entries) |
| `packages.<system>.default` | All of the above |
| `overlays.default` | `taildrop-send`, `ssh-send`, `tailnet-send-servicemenu`, `dolphin-tailnet-send` |
| `nixosModules.default` | `programs.dolphin-tailnet-send` |
| `homeManagerModules.default` | `programs.dolphin-tailnet-send` |

Supported systems: `x86_64-linux` and `aarch64-linux`. If you use the
overlay, `pkgs.dolphin-tailnet-send` is the combined package.

Without the NixOS or Home Manager module, install the package with
`nix profile install github:ollekv/dolphin-tailnet-send` and make sure
`~/.nix-profile/share` is in `XDG_DATA_DIRS`, so Dolphin finds the
servicemenu.

## NixOS

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    dolphin-tailnet-send = {
      url = "github:ollekv/dolphin-tailnet-send";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, dolphin-tailnet-send, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        dolphin-tailnet-send.nixosModules.default
        {
          services.tailscale.enable = true;
          programs.dolphin-tailnet-send = {
            enable = true;
            # Lets this user run `tailscale file cp` without sudo.
            operator = "alice";
          };
        }
      ];
    };
  };
}
```

Options:

- `programs.dolphin-tailnet-send.enable`: installs both scripts and the
  servicemenu into `environment.systemPackages`.
- `programs.dolphin-tailnet-send.package`: the package to install. Defaults
  to this flake's package, built with your system's `pkgs`.
- `programs.dolphin-tailnet-send.operator` (string or `null`): when set,
  appends `--operator=<user>` to `services.tailscale.extraSetFlags`. This
  option requires `services.tailscale.enable = true`, and evaluation fails
  with an assertion if Tailscale is not enabled.

NixOS applies the operator setting at boot and on every rebuild. Running
`tailscale up` later clears it, because `tailscale up` resets every setting
you don't pass. Use `tailscale set` for later changes, or run
`sudo systemctl restart tailscaled-set.service` after a `tailscale up`.

## Home Manager

Add the input to your `flake.nix`:

```nix
inputs.dolphin-tailnet-send.url = "github:ollekv/dolphin-tailnet-send";
```

Then, in your Home Manager configuration (with `inputs` passed in through
`extraSpecialArgs`):

```nix
{ inputs, ... }:
{
  imports = [ inputs.dolphin-tailnet-send.homeManagerModules.default ];
  programs.dolphin-tailnet-send.enable = true;
}
```

This adds the package to `home.packages`. Dolphin finds the servicemenu through
`XDG_DATA_DIRS`, which includes your Home Manager profile's `share` directory.

**Home Manager cannot set the operator.** The Tailscale operator is set in the
system daemon, so you still need one of these:

- the NixOS module's `programs.dolphin-tailnet-send.operator`, or
- `services.tailscale.extraSetFlags = [ "--operator=alice" ];`, or
- running `sudo tailscale set --operator=$USER` once.

## Receiving Taildrop files

Files sent with **Send via SSH…** are simply in `~/Downloads` (or
`TAILNET_SEND_SSH_DIR`) on the target. Taildrop works differently:

- **Linux:** received files wait in tailscaled's inbox until you collect them,
  for example with `tailscale file get ~/Downloads`. Use
  `tailscale file get --wait --loop ~/Downloads` to keep collecting them.
  Without `sudo`, this also needs the operator setting.
- **macOS, Windows, iOS and Android:** the Tailscale app receives the files and
  shows them to you.
- Taildrop only sends between devices owned by the same user. If either the
  sending or the receiving device is tagged, Taildrop doesn't work, so use
  **Send via SSH…** for tagged servers. Devices shared from other tailnets
  also don't appear as targets.

## Troubleshooting

- **The menu entries don't appear.** Restart Dolphin. If they're still missing,
  run `kbuildsycoca6` and log out and back in, so a new `XDG_DATA_DIRS` is
  picked up. Check that `dolphin-tailnet-send.desktop` exists in a
  `share/kio/servicemenus` directory listed in `XDG_DATA_DIRS`. On NixOS that
  directory is `/run/current-system/sw/share/kio/servicemenus`.
- **"Send with Taildrop failed: … Access denied: file access denied".** Your
  user is not the Tailscale operator. The device menu still works without
  it; only sending fails. Set `programs.dolphin-tailnet-send.operator`, or run
  `sudo tailscale set --operator=$USER`. If it was set before, a later
  `tailscale up` has probably cleared it; see the `operator` option above.
- **"No Taildrop targets are online".** Run `tailscale file cp --targets`
  yourself. Devices that are offline, tagged, owned by another user, or don't
  support Taildrop are not listed. Check `tailscale status`: a peer listed
  as `tagged-devices`, or this machine having tags, rules Taildrop out. A
  machine logged in with a tagged auth key is tagged too.
- **"Send via SSH failed: … Permission denied".** The target doesn't accept
  your SSH key. Run `ssh -o BatchMode=yes <tailscale-ip> true` to check, then
  add your public key to the target's `authorized_keys`. On NixOS, that's
  `users.users.<name>.openssh.authorizedKeys.keys`.
- **"Send via SSH failed: … subsystem request failed" (or similar).** The
  target has SFTP turned off. Enable it in its `sshd` configuration.
- **"Send via SSH failed: … Host key verification failed".** The target's host
  key changed, for example after a reinstall. Remove the old key with
  `ssh-keygen -R <tailscale-ip>`.
- **Testing from a terminal:** run `taildrop-send <file>...` or
  `ssh-send <file>...` directly to see the same dialogs and notifications.

## Development

```sh
nix flake check   # builds the packages and runs the NixOS VM test
nix fmt           # nixfmt (via nixfmt-tree)
```

## License

MIT, see [LICENSE](LICENSE).
