+++
title = "1 Year on Nix"
date = 2026-03-06
description = "After 8 years on Ubuntu with a curated dotfiles repo, I switched to Nix. Here's what changed and what I can't unsee."
path = "blog/2026/03/1-year-on-nix"
[taxonomies]
tags = ["nix", "linux", "devtools"]
categories = ["programming"]
+++

For eight years, Ubuntu was my home. I thought I knew the system inside out. I had a [dotfiles repo](https://github.com/aleks-sidorenko/dotfiles), a symlink manager, and a comfortable routine. Everything was version controlled, so I assumed everything was under control. It wasn't.

<!-- more -->

## The Ubuntu years

Ubuntu served me well. It's stable, the community is massive, and when something breaks, someone on Stack Overflow has already fixed it. For most of those eight years, I was productive and happy.

My setup looked responsible. I kept my configs in a [GitHub repo](https://github.com/aleks-sidorenko/dotfiles) and used the [dotfiles](https://pypi.org/project/dotfiles/) Python tool to manage symlinks. Shell config, Neovim, tmux, and Git were all tracked. I could look at my repo and feel like I had a complete picture of my environment.

Over time, small cracks appeared, the kind that are easy to ignore.

Every `apt install` I ran left a trace on the system but not in my repo. Dependencies piled up. I'd install a tool for a one-off task and forget about it. Months later, I'd find configs referencing tools I wasn't sure were still there. PPAs I'd added years ago would break on an upgrade. Slowly, the system drifted away from anything I could describe or reproduce.

My dotfiles repo tracked the *configs* but not the *software they configured*. It was a map, but the territory under it kept shifting.

## The breaking point

It hit me when I set up a new machine. I cloned my dotfiles repo, ran the symlink tool, and... sat there for hours. Installing packages by hand. Googling what I'd used to get some plugin working. Trying to remember which PPA provided which tool.

My "version controlled environment" got me maybe 30% of the way. The rest was tribal knowledge: things I'd done once, never written down, and only noticed when they were missing.

That's when I started to question the whole approach. My dotfiles were organized well enough. The problem was that *configs without their corresponding software aren't a complete environment description*. They're just text files.

## Discovering Nix

I'd heard of Nix before but dismissed it as overkill. A whole new package manager? A custom language? Sounded like a lot of ceremony for something `apt` already did fine.

When I finally gave it a real try, the language was strange and the documentation was a maze. I spent evenings reading wiki pages and squinting at error messages that seemed designed to punish newcomers.

Still, one idea kept me going: *what if your entire environment was a function of a configuration file?* That means the packages, the services, the shell, and the fonts along with the configs, all described once and reproducible anywhere.

## The mindset shift: imperative to declarative

This is the biggest thing that changed for me, and it's about more than tooling.

On Ubuntu, setting up a tool was a series of steps. Install the package, edit a config file, maybe add a symlink, maybe restart a service. Each step changed the system. If something went wrong halfway through, you were left in a partial state. The current state of the system was the sum of every command you'd ever run, minus the ones you'd undone, minus the ones that upgrades had overwritten.

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

This isn't a script that *does* things. It describes what the system *should look like*, and Nix figures out how to get there. If you remove a line, the package is gone. If you change a value, only that value changes. No hidden state or forgotten side effects build up, so the system doesn't drift.

On Ubuntu, I'd `apt install ripgrep` and then three years later wonder if I still needed it. With Nix, if it's not in the config, it doesn't exist.

## Dotfiles vs. a real environment

My old dotfiles repo had a big gap: it tracked *configuration* but not *infrastructure*. My `.bashrc` referenced `fzf`, but nothing in the repo made sure `fzf` was installed. My Neovim config assumed dozens of plugins and tools were present, but that was someone else's problem.

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

This one block installs tmux, installs these plugins, and applies this configuration as a single unit. You can't have the config without the software or the software without the config, so the old split between "what's installed" and "how it's configured" goes away.

## One config, two platforms

I didn't expect this part: I now manage both NixOS (my personal machine) and macOS (my work machine) from the [same repository](https://github.com/aleks-sidorenko/nix-config).

The shared parts (shell config, Git settings, editor setup, CLI tools) are defined once and used everywhere. Platform-specific pieces (Linux services, macOS defaults) live in separate modules that only activate on the right system.

So one repo covers two operating systems, and both machines are a `git push` away from being in sync.

On Ubuntu, I would have maintained two completely separate setups. More realistically, I'd have let the work machine drift into its own undocumented state.

## The honest cost

The switch wasn't painless.

The Nix language is its own thing. It isn't Bash, Python, or YAML. It's a lazy, purely functional language, and until you understand its evaluation model, you will be confused.

Error messages can be cryptic. When something goes wrong deep in a derivation, the stack trace reads like abstract poetry. You'll spend time debugging issues that feel like they shouldn't exist.

The documentation has improved but is still scattered. You'll find yourself reading source code to understand how a module works, because the docs either don't exist or describe an older version.

There's a social cost too. Most of your colleagues won't be using Nix, so you'll sometimes need to stay compatible with more standard setups.

## What I can't unsee

After a year on Nix, I can't go back. Nix clearly isn't perfect, but it showed me the invisible state that builds up on an imperative system, and I can't ignore that anymore.

Every Ubuntu machine I've ever used was a unique snowflake: the product of thousands of commands, each reasonable on its own, adding up to something no one could fully describe. My dotfiles repo papered over this but didn't solve it.

Nix also changed how I think about environments. Your system is a value, computed by a function from a config file checked into Git. If you can read the config, you know the system. If you can build the config, you have the system.

Eight years on Ubuntu taught me a lot, but it took one year on Nix to show me what I was missing.
