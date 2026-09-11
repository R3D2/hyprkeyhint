{
  description = "Show the Hyprland binds reachable from the modifiers you are holding";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];

      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        keyhint = pkgs.callPackage ./package.nix { };
        default = keyhint;
      });

      overlays.default = final: _prev: {
        keyhint = final.callPackage ./package.nix { };
      };

      homeModules.default = import ./modules/home-manager.nix;

      # The name home-manager used before 25.05, kept so older configurations
      # can consume this flake unchanged.
      homeManagerModules = self.homeModules;

      checks = forAllSystems (pkgs: {
        inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) keyhint;

        # --config is explicit because the check is handed ./src on its own,
        # which does not carry the ruff.toml at the repository root.
        lint = pkgs.runCommand "keyhint-lint" { nativeBuildInputs = [ pkgs.ruff ]; } ''
          ruff check --no-cache --config ${./ruff.toml} ${./src}
          ruff format --no-cache --check --diff --config ${./ruff.toml} ${./src}
          touch $out
        '';
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          inputsFrom = [ self.packages.${pkgs.stdenv.hostPlatform.system}.keyhint ];
          packages = [
            pkgs.ruff
            pkgs.nixfmt-rfc-style
          ];
        };
      });
    };
}
