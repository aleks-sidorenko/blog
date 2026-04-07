+++
title = "Event Sourcing in Haskell with Eventium"
date = 2026-04-07
description = "A walkthrough of eventium, a typed and composable event-sourcing library for Haskell — building a banking system step by step."
path = "blog/2026/04/eventium"
[taxonomies]
tags = ["haskell", "functional-programming", "event-sourcing"]
categories = ["programming"]
+++

I've been building a Haskell library called [eventium](https://github.com/aleks-sidorenko/eventium) — a typed, composable event-sourcing and CQRS library. It started as a fork of the abandoned `eventful` project, modernized for GHC 9.10+ and reshaped around a cleaner set of abstractions.

Event sourcing is one of those ideas that sounds straightforward until you try to implement it properly. State is derived from a sequence of events, not stored directly. That constraint forces clarity — but it also raises a lot of questions about how projections, commands, and aggregates should fit together.

This post walks through building a small banking system using eventium [v0.2.1](https://github.com/aleks-sidorenko/eventium/tree/v0.2.1), covering each abstraction as we need it.

<!-- more -->
