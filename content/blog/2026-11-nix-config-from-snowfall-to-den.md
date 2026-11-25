+++
title = "Moving My nix-config from Snowfall to den"
date = 2026-11-20
description = "Why I rewrote my nix-config from Snowfall lib on den and the dendritic pattern, what Snowfall got wrong for me, and what aspects gave me instead."
path = "blog/2026/11/nix-config-from-snowfall-to-den"
[taxonomies]
tags = ["nix", "den", "infrastructure"]
categories = ["programming"]
+++

When I wrote [1 Year on Nix](/blog/2026/03/1-year-on-nix), my [nix-config](https://github.com/aleks-sidorenko/nix-config/tree/snowfall) was built on [Snowfall lib](https://github.com/snowfallorg/lib). It had served me well: it gave a new Nix user a structure to follow. But a year and a half in, most of my changes were fighting that structure instead of using it.

This month I rewrote the whole config on [den](https://den.denful.dev), an aspect-oriented framework for the [dendritic pattern](https://github.com/mightyiam/dendritic). This post covers why, what the new layout looks like, and how I switched a running home server without losing it.

<!-- more -->

## What Snowfall gave me

Snowfall is convention over configuration. You put files in the right directories and it wires them up: `systems/x86_64-linux/server` becomes a NixOS host, `homes/x86_64-linux/alexander@server` becomes a home-manager config, and everything under `modules/nixos`, `modules/darwin`, and `modules/home` is imported automatically. For someone coming from Ubuntu and a dotfiles repo, that was exactly right. I didn't have to understand flake outputs to get a working machine.

The problems showed up later, as the config grew to a home server, its test VM, a Mac, and four Terraform stacks.

## Where it hurt

### Features split by platform

Snowfall sorts modules by *where they run*: `modules/nixos`, `modules/darwin`, `modules/home`. That sounds tidy until one feature runs in more than one place. Tailscale ran on both the server and the Mac, so it lived in two files:

```text
modules/darwin/services/networking/tailscale/default.nix
modules/nixos/services/networking/tailscale/default.nix
```

Most features worth having a module for had a system part and a home part, so the same idea was spread over two or three trees. Changing a feature meant finding all of its pieces first.

### Enable flags everywhere

Every Snowfall module followed the same shape: declare an option under your namespace, read it back as `cfg`, wrap the whole body in `mkIf cfg.enable`:

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

Hosts then flipped those flags on:

```nix
${namespace} = {
  roles.home-server = enabled;
  roles.smart-home = disabled;
  disks.impermanence = enabled;
};
```

Every module was imported on every host and switched off by default. The real question, "which features does this machine have?", was answered by a scattered set of booleans instead of a list.

### A global grab bag

Anything two modules needed to agree on ended up in `lib/defaults`: the username, locales, the persistence root, the Cloudflare account, the backup bucket, the LAN subnet, and every host's IP and MAC. It started as a few constants and became the place where everything was coupled to everything. The router stack read `defaults.network.hosts`. The restic module and the storage stack both read `defaults.backup.bucket` "so the two can't drift". The comment was right, but a global was the only tool I had for it.

### Cross-cutting data had no home

Adding a service like Jellyfin to the server touched several places. Its state directory went into the impermanence module, its virtual host into nginx, its cache exclude into restic. The service module couldn't say "here's what I need from others", so I edited the others.

### Infrastructure outside the system

My Terraform stacks (DNS, tailnet, storage, router) lived next to Snowfall, not inside it, with their own helpers in `lib/terraform`. They couldn't use the module structure the hosts had, so they talked to hosts through `lib/defaults` too.

None of these were bugs in Snowfall. They are the natural limits of a layout organized by platform and switched on by flags.

## What den does differently

den organizes the config by *aspect*. An aspect is a feature, like `services.tailscale` or `services.jellyfin`, and one aspect holds everything that feature means, for every place it applies: NixOS, nix-darwin, home-manager, and Terraform. Hosts don't enable aspects. They *include* them, directly or through roles.

### Every file is a module

[import-tree](https://github.com/denful/import-tree) loads every file under `modules/` as a flake-parts module. The aspect path mirrors the file path: `modules/services/jellyfin.nix` defines `den.aspects.services.jellyfin`. Modules share values only through `config`, so a file can move or go away without breaking another one.

`flake.nix` is generated by [flake-file](https://github.com/denful/flake-file). Each module declares the inputs it needs, right next to the code that uses them:

```nix
flake-file.inputs.nix-routeros = {
  url = "github:aleks-sidorenko/nix-routeros/v2.0.0";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Delete the module and its input goes with it.

### A service says what it needs

Here is the start of the Jellyfin aspect:

```nix
den.aspects.services.jellyfin = {
  includes = [ den.aspects.services.media ];
  persist.directories = [ stateDir ];
  # Regenerable, and most of a backup by size.
  backup.exclude = [ cacheDir ];
  installChecks = [ ''machine.wait_for_unit("jellyfin.service")'' ];

  vhosts = [
    {
      name = "jellyfin";
      port = webPort;
    }
  ];

  nixos = { config, host, ... }: {
    services.jellyfin = { enable = true; /* ... */ };
  };
};
```

`persist`, `backup`, `vhosts`, and `installChecks` are *quirks*: values that many aspects contribute and one aspect collects. Impermanence collects `persist`, nginx turns `vhosts` into one virtual host each, restic collects `backup`, and the install test runs every `installChecks` entry. Jellyfin declares what it needs in its own file, and the aspects that care pick it up. That was the "cross-cutting data" problem, and it's the part of den I use most.

### Settings belong to the aspect that reads them

Instead of a global `defaults`, each tunable is a setting of the aspect that reads it: `system.locale.timeZone`, `storage.disko.device`, `services.restic.bucketUrl`. A host sets only what differs from the default:

```nix
den.hosts.x86_64-linux.server = {
  deploy = { };
  settings.storage.disko.device = "/dev/disk/by-id/ata-SSD_2TB_004208";
};
```

### Roles are just includes

A role is an aspect with nothing but `includes`. The server's whole feature set reads as a tree:

```text
roles.home-server
├── roles.server
│   ├── roles.base: sudo, core CLI, boot, disko, impermanence, sops
│   ├── system.headless, system.networkmanager, system.nix-ld
│   ├── services.tailscale
│   └── security.sudo.passwordless
├── roles.media-server
│   └── services.{jellyfin, nginx, qbittorrent, sonarr, radarr, ...}
├── services.restic
└── services.minecraft-server
```

No flags, no `mkIf cfg.enable`. If an aspect isn't in the tree, it isn't on the machine.

### Infrastructure as entities

Terraform stacks are den entities like hosts, declared as `den.stacks.<name>` and built from aspects with a `terranix` body. A stack learns about hosts through quirks, never by reading a host's evaluated config. The DNS stack collects `published-names` from deployed hosts; the tailnet stack collects each host's tags. The router works the same way, which is what pushed me to rewrite [nix-routeros as v2](/blog/2026/11/nix-routeros-v2): in den, the server declares its own LAN address and the router stack collects it, so the library no longer needs its own `hosts` option.

The result is about half the files: 253 under `modules/` in the Snowfall tree, 125 under den.

## Switching a live server

I didn't migrate incrementally. Snowfall and den structure a flake in incompatible ways, so I started den from an empty tree and rebuilt each feature as an aspect. I tagged the old tree as [`snowfall`](https://github.com/aleks-sidorenko/nix-config/tree/snowfall) first.

The risk was the server. It runs the media stack, backups, and a Minecraft server, and its root filesystem is wiped on every boot. A rewrite that forgets to persist one directory loses that data on the next reboot. Two kinds of tests made the cutover boring.

**Parity tests.** I generated fixtures from the *evaluated* Snowfall config of the server: its users, groups, firewall, virtual hosts, backups, secrets, networking, service units, and disk layout. The den config is tested against them, so the new tree had to produce the same machine before it was allowed near the real one. The infra stacks got the same treatment: each stack's rendered config is compared with what Snowfall last applied.

**Install tests.** CI installs every VM host into a QEMU guest with throwaway secrets, boots it, power-cycles it, and checks that the root was wiped and persisted state survived. Then it runs every aspect's `installChecks`, fails on any failed systemd unit, and runs a guard that fails on anything under `/var/lib` or `/var/cache` that is neither persisted nor explicitly ignored. That guard is what keeps "forgot to persist one directory" from reaching the server.

It still wasn't perfect. After the cutover, home-manager failed on the server because fish had created its default `config.fish` before home-manager managed it, and Snowfall's config had a `backupFileExtension` I'd dropped. FlareSolverr restarted forever because the new headless aspect turned off fontconfig, which its browser needs. Both were one-line fixes, and both now have tests. The test VM couldn't see either of them, which is a good reminder of what tests can't cover.

## What it costs

den is young. The concepts (aspects, quirks, policies, entities) take time to learn, and the documentation is improving but you'll still read source code. Snowfall's "put a file here" is easier on day one.

But day one isn't where I spend my time. With Snowfall, the structure was something I worked around. With den, adding a service is one file that says what it is and what it needs, and deleting it is deleting that file. That is the same thing that pulled me to Nix in the first place: describe the system instead of patching it.
