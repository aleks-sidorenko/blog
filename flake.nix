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

      texFor =
        pkgs:
        pkgs.texlive.combine {
          inherit (pkgs.texlive)
            scheme-basic
            luatex
            luaotfload
            libertine
            fontspec
            fontawesome
            xcolor
            preprint # provides fullpage.sty
            amsfonts # provides amssymb
            fancyhdr
            lastpage
            pgf # provides tikz
            hyperref
            titlesec
            tools # longtable, multicol, etc.
            ;
        };
    in
    {
      packages = forAllSystems (
        { pkgs }:
        let
          evenTheme = pkgs.fetchFromGitHub {
            inherit (theme)
              owner
              repo
              rev
              hash
              ;
          };
          tex = texFor pkgs;
        in
        {
          default = pkgs.stdenv.mkDerivation {
            name = "blog";
            src = ./.;

            nativeBuildInputs = [
              pkgs.zola
              tex
            ];

            buildPhase = ''
              mkdir -p themes/even
              cp -r ${evenTheme}/* themes/even/

              # Compile the CV and place it where Zola copies static assets.
              # luaotfload writes a font cache to TEXMFVAR/TEXMFCACHE, which are
              # read-only in the Nix store — point them at writable temp dirs.
              texcache=$(mktemp -d)
              export HOME="$texcache"
              export TEXMFHOME="$texcache"
              export TEXMFVAR="$texcache"
              export TEXMFCACHE="$texcache"
              # Run twice so \pageref{LastPage} resolves on the second pass.
              for i in 1 2; do
                ${tex}/bin/lualatex --interaction=nonstopmode --halt-on-error \
                  --output-directory=cv cv/cv.tex
              done
              cp cv/cv.pdf static/cv.pdf

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
            # Drop any stale CV artifacts copied from the working tree so the
            # rebuild below is deterministic.
            rm -f "$TMPDIR/cv/cv.pdf" "$TMPDIR/cv/"*.aux "$TMPDIR/static/cv.pdf"
            texcache=$(mktemp -d)
            export HOME="$texcache"
            export TEXMFHOME="$texcache"
            export TEXMFVAR="$texcache"
            export TEXMFCACHE="$texcache"
            # Run twice so \pageref{LastPage} resolves on the second pass.
            for i in 1 2; do
              ${tex}/bin/lualatex --interaction=nonstopmode --halt-on-error \
                --output-directory="$TMPDIR/cv" "$TMPDIR/cv/cv.tex"
            done
            cp "$TMPDIR/cv/cv.pdf" "$TMPDIR/static/cv.pdf"
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
              (texFor pkgs)
            ];
          };
        }
      );
    };
}
