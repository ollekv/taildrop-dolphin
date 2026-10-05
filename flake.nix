{
  description = "Send files from Dolphin (KDE Plasma 6) to Tailscale devices with Taildrop";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      mkPackages =
        pkgs:
        let
          taildrop-send = pkgs.writeShellApplication {
            name = "taildrop-send";
            runtimeInputs = with pkgs; [
              tailscale
              kdePackages.kdialog
              libnotify
              gawk
              zip
              coreutils
              gnugrep
            ];
            text = builtins.readFile ./src/taildrop-send.sh;
            meta = {
              description = "Pick a Tailscale device with kdialog and send files to it via Taildrop";
              mainProgram = "taildrop-send";
              platforms = lib.platforms.linux;
            };
          };

          ssh-send = pkgs.writeShellApplication {
            name = "ssh-send";
            runtimeInputs = with pkgs; [
              tailscale
              kdePackages.kdialog
              libnotify
              jq
              openssh
              coreutils
              gnugrep
            ];
            text = builtins.readFile ./src/ssh-send.sh;
            meta = {
              description = "Pick a Tailscale device with kdialog and copy files to it with scp";
              mainProgram = "ssh-send";
              platforms = lib.platforms.linux;
            };
          };

          # KIO only runs servicemenus from user-writable locations when the
          # file is executable, so mark it executable to be safe everywhere.
          taildrop-servicemenu = pkgs.writeTextFile {
            name = "taildrop-servicemenu";
            destination = "/share/kio/servicemenus/taildrop.desktop";
            executable = true;
            text = ''
              [Desktop Entry]
              Type=Service
              MimeType=all/allfiles;all/all;
              Actions=taildropSend;sshSend;
              X-KDE-Submenu=Share
              Icon=document-send

              [Desktop Action taildropSend]
              Name=Send with Taildrop…
              Icon=document-send
              Exec=${lib.getExe taildrop-send} %F

              [Desktop Action sshSend]
              Name=Send via SSH…
              Icon=network-server
              Exec=${lib.getExe ssh-send} %F
            '';
          };
        in
        {
          inherit taildrop-send ssh-send taildrop-servicemenu;
          default = pkgs.symlinkJoin {
            name = "taildrop-dolphin";
            paths = [
              taildrop-send
              ssh-send
              taildrop-servicemenu
            ];
            meta.mainProgram = "taildrop-send";
          };
        };
    in
    {
      packages = forAllSystems mkPackages;

      overlays.default = final: _prev: {
        inherit (mkPackages final) taildrop-send ssh-send taildrop-servicemenu;
        taildrop-dolphin = (mkPackages final).default;
      };

      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.programs.taildrop-dolphin;
        in
        {
          options.programs.taildrop-dolphin = {
            enable = lib.mkEnableOption "the \"Send with Taildrop…\" entry in Dolphin's context menu";

            package = lib.mkOption {
              type = lib.types.package;
              default = (mkPackages pkgs).default;
              defaultText = lib.literalExpression "taildrop-dolphin.packages.\${system}.default";
              description = "The taildrop-dolphin package to install.";
            };

            operator = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "alice";
              description = ''
                User to set as the Tailscale operator (`tailscale set --operator`),
                so they can use Taildrop without sudo. Requires
                `services.tailscale.enable`.
              '';
            };
          };

          config = lib.mkIf cfg.enable (
            lib.mkMerge [
              {
                environment.systemPackages = [ cfg.package ];
                environment.pathsToLink = [ "/share/kio/servicemenus" ];
              }
              (lib.mkIf (cfg.operator != null) {
                assertions = [
                  {
                    assertion = config.services.tailscale.enable;
                    message = "programs.taildrop-dolphin.operator requires services.tailscale.enable = true.";
                  }
                ];
                services.tailscale.extraSetFlags = [ "--operator=${cfg.operator}" ];
              })
            ]
          );
        };

      # The servicemenu is picked up through XDG_DATA_DIRS from the Home
      # Manager profile. Making the user a Tailscale operator must still be
      # done at the NixOS level (programs.taildrop-dolphin.operator).
      homeManagerModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.programs.taildrop-dolphin;
        in
        {
          options.programs.taildrop-dolphin = {
            enable = lib.mkEnableOption "the \"Send with Taildrop…\" entry in Dolphin's context menu";

            package = lib.mkOption {
              type = lib.types.package;
              default = (mkPackages pkgs).default;
              defaultText = lib.literalExpression "taildrop-dolphin.packages.\${system}.default";
              description = "The taildrop-dolphin package to install.";
            };
          };

          config = lib.mkIf cfg.enable {
            home.packages = [ cfg.package ];
          };
        };

      # nixfmt-rfc-style is now a deprecated alias of nixfmt; nixfmt-tree wraps
      # it in treefmt so that a bare `nix fmt` formats the whole tree.
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);

      checks = forAllSystems (
        pkgs:
        let
          packages = self.packages.${pkgs.stdenv.hostPlatform.system};
        in
        {
          inherit (packages) taildrop-send ssh-send taildrop-servicemenu;

          nixos-module = pkgs.testers.runNixOSTest {
            name = "taildrop-dolphin";
            nodes.machine = {
              imports = [ self.nixosModules.default ];
              services.tailscale.enable = true;
              users.users.alice.isNormalUser = true;
              programs.taildrop-dolphin = {
                enable = true;
                operator = "alice";
              };
            };
            testScript = ''
              machine.wait_for_unit("multi-user.target")
              machine.succeed("test -f /run/current-system/sw/share/kio/servicemenus/taildrop.desktop")
              machine.succeed("grep -q 'Exec=/nix/store/.*/bin/taildrop-send %F' /run/current-system/sw/share/kio/servicemenus/taildrop.desktop")
              machine.succeed("grep -q 'Exec=/nix/store/.*/bin/ssh-send %F' /run/current-system/sw/share/kio/servicemenus/taildrop.desktop")
              machine.succeed("su - alice -c 'command -v taildrop-send'")
              machine.succeed("su - alice -c 'command -v ssh-send'")
              machine.wait_until_succeeds("tailscale debug prefs | grep -q '\"OperatorUser\": \"alice\"'")
            '';
          };
        }
      );
    };
}
