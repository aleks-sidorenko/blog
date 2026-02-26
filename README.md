# blog

[![Deploy to GitHub Pages](https://github.com/aleks-sidorenko/blog/actions/workflows/deploy.yml/badge.svg)](https://github.com/aleks-sidorenko/blog/actions/workflows/deploy.yml)

Personal blog at [www.sidorenko.me](https://www.sidorenko.me), built with [Zola](https://www.getzola.org/) and the [Even](https://github.com/getzola/even) theme.

## Tech Stack

- **Zola** — static site generator (Rust, single binary)
- **Even** — clean blog theme with tags, categories, pagination
- **Nix Flake** — reproducible builds, dev environment
- **GitHub Actions** — CI/CD pipeline
- **GitHub Pages** — hosting with custom domain

## Development

```bash
# Enter dev shell with zola available
nix develop

# Build the site
nix build

# Serve locally (http://127.0.0.1:1111)
nix run .#serve
```

## Project Structure

```
├── config.toml          # Zola site configuration
├── content/             # Markdown posts
├── static/              # Static assets (CNAME, images)
├── sass/                # Custom style overrides
├── templates/           # Template overrides
├── flake.nix            # Nix build definition
└── .github/workflows/   # CI/CD deployment
```

## Deployment

Pushes to `master` trigger GitHub Actions which builds the site with `nix build` and deploys to GitHub Pages.
