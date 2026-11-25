+++
title = "Managing MikroTik RouterOS with Nix"
date = 2026-03-25
description = "How I went from exporting raw MikroTik configs to a NixOS-style module system for my router, packaged as a Nix flake."
path = "blog/2026/03/managing-mikrotik-with-nix"
[taxonomies]
tags = ["nix", "networking", "mikrotik", "infrastructure"]
categories = ["programming"]
+++

My home network runs on a MikroTik router. The hardware is capable, and the configuration system is powerful but very imperative. RouterOS gives you a CLI, a GUI (WinBox), and a scripting language that feels like it was designed for a world where "just SSH in and change it" is a valid way to operate.

For a while, that was exactly what I did. Then I tried to bring the same declarative thinking I use for [everything else](/blog/2026/03/1-year-on-nix) to my router. It took three attempts to get it right.

<!-- more -->

> This post describes v1 of nix-routeros (tag `v1.0.0`). v2 changed the option set and dropped the bundled runner; see [nix-routeros v2: a library, not a framework](/blog/2026/11/nix-routeros-v2).

## Attempt 1: Export everything, import everything

My first idea was simple. RouterOS has an `/export` command that dumps the entire router configuration as a script. I ran it, saved the output, and committed it to Git. Then I wrote a Nix derivation that would take this exported script and push it back to the router. Version control for my router config: done.

**What worked.** The router config was in Git for the first time. I could see diffs between versions, and I had a backup to restore from. Compared to clicking around in WinBox and hoping I remembered what I changed, this was a real improvement. If the router died, I could buy a new one, factory-reset it, and replay the script.

**What didn't.** The exported config is a complete, ordered script. It assumes you're starting from a factory-reset device. Want to add a single DHCP lease? You can't just apply the diff. You need to reset the router to defaults and replay the entire configuration from scratch.

Every change, no matter how small, meant a full reset and re-apply. That's stressful for a device that runs my entire home network. One syntax error in a 500-line export and you're debugging from a serial console while your family asks why the internet is down.

The exported config was also opaque. It was RouterOS scripting language: a flat list of commands with no structure and no way to say "this block handles DHCP and this block handles firewall." It recorded the router's state without describing it. And since I'd moved it to Nix as-is, it was still imperative. Wrapping a script in a Nix derivation just put the same blob of commands in a fancier box.

**Why I moved on.** The all-or-nothing apply model was the deal breaker. I wanted to change one firewall rule without resetting my entire network. I needed to plan a diff and apply only what changed, which meant I needed a tool that understood individual resources instead of one monolithic script.

## Attempt 2: Terranix modules in nix-config

