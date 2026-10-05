{
  description = "Send files from Dolphin (KDE Plasma 6) to Tailscale devices via Taildrop or SSH";

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
          # Each script gets the shared helpers from common.sh in front of it.
          mkScript =
            {
              name,
              description,
              runtimeInputs,
            }:
            pkgs.writeShellApplication {
              inherit name runtimeInputs;
              text = builtins.readFile ./src/common.sh + builtins.readFile ./src/${name}.sh;
              meta = {
                inherit description;
                license = lib.licenses.mit;
                mainProgram = name;
                platforms = lib.platforms.linux;
              };
            };

          taildrop-send = mkScript {
            name = "taildrop-send";
            description = "Pick a Tailscale device with kdialog and send files to it via Taildrop";
            runtimeInputs = with pkgs; [
              tailscale
              kdePackages.kdialog
              libnotify
              gawk
              zip
              coreutils
              gnugrep
            ];
          };

          ssh-send = mkScript {
            name = "ssh-send";
            description = "Pick a Tailscale device with kdialog and copy files to it with scp";
            runtimeInputs = with pkgs; [
              tailscale
              kdePackages.kdialog
              libnotify
              jq
              openssh
              coreutils
              gnugrep
            ];
          };

          # KIO only runs servicemenus from user-writable locations when the
          # file is executable, so mark it executable to be safe everywhere.
          tailnet-send-servicemenu = pkgs.writeTextFile {
            name = "tailnet-send-servicemenu";
            destination = "/share/kio/servicemenus/dolphin-tailnet-send.desktop";
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
          inherit taildrop-send ssh-send tailnet-send-servicemenu;
          default = pkgs.symlinkJoin {
            name = "dolphin-tailnet-send";
            paths = [
              taildrop-send
              ssh-send
              tailnet-send-servicemenu
            ];
            meta.mainProgram = "taildrop-send";
          };
        };

      # Options shared by the NixOS and Home Manager modules.
      commonOptions = pkgs: {
        enable = lib.mkEnableOption "the Taildrop and SSH entries in Dolphin's Share menu";

        package = lib.mkOption {
          type = lib.types.package;
          default = (mkPackages pkgs).default;
          defaultText = lib.literalExpression "dolphin-tailnet-send.packages.\${system}.default";
          description = "The dolphin-tailnet-send package to install.";
        };
      };
    in
    {
      packages = forAllSystems mkPackages;

      overlays.default =
        final: _prev:
        let
          packages = mkPackages final;
        in
        {
          inherit (packages) taildrop-send ssh-send tailnet-send-servicemenu;
          dolphin-tailnet-send = packages.default;
        };

      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.programs.dolphin-tailnet-send;
        in
        {
          options.programs.dolphin-tailnet-send = commonOptions pkgs // {
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
                    message = "programs.dolphin-tailnet-send.operator requires services.tailscale.enable = true.";
                  }
                ];
                services.tailscale.extraSetFlags = [ "--operator=${cfg.operator}" ];
              })
            ]
          );
        };

      # The servicemenu is picked up through XDG_DATA_DIRS from the Home
      # Manager profile. Making the user a Tailscale operator must still be
      # done at the NixOS level (programs.dolphin-tailnet-send.operator).
      homeManagerModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.programs.dolphin-tailnet-send;
        in
        {
          options.programs.dolphin-tailnet-send = commonOptions pkgs;

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
          inherit (packages) taildrop-send ssh-send tailnet-send-servicemenu;

          nixos-module = pkgs.testers.runNixOSTest {
            name = "dolphin-tailnet-send";
            nodes.machine = {
              imports = [ self.nixosModules.default ];
              services.tailscale.enable = true;
              users.users.alice.isNormalUser = true;
              programs.dolphin-tailnet-send = {
                enable = true;
                operator = "alice";
              };
            };
            testScript = ''
              machine.wait_for_unit("multi-user.target")
              machine.succeed("test -f /run/current-system/sw/share/kio/servicemenus/dolphin-tailnet-send.desktop")
              machine.succeed("grep -q 'Exec=/nix/store/.*/bin/taildrop-send %F' /run/current-system/sw/share/kio/servicemenus/dolphin-tailnet-send.desktop")
              machine.succeed("grep -q 'Exec=/nix/store/.*/bin/ssh-send %F' /run/current-system/sw/share/kio/servicemenus/dolphin-tailnet-send.desktop")
              machine.succeed("su - alice -c 'command -v taildrop-send'")
              machine.succeed("su - alice -c 'command -v ssh-send'")
              machine.wait_until_succeeds("tailscale debug prefs | grep -q '\"OperatorUser\": \"alice\"'")
            '';
          };
        }
      );
    };
}
