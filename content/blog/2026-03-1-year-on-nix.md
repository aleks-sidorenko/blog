+++
title = "1 Year on Nix"
date = 2026-03-06
description = "After 8 years on Ubuntu with a carefully curated dotfiles repo, I switched to Nix. Here's what changed — and what I can't unsee."
path = "blog/2026/03/1-year-on-nix"
[taxonomies]
tags = ["nix", "linux", "devtools"]
categories = ["programming"]
+++

For eight years, Ubuntu was my home. I knew the system inside out — or at least I thought I did. I had a [dotfiles repo](https://github.com/aleks-sidorenko/dotfiles), a symlink manager, and a comfortable routine. Everything was version controlled. Everything was under control.

It wasn't.

<!-- more -->

## The Ubuntu years

Don't get me wrong — Ubuntu served me well. It's stable, the community is massive, and when something breaks, someone on Stack Overflow has already fixed it. For most of those eight years, I was productive and happy.

My setup looked responsible. I kept my configs in a [GitHub repo](https://github.com/aleks-sidorenko/dotfiles) and used the [dotfiles](https://pypi.org/project/dotfiles/) Python tool to manage symlinks. Shell config, Neovim, tmux, Git — all tracked. I could look at my repo and feel like I had a complete picture of my environment.

But over time, cracks appeared. Not dramatic ones — the quiet kind.

Every `apt install` I ran left a trace on the system but not in my repo. Dependencies accumulated silently. I'd install a tool for a one-off task and forget about it. Months later, I'd find configs referencing tools I wasn't sure were still there. PPAs I'd added years ago would break on an upgrade. The system was slowly drifting from anything I could describe or reproduce.

My dotfiles repo tracked the *configs* but not the *software they configured*. It was a map, but the territory underneath kept shifting.

## The breaking point

The moment of clarity came when I set up a new machine. I cloned my dotfiles repo, ran the symlink tool, and... sat there for hours. Installing packages by hand. Googling what I'd used to get some plugin working. Trying to remember which PPA provided which tool.

My "version controlled environment" got me maybe 30% of the way. The rest was tribal knowledge — things I'd done once, never wrote down, and only noticed when they were missing.

That's when I started to question the model itself. The problem wasn't that my dotfiles were poorly organized. The problem was that *configs without their corresponding software aren't a complete environment description*. They're just text files.

## Discovering Nix

I'd heard of Nix before but dismissed it as overkill. A whole new package manager? A custom language? Sounded like a lot of ceremony for something `apt` already did fine.

When I finally gave it a real try, the language was strange. The documentation was a maze. I spent evenings reading wiki pages and squinting at error messages that seemed designed to punish newcomers.

But underneath the rough edges, one idea kept pulling me forward: *what if your entire environment was a function of a configuration file?* Not just the configs. The packages, the services, the shell, the fonts — everything. Described once, reproducible anywhere.

## The mindset shift: imperative to declarative

This is the core of what changed for me, and it goes beyond tooling.

On Ubuntu, setting up a tool was a series of steps. Install the package, edit a config file, maybe add a symlink, maybe restart a service. Each step changed the system. If something went wrong halfway through, you were left in a partial state. The "current state of the system" was the sum of every command you'd ever run, minus the ones you'd undone, minus the ones that had been overwritten by upgrades.

With Nix, you describe the desired state:

```nix
{ pkgs, ... }:
{
  home.packages = with pkgs; [
    ripgrep
    fd
    jq
    htop
  ];

  programs.neovim = {
    enable = true;
    defaultEditor = true;
  };

  programs.git = {
    enable = true;
    userName = "Alexander Sidorenko";
    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = true;
    };
  };
}
```

That's not a script that *does* things. It's a description of what the system *should look like*. Nix figures out how to get there. If you remove a line, the package is gone. If you change a value, only that value changes. There's no hidden state, no forgotten side effects, no drift.

On Ubuntu, I'd `apt install ripgrep` and then three years later wonder if I still needed it. With Nix, if it's not in the config, it doesn't exist.

## Dotfiles vs. a real environment

My old dotfiles repo had a fundamental gap: it tracked *configuration* but not *infrastructure*. My `.bashrc` referenced `fzf`, but nothing in the repo made sure `fzf` was installed. My Neovim config assumed dozens of plugins and tools were present, but that was someone else's problem.

Nix closes this gap. Packages and their configuration live together:

```nix
programs.tmux = {
  enable = true;
  terminal = "tmux-256color";
  keyMode = "vi";
  plugins = with pkgs.tmuxPlugins; [
    sensible
    yank
  ];
  extraConfig = ''
    set -g mouse on
    set -g base-index 1
  '';
};
```

This single block says: install tmux, install these plugins, and apply this configuration. It's one unit. You can't have the config without the software, and you can't have the software without the config. The old split between "what's installed" and "how it's configured" just doesn't exist.

## One config, two platforms

Here's something I never expected: I now manage both NixOS (my personal machine) and macOS (my work machine) from the [same repository](https://github.com/aleks-sidorenko/nix-config).

The shared parts — shell config, Git settings, editor setup, CLI tools — are defined once and used everywhere. Platform-specific pieces (Linux services, macOS defaults) are in separate modules that only activate on the right system.

One repo. Two operating systems. A `git push` away from being in sync.

On Ubuntu, I would have maintained two completely separate setups — or, more realistically, let the work machine drift into its own undocumented state.

## The honest cost

I'd be lying if I said this transition was painless.

The Nix language is its own thing. It's not Bash, it's not Python, it's not YAML. It's a lazy, purely functional language, and until you fully understand its evaluation model, you will be confused.

Error messages can be cryptic. When something goes wrong deep in a derivation, the stack trace reads like abstract poetry. You'll spend time debugging issues that feel like they shouldn't exist.

The documentation situation has improved but is still scattered. You'll find yourself reading source code to understand how a module works, because the docs either don't exist or describe an older version.

And there's a social cost too — most of your colleagues won't be using Nix, which means you'll sometimes need to stay compatible with more standard setups.

## What I can't unsee

After a year on Nix, I can't go back. Not because Nix is perfect — it clearly isn't. But because it showed me something I can no longer ignore: the invisible state that accumulates on an imperative system.

Every Ubuntu machine I've ever used was a unique snowflake — the product of thousands of commands, each reasonable in isolation, adding up to something no one could fully describe. My dotfiles repo papered over this reality but didn't solve it.

Nix doesn't just manage packages. It changes how you think about environments. Your system is a value, computed from a function, derived from a config file checked into Git. If you can read the config, you know the system. If you can build the config, you have the system.

Eight years on Ubuntu taught me a lot. One year on Nix taught me what I was missing.