I discovered [terranix](https://terranix.org) (a tool that generates Terraform JSON from Nix expressions) and the [routeros Terraform provider](https://registry.terraform.io/providers/terraform-routeros/routeros/latest). Instead of scripting the router directly, I could describe individual resources declaratively and let Terraform figure out the diff.

I built a set of Nix modules inside my [nix-config](https://github.com/aleks-sidorenko/nix-config/tree/myla/infra/router) repository under `infra/router/`. Each module handled one aspect of the router: system settings, DHCP, DNS, firewall, WiFi.

**What worked.** This was a huge step forward. Changes were finally incremental: Terraform would plan the diff, show me exactly what would change, and apply only that. No more factory resets. I could add a DHCP lease and see a plan that said "1 resource to add, 0 to change, 0 to destroy." I could review the plan, approve it, and the router would update in seconds while the network stayed up.

The module structure also made things clearer. Instead of one monolithic export, I had separate files for firewall, DNS, DHCP, and system settings, and each one was readable on its own. Nix's type system caught mistakes before they reached the router.

**What didn't.** The modules lived inside my personal nix-config repo, tangled with my NixOS configuration, home-manager setup, and everything else. They were tightly coupled to my specific network. The firewall module hardcoded my subnet. The DNS module assumed my naming conventions. Host definitions were scattered: a DHCP lease in one file, the corresponding DNS record in another, with nothing enforcing consistency between them.

Testing was awkward too. I couldn't build or validate the router modules without the rest of my nix-config flake. And if someone else wanted to manage their MikroTik with Nix, they'd have to fork my entire repo and remove everything specific to my network.

**Why I moved on.** The approach was good. Nix modules generating Terraform via terranix was exactly the right stack. But the code was stuck inside a monorepo where it couldn't grow on its own. I wanted to share this with others, and I wanted clean separation between "how to configure a MikroTik router" (generic) and "how my specific router is configured" (personal). That meant extracting the modules into their own flake with a proper option interface.

## Attempt 3: nix-routeros

The third attempt took everything I'd learned and extracted it into a standalone flake: [nix-routeros](https://github.com/aleks-sidorenko/nix-routeros/tree/v1.0.0).

The idea is to bring the NixOS module system to RouterOS. You declare what your router should look like using typed options. The flake generates Terraform JSON and gives you scripts to plan and apply changes. Your router configuration becomes a Nix expression that you can compose, type-check, and diff.

It keeps what worked in attempt 2 (incremental changes, plan-before-apply, modular structure) and fixes what didn't. The modules are now generic, reusable, and fully decoupled from my personal config. My [actual router configuration](https://github.com/aleks-sidorenko/nix-config/tree/v1/infra/router) is just a thin `router.nix` that imports the flake and sets values specific to my network.

### Getting started

```bash
nix flake init -t github:aleks-sidorenko/nix-routeros/v1.0.0
```

This gives you a `flake.nix` and a `router.nix` to edit. Here's what a minimal configuration looks like:

```nix
{
  routeros = {
    connection.gateway = "10.0.0.1";

    network = {
      subnet = "10.0.0.0/24";
      dhcp.server.range = "10.0.0.50-10.0.0.250";
    };

    bridge.ports = [ "ether2" "ether3" "ether4" "ether5" ];

    hosts.server = {
      ip = "10.0.0.10";
      mac = "AA:BB:CC:DD:EE:FF";
      comment = "Home server";
      aliases = [ "jellyfin" "home-assistant" ];
    };
  };
}
```

That's the entire router config. No Terraform files, no provider blocks, no resource naming. The flake handles all of it.

### Hosts as the single source of truth

The `hosts` option is the most important design decision. You define a host once and everything else follows from it:

```nix
hosts = {
  nas = {
    ip = "10.0.0.10";
    mac = "AA:BB:CC:DD:EE:01";
    comment = "Synology NAS";
    aliases = [ "media" "backups" ];
  };
  printer = {
    ip = "10.0.0.11";
    mac = "AA:BB:CC:DD:EE:02";
    comment = "HP LaserJet";
  };
};
```

From this, the flake automatically generates:
- Static DHCP leases for each host (so they always get the same IP)
- DNS A records (`nas.local`, `printer.local`)
- DNS aliases (`media.local`, `backups.local` pointing to the NAS)

Nothing is duplicated. Add a device to `hosts` and it appears everywhere it should; remove it and it disappears. This is easy to get wrong when you manage individual Terraform resources by hand.

### Secure defaults with the router preset

The flake ships with an opinionated `router` preset with sane defaults for a home router:

- SSH, WinBox, and API enabled but restricted to the LAN subnet
- FTP, Telnet, and WWW disabled
- DHCP server and client enabled
- DNS with upstream forwarding and `.local` domain
- Full firewall with 13 filter rules and NAT
- IPv6 disabled

All preset values use `lib.mkDefault`, so you can override any of them in your config without `mkForce`:

```nix
{
  routeros.system = {
    timezone = "Europe/Berlin";
    services.ssh.port = 2222;
    ipv6.enable = true;  # override the preset
  };
}
```

### The firewall you don't have to write

Writing firewall rules for RouterOS is tedious and error-prone. Rule order matters, and one misplaced rule can lock you out or leave your network wide open.

The preset includes a complete firewall with deterministic rule ordering via `place_before` chaining. It handles established/related connections, drops invalid packets, allows ICMP, enables fasttrack, blocks DNS from WAN, and sets up masquerade NAT. You get a production-ready firewall without writing a single rule.

Need custom rules? Append them:

```nix
{
  routeros.firewall = {
    addressLists.my-servers = [ "10.0.0.10" "10.0.0.11" ];
    filterRules = [
      {
        chain = "forward";
        action = "accept";
        src_address_list = "my-servers";
        dst_port = "443";
        protocol = "tcp";
        comment = "Allow HTTPS from servers";
      }
    ];
  };
}
```

### Plan before you apply

The flake generates four scripts for each router derivation:

```bash
export FLAKE_DIR=$(pwd)

nix run .#default          # Show generated Terraform JSON
nix run .#default.plan     # Preview changes
nix run .#default.apply    # Apply to router
nix run .#default.destroy  # Remove managed resources
```

The `plan` step is the important one. Before anything touches the router, you see exactly what will change. Add a host, and the plan shows two new resources (DHCP lease + DNS record). Change a firewall rule, and it shows the modification.

### Secrets with SOPS

Router passwords and WiFi keys don't belong in Git. The flake integrates with [SOPS](https://github.com/getsops/sops) for encrypted secrets:

```nix
nix-routeros.lib.mkRouterDerivation {
  inherit pkgs system;
  modules = [ ./router.nix ];
  stateDir = "infra/router";
  secretsFile = "infra/router/secrets.yaml";
  secrets = {
    TF_VAR_routeros_password = "router-api-password";
    TF_VAR_wifi_password = "wifi-password";
  };
};
```

Secrets are decrypted at runtime, never written to disk in plaintext, and never committed to the repo.

## What changed

The progression from exported configs to nix-routeros mirrors the same shift I described in my [Nix journey](/blog/2026/03/1-year-on-nix): from imperative snapshots to declarative descriptions.

The RouterOS export was like my old dotfiles repo: a recording of state. It told you what the router looked like at one point in time, but not why, and not how to change it safely.

nix-routeros gives me what NixOS gives me for my machines: a single source of truth that I can read, review, diff, and apply incrementally. My router configuration is 40 lines of Nix. It's checked into Git next to the rest of my infrastructure. When I need to add a device to my network, I add three lines to `hosts` and run `nix run .#default.apply`. When I want to see what changed since last month, I read the Git log.

The router is no longer a snowflake I'm afraid to touch. It's another piece of infrastructure described by a Nix expression.
