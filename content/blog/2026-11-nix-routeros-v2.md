+++
title = "nix-routeros v2: A Library, Not a Framework"
date = 2026-11-25
description = "Why I rewrote nix-routeros after moving my nix-config to den, and what v2 brings: device profiles, uplink failover, evaluation checks, and no opinions about your network."
path = "blog/2026/11/nix-routeros-v2"
[taxonomies]
tags = ["nix", "networking", "mikrotik", "infrastructure"]
categories = ["programming"]
+++

In March I wrote about [managing my MikroTik router with Nix](/blog/2026/03/managing-mikrotik-with-nix) and the third attempt that became [nix-routeros](https://github.com/aleks-sidorenko/nix-routeros/tree/v1.0.0). Since then I've moved my [nix-config](https://github.com/aleks-sidorenko/nix-config) from Snowfall to [den](https://github.com/denful/den), and the router had to move with it. v1 didn't fit, and the reasons it didn't fit turned into [nix-routeros v2](https://github.com/aleks-sidorenko/nix-routeros/tree/v2.0.0).

v2 is a breaking release. In one sentence: v1 was a framework that ran your router, and v2 is a library of modules that describes it.

<!-- more -->

## What moving to den exposed

In den you don't organize a config by machine. You organize it by *aspect*: a feature like "SSH", "Wi-Fi", or "the router stack" that can contribute to NixOS, home-manager, and Terraform at once. Each file is a flake-parts module (the dendritic pattern), and hosts pick the aspects they include. Infrastructure that isn't a machine (DNS zones, the tailnet, storage buckets, GitHub repo settings) lives in terranix *stacks* built the same way.

By the time I got to the router, I had four other stacks running on a shared terranix setup in nix-config. It already handled secrets, state encryption, and the plan/apply scripts. Porting the router showed three places where v1 was in the way.

### Two runners

v1 shipped its own runner: `mkRouterDerivation` decrypted SOPS secrets, set up the state directory, needed `FLAKE_DIR`, and generated the `plan`/`apply`/`destroy` scripts. That's convenient for a standalone router repo. In nix-config it duplicated machinery I already had, and the two never quite agreed. My [v1 router config](https://github.com/aleks-sidorenko/nix-config/tree/v1/infra/router) had already drifted to my own `mkTerraformDerivation`, with a comment explaining why the preset now had to be imported by hand:

```nix
modules = [
  # mkRouterDerivation prepended this internally; mkTerraformDerivation
  # doesn't, so the preset is now explicit.
  inputs.nix-routeros.presets.router
  ./imports.nix
  # ...
];
```

When a library's main entry point gets bypassed by its only user, the entry point is in the wrong place.

### Hosts in the wrong place

In March I called `hosts` "the most important design decision": define a host once, get a DHCP lease and DNS records for free. It worked, but it put facts about my server (its MAC and IP) inside the router config. In den, a host is a first-class object with its own definition. The server's LAN address belongs there, next to its disk layout, not in a list inside the router module.

### Opinions about my network

The v1 `router` preset came with defaults: a `.local` domain, upstream DNS, CAPsMAN for Wi-Fi, and no notion of which device you own. Defaults like these are fine until they're wrong, and then you `mkForce` your way around them. A library that other people can use shouldn't guess your subnet or your country.

## What's new in v2

The [README](https://github.com/aleks-sidorenko/nix-routeros/tree/v2.0.0#readme) has the full option reference. Here are the parts that matter.

### Just terranix modules

v2 exports `terranixModules.default` and nothing that runs anything. You plug it into terranix's own `flakeModule`:

```nix
imports = [ inputs.terranix.flakeModule ];
perSystem = { pkgs, ... }: {
  terranix.terranixConfigurations.router = {
    modules = [ nix-routeros.terranixModules.default ./router.nix ];
    workdir = ".";
    terraformWrapper.package = pkgs.opentofu;
  };
};
```

```bash
nix flake init -t github:aleks-sidorenko/nix-routeros
nix build .#router.config     # render config.tf.json, never touches the router
nix run .#router.plan         # tofu init + plan
nix run .#router              # tofu init + apply
```

Secrets follow the same idea. The library declares Terraform variables (`routeros_password`, one passphrase variable per Wi-Fi network, one per PPPoE uplink) and never sees their values. You supply `TF_VAR_*` from whatever secret manager you already use. The SOPS integration, `state_passphrase`, and `FLAKE_DIR` are gone.

### A minimal config, with no hidden defaults

```nix
{
  routeros = {
    device = "hap-ax3";

    connection = {
      address = "192.168.88.1";
      username = "admin";
    };

    lan = {
      address = "192.168.88.1/24";
      dhcp.pool = "192.168.88.100-192.168.88.250";
    };

    uplinks.isp = {
      kind = "ethernet";
      check.host = "1.0.0.1";
    };

    dns.upstream = [ "9.9.9.9" ];

    wifi = {
      country = "United States";
      networks.home = {
        ssid = "home";
        primary = true;
        passphraseVariable = "wifi_home";
      };
    };
  };
}
```

It's a few lines longer than the v1 example, and that's on purpose. The subnet, pool, upstream DNS, and Wi-Fi country have no defaults, because no default would be right for everyone. What *does* have a default is anything that follows from the hardware or from your other options: LAN ports default to the device's Ethernet ports minus the uplink ones, and the subnet is derived from `lan.address`.

The defconf-style firewall is still there and on by default (`firewall.defaults = true`). It's just no longer a separate preset you have to remember to import.

### Device profiles

v1 didn't know which router it was configuring. v2 requires `routeros.device`, which is either a profile name (`hap-ax3`, `hap-ax2`, `hap-ac2`) or an attrset describing the hardware:

```nix
routeros.device = {
  ethernet = [ "ether1" "ether2" "ether3" "ether4" ];
  defaultUplink = "ether1";
  wifi = {
    stack = "wifi"; # or "wireless"
    radios.wifi1.band = "5ghz";
  };
  usb = false;
};
```

The profile drives a lot. It picks the Wi-Fi stack (the newer `wifi` package or the legacy `wireless` one), knows which radio is on which band, and knows whether there's a USB port for an LTE modem. That replaces the CAPsMAN module from v1 with plain access points on the device's own radios.

### Uplinks with failover

v1 had `interfaces.wan` and `interfaces.lte`. v2 has `uplinks`, a named set of internet connections ordered by distance:

```nix
routeros.uplinks = {
  fiber = {
    kind = "ethernet";
    distance = 1;
    check.host = "1.0.0.1";
  };
  backup = {
    kind = "lte";
    distance = 2;
    check.host = "9.9.9.9";
    lte.apn = "internet";
  };
};
```

Each uplink gets a default route with `check_gateway=ping` towards its `check.host`, and that host is reachable only through that uplink via a `/32` route. The lowest-distance uplink whose check passes carries traffic; when it fails, the next one takes over. The kinds are `ethernet`, `lte`, `pppoe`, and `wifi-station`, which turns one radio into a Wi-Fi client. My own router uses that one, since its internet arrives over Wi-Fi.

### Checks that fail evaluation, not the router

This is the part I'm happiest with. terranix has no `assertions`, so v2 collects its own internal list of checks and forces them during evaluation. A violated check aborts `nix build` with a message that names the option:

```text
routeros.lan.leases.nas: 10.0.0.120 is inside the DHCP pool 10.0.0.100-10.0.0.250
routeros.uplinks fiber, backup share distance 1; equal distances balance traffic
  across them (ECMP) instead of failing over, so give each a distinct distance
routeros.lan.ports includes uplink interfaces ether1; bridging them joins the WAN to the LAN
```

Every one of these is a mistake I either made or nearly made. In v1 they would have reached the router, and some of them would have cut off the session I was applying from. Other checks cover leases outside the subnet or on the router's own address, duplicate MACs, an LTE uplink on a device without USB, and two names that would render to the same Terraform resource key and silently overwrite each other.

The library also has a real test suite now: about 1,500 lines of evaluation tests, including negative tests that assert each check's exact message. `just validate` runs `tofu validate` on the rendered config for every device profile.

### Adopting a live router

v1 assumed you started from a factory reset. That doesn't work when the router you're configuring is the one your laptop is connected through. v2 documents a first apply: reset with no defaults, create the bridge, your port, the LAN address, and an API user by hand, then adopt them with Terraform `import` blocks. After that, the provider manages them like everything else.

## My router on den

With the library this small, the interesting part of my setup moved into nix-config. The [router stack](https://github.com/aleks-sidorenko/nix-config/blob/master/modules/infra/router.nix) pins the library and includes it like any other aspect:

```nix
flake-file.inputs.nix-routeros = {
  url = "github:aleks-sidorenko/nix-routeros/v2.0.0";
  inputs.nixpkgs.follows = "nixpkgs";
  inputs.terranix.follows = "terranix";
};
```

The single source of truth for hosts moved up a level. A host now declares its own place on the LAN:

```nix
den.hosts.x86_64-linux.server = {
  deploy = { };
  lan = {
    address = "10.0.0.10";
    mac = "80:30:49:13:75:41";
  };
};
```

A host-wide `system.lan` aspect turns that into a `lan-leases` value, and a den policy collects it from every *deployed* host into the router stack. The router aspect maps the collected list straight onto the library's option:

```nix
lan.leases = lib.listToAttrs (
  map (l: lib.nameValuePair l.name { inherit (l) address mac; }) lan-leases
);
```

Add a host with a `lan` block, and the router gives it a static lease and a `<host>.lan` DNS record. A VM that shares the server's config but isn't deployed doesn't claim its address. An eval test checks that only `server` gets a lease.

The same trick works for DNS. Hosts publish the names they serve (`published-names`). The public DNS stack points them at each host's tailnet address, and the router points the same names at the LAN address, so I get split-horizon DNS without keeping two lists. If a host publishes a name but has no LAN address, evaluation fails instead of creating a record that points nowhere.

The Wi-Fi works the same way. The SSID is a setting shared by the router's access point and the server's NetworkManager profile, and an eval test asserts they're equal:

```nix
sameSsid =
  profiles.home-wifi.wifi.ssid
  == config.infraStacks.router.config.resource.routeros_wifi_configuration.home.ssid;
```

None of this is in nix-routeros, and that's the point. The library knows how to configure a MikroTik. My config knows which machines I own. v1 mixed the two. v2 keeps them apart.

## Migrating from v1

If you're on v1, it stays available at tag `v1.0.0`. The main renames:

| v1 | v2 |
| --- | --- |
| `connection.gateway` | `connection.address` |
| `network.subnet` | `lan.address` (CIDR) |
| `network.dhcp.server.range` | `lan.dhcp.pool` |
| `hosts` | `lan.leases` + `dns.localDomain` |
| `dns.aliases` | `dns.records` |
| `bridge.ports` | `lan.ports` |
| `interfaces.wan`, `interfaces.lte` | `uplinks.<name>` |
| `wifi.*` (CAPsMAN) | `wifi.networks.<name>`, `wifi.country` |
| `mkRouterDerivation` | terranix `flakeModule` |
| `presets.router`, `secrets` | removed |

Resource keys changed too, so expect the first v2 plan against existing state to replace some resources. Read it before you apply.

## What changed

v1 tried to be the whole toolchain: modules, presets, secrets, state, and scripts. That made a standalone repo pleasant, but it got in the way once the router became one stack among several. v2 does less. It turns `routeros.*` options into Terraform JSON, refuses configs it knows are broken, and leaves running, secrets, and site facts to you.

That's the same lesson den taught me about my machines: keep each piece small and let composition do the rest.
