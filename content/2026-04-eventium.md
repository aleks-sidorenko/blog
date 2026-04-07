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

## Process Managers: Coordinating Transfers

Everything so far happens within a single aggregate. One stream of events, one command handler, one projection — all scoped to a single account. But a bank transfer debits one account and credits another. Those are two separate aggregates, each with their own stream and their own consistency boundary. You can't just reach into both in the same command handler. They need to be coordinated, and that's where process managers come in.

A process manager watches events from across the system and reacts by issuing commands. Here's the type:

```haskell
data ProcessManager state event command = ProcessManager
  { projection :: Projection state (VersionedStreamEvent event)
  , react :: state -> VersionedStreamEvent event -> [ProcessManagerEffect command]
  }
```

The projection tracks whatever state the process manager needs to make decisions — in our case, which transfers are in flight. The interesting part is `react`: it takes the current state and a new event, and returns a list of effects. It's a pure function. No monadic IO, no database calls, just state and event in, effects out.

Those effects are where things get clever:

```haskell
data ProcessManagerEffect command
  = IssueCommand UUID command
  | IssueCommandWithCompensation UUID command
      (RejectionReason -> [ProcessManagerEffect command])
```

`IssueCommand` is straightforward — send this command to this aggregate. But `IssueCommandWithCompensation` carries a function: if the command gets rejected, here's what to do about it. The compensation logic is encoded right there in the type, not in some separate rollback service you have to wire up and hope stays in sync.

Here's the key excerpt from the transfer process manager's `react` function:

```haskell
reactTransfer manager (StreamEvent sourceAcct _ _ (AccountTransferStartedEvent evt))
  | isNothing (Map.lookup evt.transferId manager.transferData) =
      [ IssueCommandWithCompensation
          evt.targetAccount
          (AcceptTransferCommand AcceptTransfer { ... })
          (\(RejectionReason reason) ->
              [ IssueCommand sourceAcct
                  (RejectTransferCommand RejectTransfer { ... })
              ])
      ]
```

When the process manager sees a transfer started, it issues `AcceptTransfer` to the target account. If that command fails — maybe the target account is closed — the compensation function fires and issues `RejectTransfer` back on the source account. The entire decision tree is right there in one expression.

The full transfer flow plays out in four steps:

1. `TransferToAccount` command on the source account emits `AccountTransferStarted`
2. The process manager reacts by issuing `AcceptTransfer` on the target account, with compensation attached
3. **Success:** target emits `AccountCreditedFromTransfer`, process manager reacts with `CompleteTransfer` on the source
4. **Failure:** compensation fires, issuing `RejectTransfer` on the source account

To actually execute these effects, eventium provides `runProcessManagerEffects`, which walks the effect list and dispatches each command via a `CommandDispatcher`. If a command with compensation gets rejected, it evaluates the compensation function and continues with the resulting effects.

Two things make this design stand out compared to most event-sourcing libraries I've seen. First, `react` is pure data, not monadic. Most ES frameworks implement sagas or process managers as effectful state machines — you're in IO from the start, and testing means mocking half the world. Here, the entire saga decision tree is a pure function you can unit test by passing in a state and an event and asserting on the returned effects. No IO, no mocking.

Second, compensation is data, not a service. The failure handler lives right there in the `ProcessManagerEffect` type — it's part of the value you return from `react`. There's no separate "compensation service" to register, no rollback handler to wire up, no hope that the right callback is connected to the right failure mode. The compiler sees it all.

## Read Models: Queryable Views

Everything so far is the write side — command handlers produce events, projections reconstruct aggregate state. But what if you want to query across aggregates? "Show me all pending transfers" doesn't belong to any single account. There's no single event stream to fold over, and the aggregate projection only knows about its own events. You need a different mechanism: a read model.

Read models in eventium are first-class values with their own type:

```haskell
data ReadModel m event = ReadModel
  { initialize :: m ()
  , eventHandler :: EventHandler m (GlobalStreamEvent event)
  , checkpointStore :: CheckpointStore m SequenceNumber
  , reset :: m ()
  }
```

The type is parametric over the monad `m` — it's backend-agnostic by design. The bank example uses SQL, but nothing in the type forces that choice. You could back a read model with Redis, an in-memory `TVar`, or anything else that fits `m`.

Here's the actual transfers read model from the bank example:

```haskell
transferReadModel :: ReadModel (SqlPersistT IO) BankEvent
transferReadModel = ReadModel
  { initialize = void $ runMigrationSilent migrateTransfer
  , eventHandler = EventHandler handleTransferEvent
  , checkpointStore = sqliteCheckpointStore (CheckpointName "transfers")
  , reset = deleteWhere ([] :: [Filter TransferEntity])
  }
```

