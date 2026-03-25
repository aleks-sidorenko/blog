{
  description = "Personal blog built with Zola";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    let
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs
          [
            "x86_64-linux"
            "aarch64-linux"
            "x86_64-darwin"
            "aarch64-darwin"
          ]
          (
            system:
            f {
              pkgs = nixpkgs.legacyPackages.${system};
            }
          );

      theme = {
        owner = "getzola";
        repo = "even";
        rev = "994bfdb426a75f6615a2da649d9eb57870b1ca88";
        hash = "sha256-ZKO2+C7DU01IFxCLNAsL+m68LJ29O5ZqtCTJNWQkwTA=";
      };
    in
    {
      packages = forAllSystems (
        { pkgs }:
        let
          evenTheme = pkgs.fetchFromGitHub {
            inherit (theme) owner repo rev hash;
          };
        in
        {
          default = pkgs.stdenv.mkDerivation {
            name = "blog";
            src = ./.;

            nativeBuildInputs = [ pkgs.zola ];

            buildPhase = ''
              mkdir -p themes/even
              cp -r ${evenTheme}/* themes/even/
              zola build -o $out
            '';

            dontInstall = true;
          };

          serve = pkgs.writeShellScriptBin "blog-serve" ''
            SITE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
            if [ -f "$SITE_DIR/config.toml" ]; then
              cd "$SITE_DIR"
            else
              cd "${./.}"
            fi
            TMPDIR=$(mktemp -d)
            cp -r . "$TMPDIR/"
            mkdir -p "$TMPDIR/themes/even"
            cp -r ${evenTheme}/* "$TMPDIR/themes/even/"
            chmod -R u+w "$TMPDIR"
            cd "$TMPDIR"
            ${pkgs.zola}/bin/zola serve
          '';
        }
      );

      formatter = forAllSystems ({ pkgs }: pkgs.nixfmt-rfc-style);

      devShells = forAllSystems (
        { pkgs }:
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.zola
              pkgs.just
              pkgs.nodejs
            ];
          };
        }
      );
    };
}
