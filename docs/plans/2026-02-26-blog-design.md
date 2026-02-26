# Personal Blog Design

## Goal

Set up a personal blog at `www.sidorenko.me` using Zola with the Even theme, hosted on GitHub Pages via the separate `aleks-sidorenko/blog` repo.

## Decisions

- **SSG:** Zola (single Rust binary, fast, Nix-friendly)
- **Theme:** [getzola/even](https://github.com/getzola/even) — clean blog theme, commit `994bfdb426a75f6615a2da649d9eb57870b1ca88`
- **Repo:** Separate repo at `https://github.com/aleks-sidorenko/blog` (cloned to `~/Projects/Self/blog`)
- **Hosting:** GitHub Pages with custom domain `www.sidorenko.me`
- **Build:** Nix flake wrapping Zola — `nix build` produces static site, `nix run .#serve` for local dev
- **CI:** GitHub Actions — build with Nix, deploy to GitHub Pages on push to `main`

## Architecture

```
blog/                          # aleks-sidorenko/blog repo
├── flake.nix                  # Nix flake: fetches Even theme, builds with zola
├── flake.lock
├── config.toml                # Zola site config (base_url, theme, taxonomies)
├── content/
│   ├── _index.md              # Homepage listing (paginate_by, sort_by)
│   └── first-post.md          # Example post
├── static/
│   └── CNAME                  # "www.sidorenko.me" — GitHub Pages custom domain
├── sass/                      # Custom style overrides (empty initially)
├── templates/                 # Template overrides (empty initially)
└── .github/
    └── workflows/
        └── deploy.yml         # CI: nix build → deploy to GitHub Pages
```

### flake.nix

- Input: `nixpkgs`
- Fetches Even theme via `fetchFromGitHub`
- `packages.default` = `stdenv.mkDerivation` that:
  1. Copies site source
  2. Symlinks theme into `themes/even`
  3. Runs `zola build`
  4. Output: `$out` contains static HTML from `public/`
- `packages.serve` = `writeShellScriptBin` that sets up theme and runs `zola serve`

### config.toml

- `base_url = "https://www.sidorenko.me"`
- `theme = "even"`
- Taxonomies: tags, categories (required by Even)
- `[extra]` section: `even_title`, `even_menu` (Home, Tags, Categories, About)

### GitHub Actions

- Trigger: push to `main`
- Uses `cachix/install-nix-action` for Nix
- Runs `nix build`
- Deploys `result/public/` via `actions/deploy-pages`

### DNS (manual)

- CNAME: `www` → `aleks-sidorenko.github.io`
- A records for apex: GitHub Pages IPs (185.199.108-111.153)
- Enable "Enforce HTTPS" in repo Settings > Pages

## Not in scope

- nix-config integration (can be added later as a flake input)
- Self-hosting on homelab
- Comments system, analytics
