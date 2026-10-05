# taildrop-dolphin

Adds a **Send with Taildrop…** entry to Dolphin's right-click menu on KDE
Plasma 6, so you can send files to your other Tailscale devices with
[Taildrop](https://tailscale.com/kb/1106/taildrop).

## How it works

1. Select one or more files or folders in Dolphin, right-click, then pick
   **Share → Send with Taildrop…**.
2. A kdialog menu lists the devices from `tailscale file cp --targets`. Offline
   peers are left out. Peers whose status is unknown are still listed, marked
   `(unknown-status)`.
3. The files are sent with `tailscale file cp <files...> <ip>:`.
4. A desktop notification reports whether the send worked.

`tailscale file cp` cannot send directories. Any selected folder is zipped to
a temporary `<name>.zip` first, and the temp files are deleted after the send.
If no device is online, an error dialog is shown.

The flake provides:

| Output | Contents |
| --- | --- |
| `packages.<system>.taildrop-send` | The `taildrop-send` script |
| `packages.<system>.taildrop-servicemenu` | `share/kio/servicemenus/taildrop.desktop` |
| `packages.<system>.default` | Both of the above |
| `overlays.default` | `taildrop-send`, `taildrop-servicemenu`, `taildrop-dolphin` |
| `nixosModules.default` | `programs.taildrop-dolphin` |
| `homeManagerModules.default` | `programs.taildrop-dolphin` |

Supported systems: `x86_64-linux` and `aarch64-linux`.

## NixOS

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    taildrop-dolphin = {
      url = "github:ollekv/taildrop-dolphin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, taildrop-dolphin, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        taildrop-dolphin.nixosModules.default
        {
          services.tailscale.enable = true;
          programs.taildrop-dolphin = {
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

- `programs.taildrop-dolphin.enable`: installs the script and the servicemenu
  into `environment.systemPackages`.
- `programs.taildrop-dolphin.package`: the package to install. Defaults to this
  flake's package, built with your system's `pkgs`.
- `programs.taildrop-dolphin.operator` (string or `null`): when set, appends
  `--operator=<user>` to `services.tailscale.extraSetFlags`. This option
  requires `services.tailscale.enable = true`, and evaluation fails with an
  assertion if Tailscale is not enabled.

## Home Manager

```nix
{
  inputs.taildrop-dolphin.url = "github:ollekv/taildrop-dolphin";

  # In your Home Manager configuration:
  imports = [ inputs.taildrop-dolphin.homeManagerModules.default ];
  programs.taildrop-dolphin.enable = true;
}
```

This adds the package to `home.packages`. Dolphin finds the servicemenu through
`XDG_DATA_DIRS`, which includes your Home Manager profile's `share` directory.

**Home Manager cannot set the operator.** The Tailscale operator is set in the
system daemon, so you still need one of these:

- the NixOS module's `programs.taildrop-dolphin.operator`, or
- `services.tailscale.extraSetFlags = [ "--operator=alice" ];`, or
- running `sudo tailscale set --operator=$USER` once.

If you use the overlay, `pkgs.taildrop-dolphin` is the combined package.

## Receiving files

- **Linux:** received files wait in tailscaled's inbox until you collect them,
  for example with `tailscale file get ~/Downloads`. Use
  `tailscale file get --wait --loop ~/Downloads` to keep collecting them.
  Without `sudo`, this also needs the operator setting.
- **macOS, Windows, iOS and Android:** the Tailscale app receives the files and
  shows them to you.
- Taildrop only sends between devices owned by the same user. Tagged devices
  and devices shared from other tailnets will not appear as targets.

## Troubleshooting

- **The menu entry doesn't appear.** Restart Dolphin. If it's still missing,
  run `kbuildsycoca6` and log out and back in, so a new `XDG_DATA_DIRS` is
  picked up. Check that `taildrop.desktop` exists in a
  `share/kio/servicemenus` directory listed in `XDG_DATA_DIRS`. On NixOS that
  directory is `/run/current-system/sw/share/kio/servicemenus`.
- **"Could not list Taildrop targets: … access denied".** Your user is not the
  Tailscale operator. Set `programs.taildrop-dolphin.operator`, or run
  `sudo tailscale set --operator=$USER`. Then check the result with
  `tailscale file cp --targets`.
- **"No Taildrop targets are online".** Run `tailscale file cp --targets`
  yourself. Devices that are offline, or that don't support Taildrop, are not
  listed.
- **Testing from a terminal:** run `taildrop-send <file>...` directly to see
  the same dialogs and notifications.

## Development

```sh
nix flake check   # builds both packages and runs the NixOS VM test
nix fmt           # nixfmt (via nixfmt-tree)
```