Each field has a clear job. `initialize` runs the database migrations on startup, ensuring the transfers table exists before anything tries to write to it. `eventHandler` processes events arriving from the global stream and updates the read model accordingly — in this case, inserting and updating rows in the transfers table. `checkpointStore` tracks the last sequence number successfully processed, so on restart the model picks up where it left off rather than replaying from the beginning. `reset` wipes the table entirely, which matters for the rebuild case.

The three operations that drive read models:

- `runReadModel` — runs forever, polling the global event stream at a configurable interval and feeding new events to the handler. This is the steady-state operation.
- `rebuildReadModel` — calls `reset`, then replays all events from sequence number zero. One-shot, useful when you've changed the projection logic and need to regenerate the view.
- `combineReadModels` — fans out from a single global stream subscription to multiple read models. Rather than subscribing once per read model, you subscribe once and let eventium dispatch to all of them.

Most event-sourcing libraries leave this infrastructure to the user — you're on your own for checkpointing, for wiring up initialization, for deciding how to handle rebuilds. Eventium encodes all of it directly in the `ReadModel` type. Checkpointing, initialization, reset, and composition are built in and consistent across every read model in your system.

## Putting It All Together

We've built all the individual pieces — projections, command handlers, process managers, read models. Now comes the wiring. Eventium's composition story is built around a few key mechanisms that let you snap everything together without losing type safety.

**TypeEmbedding** is how you compose across aggregates. We have `AccountEvent` and `AccountCommand` at the aggregate level, but the application works with `BankEvent` and `BankCommand`. The Template Haskell utilities generate the embedding:

```haskell
mkSumTypeEmbedding "accountEventEmbedding" ''AccountEvent ''BankEvent
mkSumTypeEmbedding "accountCommandEmbedding" ''AccountCommand ''BankCommand

accountBankCommandHandler :: CommandHandler Account BankEvent BankCommand AccountCommandError
accountBankCommandHandler =
  embeddedCommandHandler accountEventEmbedding accountCommandEmbedding accountCommandHandler
```

`embeddedCommandHandler` lifts an aggregate-specific handler to work with the application-wide types. Events and commands that don't belong to this aggregate are silently skipped — no exceptions, no partial matches. The account handler simply ignores customer events and returns `Right []` for customer commands. This is what makes composition safe: each handler only sees what it understands.

**Command dispatching** follows naturally. `commandHandlerDispatcher` routes application-wide commands to the right aggregate handler. Since each embedded handler returns `Right []` for non-matching commands, the dispatcher just tries each handler in sequence — account handler, customer handler — and collects the results. No routing table, no command-to-handler mapping to maintain.

**Event publishing** closes the loop between the write side and everything downstream. `publishingEventStoreWriter` wraps a store writer to auto-dispatch events to process managers and read models after successful writes. You create a publisher from an `EventHandler` using `synchronousPublisher`, and the store writer takes care of the rest. When a command handler writes events, the transfer process manager and the read models all see them without any manual plumbing.

**Backend swapping** is where the polymorphic monad design pays off. The same domain code — command handlers, projections, process managers — works with in-memory STM stores, SQLite, or PostgreSQL. You pick the store constructor at the application boundary. In tests, you use `stmEventStoreWriter` and `stmStreamProjectionStore`. In production, swap in the SQL variants. The backend is a deployment decision, not an architectural one.

**Codecs** handle the serialization boundary. The bank example uses `deriveJSON` for the wire format — straightforward Aeson instances for each event type. But eventium also provides `lenientCodecProjection`, which skips unrecognized events instead of failing. This enables forward compatibility: you can add new event types to a stream without breaking existing consumers that haven't been updated to handle them yet.

The theme across all of these is the same one we've seen in every layer: small, focused pieces that compose cleanly. A projection is just a fold. A command handler is a pure function plus a projection. A process manager is a pure function that returns effects. And the wiring layer — embeddings, dispatchers, publishers — snaps them together without requiring any of the pieces to know about each other. Each abstraction does one thing, and composition handles the rest.

## Wrapping Up

One thing I didn't mention: testing. Because `decide` and `react` are pure functions, your entire domain and saga logic is testable without any infrastructure. Pair that with the in-memory STM backend and you get fast, deterministic tests for the full write path — no database, no mocking, no test containers.

There's also more in the library I didn't cover here: `ProjectionCache` for snapshotting aggregate state (avoids replaying all events on every command), and `EventSubscription` with resilient polling and retry for production read models that need to survive transient failures.

The three backends — memory (STM), SQLite, and PostgreSQL — all expose the same interfaces. Swapping is a single constructor call at the application boundary.

The full bank example is [on GitHub](https://github.com/aleks-sidorenko/eventium/tree/v0.2.1/examples/bank) if you want to see everything wired together. The library itself lives at [aleks-sidorenko/eventium](https://github.com/aleks-sidorenko/eventium). If you're building anything event-sourced in Haskell, give it a try — feedback welcome.
