+++
title = "Moving My nix-config from Snowfall to den"
date = 2026-11-20
description = "Why I rewrote my whole nix-config, from the Mac to the home server to the Terraform stacks, from Snowfall lib to den and the dendritic pattern."
path = "blog/2026/11/nix-config-from-snowfall-to-den"
[taxonomies]
tags = ["nix", "den", "infrastructure"]
categories = ["programming"]
+++

When I wrote [1 Year on Nix](/blog/2026/03/1-year-on-nix), my [nix-config](https://github.com/aleks-sidorenko/nix-config/tree/snowfall) was built on [Snowfall lib](https://github.com/snowfallorg/lib). It had served me well: it gave a new Nix user a structure to follow. But as the config grew, more of my changes were working around that structure than using it.

This month I rewrote all of it on [den](https://den.denful.dev), an aspect-oriented framework for the [dendritic pattern](https://github.com/mightyiam/dendritic): my work MacBook, the home server and its test VMs, the installer image, and the Terraform stacks for DNS, the tailnet, storage, GitHub repos, and the router. This post covers why, what changed, and how I moved everything without breaking the machines I use every day.

<!-- more -->

## What Snowfall gave me

Snowfall is convention over configuration. You put files in the right directories and it wires them up: `systems/aarch64-darwin/workbook` becomes a nix-darwin host, `homes/aarch64-darwin/oleksandrsy@workbook` becomes a home-manager config, and everything under `modules/nixos`, `modules/darwin`, and `modules/home` is imported automatically. For someone coming from Ubuntu and a dotfiles repo, that was exactly right. I didn't have to understand flake outputs to get a working machine.

The problems showed up later, once one repo described a Mac, a NixOS server, VMs, an ISO, and a handful of cloud stacks.

## Where it hurt

### Features split by platform

Snowfall sorts modules by *where they run*: 36 files under `modules/darwin`, 88 under `modules/nixos`, 129 under `modules/home`. That sounds tidy until one feature runs in more than one place. Tailscale ran on both the Mac and the server, so it lived in two files:

```text
modules/darwin/services/networking/tailscale/default.nix
modules/nixos/services/networking/tailscale/default.nix
```

It was the same for apps. Chrome is a home-manager program, but its Dock tile is a nix-darwin setting, so "install Chrome" was half in `modules/home` and half in `modules/darwin`. Changing a feature meant finding all of its pieces first.

### Enable flags everywhere

Every Snowfall module had the same shape: declare an option under your namespace, read it back as `cfg`, and wrap the whole body in `mkIf cfg.enable`:

```nix
{ config, lib, namespace, ... }:
with lib;
let
  cfg = config.${namespace}.services.networking.tailscale;
in
{
  options.${namespace}.services.networking.tailscale = with types; {
    enable = mkEnableOption "Enable tailscale";
    # ...
  };

  config = mkIf cfg.enable {
    services.tailscale.enable = true;
    # ...
  };
}
```

Hosts then flipped those flags:

```nix
${namespace} = {
  roles.home-server = enabled;
  roles.smart-home = disabled;
  disks.impermanence = enabled;
};
```

Every module was imported on every host and switched off by default. The question "what does this machine have?" was answered by booleans scattered across files instead of a list.

### A global grab bag

Anything two modules needed to agree on ended up in `lib/defaults`: the username, locales, the persistence root, the Cloudflare account, the backup bucket, the LAN subnet, and every host's IP and MAC. It started as a few constants and became the place where everything was coupled to everything. The router stack read `defaults.network.hosts`. The restic module and the storage stack both read `defaults.backup.bucket` "so the two can't drift". The comment was right, but a global was the only tool I had for it.

### Cross-cutting data had no home

A feature often needs something from another feature. A server service needs its state directory persisted, a virtual host in nginx, and an entry in the backups. A Mac app needs a Homebrew cask and a Dock tile. In Snowfall, the feature couldn't say what it needed, so I went and edited the other modules.

### Infrastructure outside the system

My Terraform stacks lived next to Snowfall, not inside it, with their own helpers in `lib/terraform`. They couldn't use the module structure the hosts had, so they talked to hosts through `lib/defaults` too.

None of these were bugs in Snowfall. They are the natural limits of a layout organized by platform and switched on by flags.

## What den does differently

den organizes the config by *aspect*. An aspect is a feature, like `services.tailscale` or `gui.chrome`, and one aspect holds everything that feature means, for every place it applies: NixOS, nix-darwin, home-manager, and Terraform. Hosts don't enable aspects. They *include* them, directly or through roles.

### One feature, one file

Here is Chrome, which used to be split across two trees:

```nix
den.aspects.gui.chrome = {
  includes = [
    (den.batteries.unfree [ "google-chrome" ])
    den.aspects.security.pass
  ];

  homeManager = { pkgs, ... }: {
    programs.browserpass.enable = true;
    programs.google-chrome.enable = true;
  };

  darwin = { config, host, lib, ... }: {
    system.defaults.dock.persistent-apps = lib.mkOrder 1100 [
      "${config.users.users.${host.primaryUser}.home}/Applications/Home Manager Apps/Google Chrome.app"
    ];
  };
};
```

The home-manager part, the macOS Dock tile, and the unfree-license allowance all sit together. Homebrew apps work the same way: the aspect that owns the app adds its cask, and `system.homebrew` only sets the policy:

```nix
den.aspects.gui.raycast = {
  includes = [ den.aspects.system.homebrew ];
  darwin.homebrew.casks = [ "raycast" ];
};
```

Categories name a concern, never a platform: `cli` for terminal tools, `dev` for working on code, `gui` for apps, `services` for daemons. An aspect with only a `darwin` body is fine. It still lives where its concern does.

### Every file is a module

[import-tree](https://github.com/denful/import-tree) loads every file under `modules/` as a flake-parts module, and the aspect path mirrors the file path: `modules/gui/chrome.nix` defines `den.aspects.gui.chrome`. Modules share values only through `config`, so a file can move or go away without breaking another one.

`flake.nix` is generated by [flake-file](https://github.com/denful/flake-file). Each module declares the inputs it needs, next to the code that uses them:

```nix
flake-file.inputs.nix-routeros = {
  url = "github:aleks-sidorenko/nix-routeros/v2.0.0";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Delete the module and its input goes with it.

### Features say what they need

For data that many aspects contribute and one aspect collects, den has *quirks*. On the server, Jellyfin declares its own state, backup exclude, virtual host, and install check:

```nix
den.aspects.services.jellyfin = {
  includes = [ den.aspects.services.media ];
  persist.directories = [ stateDir ];
  backup.exclude = [ cacheDir ];
  vhosts = [ { name = "jellyfin"; port = webPort; } ];
  installChecks = [ ''machine.wait_for_unit("jellyfin.service")'' ];
  nixos = { ... }: { services.jellyfin.enable = true; /* ... */ };
};
```

Impermanence collects `persist`, nginx turns `vhosts` into virtual hosts, restic collects `backup`, and the install test runs every `installChecks` entry. The same idea reaches the infrastructure: Tailscale contributes each host's ACL tags to the tailnet stack, and nginx contributes the names a host serves to the DNS stack.

### Settings belong to the aspect that reads them

Instead of a global `defaults`, each tunable is a setting of the aspect that reads it, and a host sets only what differs. The workbook's host definition is mostly the things that are actually specific to a work laptop:

```nix
den.hosts.aarch64-darwin.workbook = {
  # The org names the account; the person is the same.
  users.alexander.userName = "oleksandrsy";
  settings = {
    services.tailscale.tags = [ "tag:workstation" ];
    # ...plus the work VPN and the company's npm registry
  };
};
```

That first line fixed something Snowfall's directory names got wrong. In Snowfall, the Mac's home was `oleksandrsy@workbook` and the server's was `alexander@server`, two different users as far as the config knew. In den, there's one user, `alexander`, with one identity (name, email, Git and SSH keys in `identities/`), and the work laptop just names the account differently.

### Roles are just includes

A role is an aspect with nothing but `includes`. Each machine's feature set reads as a tree instead of a set of flags. The workstation role bundles the macOS system aspects (Homebrew, Dock, Finder, input, power, Touch ID sudo), the `cli`, `dev`, and `gui` aspects, secrets, and Tailscale. The workbook adds only what belongs to the employer: the VPN and a secrets CLI.

```nix
den.aspects.workbook.includes = [
  den.aspects.roles.workstation
  # ...plus the employer's VPN and secrets CLI
];
```

The server's side looks the same, just a different tree:

```text
roles.home-server
├── roles.server
│   ├── roles.base: sudo, core CLI, boot, disko, impermanence, sops
│   ├── system.headless, system.networkmanager
│   └── services.tailscale
├── roles.media-server
│   └── services.{jellyfin, nginx, qbittorrent, sonarr, radarr, ...}
├── services.restic
└── services.minecraft-server
```

The installer ISO is a host too. It includes `roles.core`, the part of the base role that needs no disk layout or secrets, plus an aspect that imports nixpkgs' installer profile. If an aspect isn't in the tree, it isn't on the machine.

### Infrastructure as entities

Terraform stacks are den entities like hosts, declared as `den.stacks.<name>` and built from aspects with a `terranix` body. A stack learns about hosts through quirks, never by reading a host's evaluated config. That's how DNS, the tailnet, storage, and a new stack for my GitHub repos' branch rules all fit the same model.

The router came last, and it didn't fit. Porting it led to a rewrite of the library it uses, which I wrote up separately in [nix-routeros v2: a library, not a framework](/blog/2026/11/nix-routeros-v2). In short, the server now declares its own LAN address and the router stack collects it, so the library no longer needs its own list of hosts.

The result is about half the files: 253 under `modules/` in the Snowfall tree, 125 under den.

## How I moved

I didn't migrate incrementally. Snowfall and den structure a flake in incompatible ways, so I tagged the old tree as [`snowfall`](https://github.com/aleks-sidorenko/nix-config/tree/snowfall), started den from an empty tree, and rebuilt each feature as an aspect. It landed as a series of PRs: the base and the server first, then the workbook and its home, then the DNS, tailnet, and storage stacks, then the installer image, then the router.

Every step had to produce the same result as the tree it replaced, and each kind of target got its own kind of check.

**The server: parity and install tests.** I generated fixtures from the *evaluated* Snowfall config of the server: users, groups, firewall, virtual hosts, backups, secrets, networking, service units, and disk layout. The den config is tested against them. On top of that, CI installs every VM host into a QEMU guest, power-cycles it, checks that the wiped root came back clean and persisted state survived, and fails on any state under `/var/lib` that no aspect declared.

**The workbook: eval tests on what matters.** There's no VM for a Mac, so the tests pin the evaluated config instead: the fish abbreviations and plugins, the Dock layout, network service names, and the decisions I made along the way. One test asserts that no JDK or Node reaches the global environment, because toolchains are now per project (`use_stack jvm` in a project's `.envrc`) instead of global. Another pins the apps I deliberately dropped, so they don't sneak back in.

**The stacks: rendered config.** Each stack's rendered Terraform JSON is compared with the one Snowfall last applied, so the port couldn't quietly change anything the stacks manage.

It still wasn't perfect. On the workbook, Nix ended up behind Homebrew on `PATH`, and `nh` lost track of the flake. On the server, home-manager failed because a setting from the old config had been dropped, and FlareSolverr couldn't start without fontconfig. All were small fixes, and all now have tests. The ones the tests missed were the ones that depended on the real machine, which is a good reminder of what tests can't cover.

## What it costs

den is young. The concepts (aspects, quirks, policies, entities) take time to learn, and the documentation is improving, but you'll still read source code. Snowfall's "put a file here" is easier on day one.

But day one isn't where I spend my time. With Snowfall, the structure was something I worked around. With den, adding an app to the Mac or a service to the server is one file that says what it is and what it needs, and removing it means deleting that file. That is the same thing that pulled me to Nix in the first place: describe the system instead of patching it.
