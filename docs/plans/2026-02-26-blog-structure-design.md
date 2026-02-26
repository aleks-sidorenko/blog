# Blog Structure Design

## Goal

Establish the initial blog content structure: About page, blog post conventions, categories, tags, and a demo Haskell post.

## URL Strategy

Zola lacks automatic URL templates (like Hugo's `permalinks`). Use explicit `path` front matter per post.

- **Filename pattern:** `content/yyyy-mm-post-name.md`
- **URL pattern:** `/blog/yyyy/mm/post-name/` (via `path = "blog/yyyy/mm/post-name"`)
- **About page:** `content/about.md` → `/about/`

## About Page

Developer-oriented bio at `/about`:
- Brief intro (FP enthusiast, Haskell/Nix developer)
- Placeholder links: GitHub, X (Twitter), LinkedIn, Email
- Key interests: functional programming, Haskell, Nix, type systems

## Blog Post Front Matter Template

```toml
+++
title = "Post Title"
date = YYYY-MM-DD
description = "Short description"
path = "blog/YYYY/MM/post-slug"
[taxonomies]
tags = ["tag1", "tag2"]
categories = ["Category Name"]
+++
```

## Demo Post

`content/2026-02-getting-started-with-haskell.md` → `/blog/2026/02/getting-started-with-haskell/`

Covers: basic syntax, type signatures, pattern matching, higher-order functions, practical example — all with code blocks.

## Categories

| Category | Description |
|---|---|
| Functional Programming | Haskell, FP concepts, type theory |
| Nix & DevOps | Nix, NixOS, reproducible builds, CI/CD |
| Software Engineering | Architecture, patterns, best practices |
| System Design | Distributed systems, scalability, architecture decisions |
| Artificial Intelligence | ML, LLMs, AI tooling, applied AI |
| Tools & Workflow | Editor setups, CLI tools, productivity |

## Tags

haskell, nix, nixos, functional-programming, types, monads, category-theory, flakes, devops, git, linux, tutorial, rust, elm, purescript, ghc, cabal, stack, neovim, emacs, system-design, distributed-systems, scalability, ai, llm, machine-learning, claude, copilot

## Changes to Existing Content

- Remove `content/first-post.md`
- Add `content/about.md`
- Add `content/2026-02-getting-started-with-haskell.md`
- No changes to `config.toml` (menu already includes Home, Categories, Tags, About)
- Keep `content/_index.md` as-is (homepage lists posts with pagination)
