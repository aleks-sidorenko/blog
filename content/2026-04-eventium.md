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

## Event Sourcing and CQRS

The core idea is deceptively simple: instead of storing the current state of something, you store the sequence of things that happened to it. Current state is never saved — it's always derived by replaying those events from the beginning. That derivation is called a projection, and it's just a fold: start with an initial state, apply each event in order, and arrive at where you are now. If you want a different view of the same data, you write a different fold.

Commands are the other half. Before anything gets persisted, a command handler validates the intent against the current projected state and decides whether to accept or reject it. If it's valid, the handler produces new events — it doesn't mutate anything directly. This separation matters: commands can fail, events cannot. Once an event is in the log, it happened.

CQRS builds on this by splitting the write and read sides entirely. The write side lives in aggregates — units of consistency that process commands and emit events. The read side is a set of projections optimized for whatever queries you actually need. These two sides can evolve independently, and the read models can be rebuilt at any time from the event log.

For workflows that span multiple aggregates — things like "open an account, then fund it, then notify a downstream service" — there are process managers. They listen to events from one aggregate and issue commands to others, coordinating multi-step flows without coupling the aggregates directly.

That's the conceptual skeleton. Let's see how this looks in practice by building a bank.

## The Domain: A Banking System

We're modeling bank accounts that can be opened, credited, debited, and transfer money between each other. Nothing exotic — but rich enough that real patterns emerge.

Events come first. Each one is a plain record describing something that happened:

```haskell
data AccountOpened = AccountOpened
  { owner :: UUID
  , initialFunding :: Double
  }

data AccountDebited = AccountDebited
  { amount :: Double
  , reason :: String
  }

data AccountTransferStarted = AccountTransferStarted
  { transferId :: UUID
  , amount :: Double
  , targetAccount :: UUID
  }
```

There are others — `AccountCredited`, `AccountTransferCompleted`, `AccountTransferFailed`, `AccountCreditedFromTransfer` — but they follow the same shape. One record per thing that can happen.

Now, aggregates and process managers need to work with a closed set of events, so we need sum types. Eventium provides Template Haskell utilities for generating them. At the aggregate level:

```haskell
constructSumType "AccountEvent"
  (withTagOptions AppendTypeNameToTags defaultSumTypeOptions)
  accountEvents
-- Generates: AccountOpenedAccountEvent AccountOpened
--          | AccountCreditedAccountEvent AccountCredited
--          | ...
```

And at the application level, where events from multiple aggregates are combined:

```haskell
constructSumType "BankEvent"
  (withTagOptions (ConstructTagName (++ "Event")) defaultSumTypeOptions)
  (accountEvents ++ customerEvents)
-- Generates: AccountOpenedEvent AccountOpened
--          | ...
```

Sum types are a natural fit for events — each constructor represents one thing that happened, and the compiler ensures you handle every case. The TH utilities just reduce the boilerplate of writing these by hand. You'll see the `BankEvent` constructors (like `AccountTransferStartedEvent`) later when we get to process managers.

Commands describe intent. Here's one:

```haskell
data TransferToAccount = TransferToAccount
  { transferId :: UUID
  , amount :: Double
  , targetAccount :: UUID
  }
```

The rest — `OpenAccount`, `CreditAccount`, `DebitAccount`, `AcceptTransfer`, `CompleteTransfer`, `RejectTransfer` — are similarly straightforward.

The aggregate state tracks what we need for validation:

```haskell
data Account = Account
  { balance :: Double
  , owner :: Maybe UUID
  , pendingTransfers :: [PendingAccountTransfer]
  }
```

The `Maybe UUID` for `owner` is doing double duty — `Nothing` means the account hasn't been opened yet. Simple, but it works.

And the error type for when commands are rejected:

```haskell
data AccountCommandError
  = AccountAlreadyOpen
  | InvalidInitialDeposit
  | InsufficientFunds Double
  | AccountNotOpen
```

There's also a `Customer` aggregate alongside `Account` — we'll see how they compose later. For now, let's focus on how these pieces wire together.
