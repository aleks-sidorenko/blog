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

## Projections: Rebuilding State from Events

The central abstraction for state reconstruction is `Projection`:

```haskell
data Projection state event = Projection
  { seed :: state
  , eventHandler :: state -> event -> state
  }
```

`seed` is the initial state before any events have been applied. `eventHandler` takes the current state and one event, and returns the next state. That's it — a `Projection` is just a fold specification, packaged up as a first-class value.

For the banking domain, the event handler for `Account` looks like this:

```haskell
handleAccountEvent :: Account -> AccountEvent -> Account
handleAccountEvent account (AccountOpenedAccountEvent evt) =
  account { owner = Just evt.owner, balance = evt.initialFunding }
handleAccountEvent account (AccountCreditedAccountEvent evt) =
  account { balance = account.balance + evt.amount }
handleAccountEvent account (AccountDebitedAccountEvent evt) =
  account { balance = account.balance - evt.amount }
-- ... transfer events update pendingTransfers
```

Each case is a direct translation of "what does this event mean for the state". Debits subtract, credits add, opening an account sets the owner and seeds the balance. The transfer cases are a bit more involved — they push to and pop from `pendingTransfers` — but the pattern is the same. Then we wire it together:

```haskell
accountProjection :: Projection Account AccountEvent
accountProjection = Projection accountDefault handleAccountEvent
```

To actually reconstruct state from a sequence of events, eventium provides `latestProjection`:

```haskell
latestProjection :: (Foldable t) => Projection state event -> t event -> state
```

Give it a projection and any `Foldable` of events — a list, a sequence, whatever you have — and you get the current state back. No IO, no database round-trip, just a fold. This makes projections trivially testable: you can unit test your entire state reconstruction logic by passing in a list of events and asserting on the result. No test database needed, no mocking, no setup overhead.

One other thing worth mentioning: `Projection` has a `Contravariant` instance on the event type. This is useful when you have two event types that are isomorphic — say, you're adapting a projection written for one sum type to work with another. You `contramap` over the event side to adapt the handler. For composing projections across multiple aggregates, eventium uses a different mechanism called `TypeEmbedding`, which we'll get to when we look at process managers.

## Command Handlers: Validating Intent

A projection tells you how to reconstruct state. A command handler tells you what to do with it. The type that ties the two together is `CommandHandler`:

```haskell
data CommandHandler state event command err = CommandHandler
  { decide :: state -> command -> Either err [event]
  , projection :: Projection state event
  }
```

`decide` is where all the domain logic lives. It's a pure function — current state and an incoming command go in, either a rejection error or a list of new events comes out. The handler bundles `decide` with a `Projection` so it knows how to rebuild state before making that call. Nothing else is needed.

For the banking domain, the interesting cases in `handleAccountCommand` are the ones with real validation to do:

```haskell
handleAccountCommand :: Account -> AccountCommand -> Either AccountCommandError [AccountEvent]
handleAccountCommand account (OpenAccountAccountCommand cmd) =
  case account.owner of
    Just _ -> Left AccountAlreadyOpen
    Nothing ->
      if cmd.initialFunding < 0
        then Left InvalidInitialDeposit
        else Right [AccountOpenedAccountEvent AccountOpened { ... }]
handleAccountCommand account (TransferToAccountAccountCommand cmd)
  | isNothing account.owner = Left AccountNotOpen
  | accountAvailableBalance account - cmd.amount < 0 =
      Left $ InsufficientFunds $ accountAvailableBalance account
  | otherwise = Right [AccountTransferStartedAccountEvent AccountTransferStarted { ... }]
```

Opening an account checks whether one is already open, then validates the initial deposit. Initiating a transfer checks that the account exists and that the available balance — after accounting for any in-flight transfers — covers the amount. The `{ ... }` record fields are elided here to keep the focus on validation logic rather than plumbing. The pattern is the same throughout: inspect state, reject with a typed error or return a list of events.

Wiring it up is one line:

```haskell
accountCommandHandler :: CommandHandler Account AccountEvent AccountCommand AccountCommandError
accountCommandHandler = CommandHandler handleAccountCommand accountProjection
```

To actually run a command against a stream, eventium provides `applyCommandHandler`. It loads the latest projected state from the event store, calls `decide`, and writes the resulting events back — using `ExpectedPosition` to implement optimistic concurrency. If another write landed on the same stream between the read and the write, the store rejects it. That conflict surfaces as a typed `CommandHandlerError`, not an exception.

A few things stand out about this design. `decide` being pure means the entire domain logic is testable without any IO — pass in a state and a command, assert on the `Either`. No mocking stores or spinning up databases. Optimistic concurrency means you never hold a lock while running business logic; conflicts are detected on write and returned as values. And the `err` type parameter keeps concerns separate at the type level: `InsufficientFunds` and `AccountNotOpen` live in `AccountCommandError`, while concurrency conflicts live in `CommandHandlerError`. The compiler makes sure you handle each appropriately.
