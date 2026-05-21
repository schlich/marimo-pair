{
  description = "marimo-pair — a Claude agent skill for working inside a running marimo notebook's kernel";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = self.packages.${system}.marimo-pair;

          # The skill directory itself. $out contains SKILL.md, scripts/, and
          # reference/ — point a Claude skills directory at it:
          #
          #   home.file.".claude/skills/marimo-pair".source =
          #     inputs.marimo-pair.packages.${system}.default;
          marimo-pair = pkgs.stdenvNoCC.mkDerivation {
            pname = "marimo-pair-skill";
            version = "0.0.15";
            src = ./skills/marimo-pair;

            dontConfigure = true;
            dontBuild = true;

            installPhase = ''
              runHook preInstall
              mkdir -p $out
              cp -r . $out/
              runHook postInstall
            '';

            meta = {
              description = "Claude agent skill for pair-programming with a running marimo notebook";
              homepage = "https://github.com/marimo-team/marimo-pair";
              license = pkgs.lib.licenses.asl20;
              platforms = pkgs.lib.platforms.unix ++ [ "x86_64-windows" ];
            };
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShellNoCC {
            packages = [
              pkgs.nushell
              pkgs.curl
            ];
          };
        }
      );
    };
}
