# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Personal blog for Oleksandr Sidorenko (www.sidorenko.me) built with Zola static site generator, using the Even theme, with Nix flake for reproducible builds and GitHub Pages for hosting.

## Build & Development Commands

Enter the dev shell first (`nix develop`), then use `just`:

```bash
just help            # List available commands
just start           # Run local dev server at http://localhost:1111
just open            # Open blog in browser
just format          # Format Nix files
nix build            # Build static site (output in result/)
```

The Nix flake automatically fetches the Even theme from GitHub during build — no manual theme installation needed.

## Architecture

- **Nix flake** (`flake.nix`): Manages the entire build pipeline. Fetches the Even theme as a pinned GitHub source, copies it into the build directory, then runs `zola build`. Supports multi-platform (Linux/macOS, x86_64/aarch64).
- **CI/CD** (`.github/workflows/deploy.yml`): Pushes to `master` trigger `nix build` on GitHub Actions, then deploy to GitHub Pages.
- **Theme customization**: Override Even theme templates in `templates/` and styles in `sass/` (currently empty — defaults used).

## Content Authoring

Blog posts go in `content/` as Markdown files with TOML front matter:

```markdown
+++
title = "Post Title"
date = 2026-02-26
description = "Short description"
[taxonomies]
tags = ["tag1"]
categories = ["category1"]
+++

Post content here.
```

Pagination is set to 5 posts per page, sorted by date (configured in `content/_index.md`).

## Key Configuration

- `config.toml`: Site URL, theme, taxonomy, feed, and syntax highlighting settings
- `static/CNAME`: Custom domain for GitHub Pages
- Syntax highlighting theme: One Dark Pro
- Feed format: Atom (`atom.xml`)
