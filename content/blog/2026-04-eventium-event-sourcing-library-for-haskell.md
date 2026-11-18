+++
title = "Event Sourcing in Haskell with Eventium"
date = 2026-04-07
description = "A walkthrough of eventium, a typed and composable event-sourcing library for Haskell, building a small banking system step by step."
path = "blog/2026/04/eventium-event-sourcing-library-for-haskell"
[taxonomies]
tags = ["haskell", "functional-programming", "event-sourcing"]
categories = ["programming"]
+++

I've been building a Haskell library called [eventium](https://github.com/aleks-sidorenko/eventium), a typed, composable event-sourcing and CQRS library. It started as a fork of the abandoned `eventful` project, which I modernized for GHC 9.10+ and reshaped around a cleaner set of abstractions.

Event sourcing sounds straightforward until you try to implement it properly. State is derived from a sequence of events instead of being stored directly. That constraint forces clarity, but it also raises a lot of questions about how projections, commands, and aggregates should fit together.

This post walks through building a small banking system using `eventium` [v0.2.1](https://github.com/aleks-sidorenko/eventium/tree/v0.2.1), covering each abstraction as we need it.

<!-- more -->

## Event Sourcing and CQRS

The core idea is simple: instead of storing the current state of something, you store the sequence of things that happened to it. Current state is never saved. You always derive it by replaying those events from the beginning. That derivation is called a projection, and it's just a fold: start with an initial state, apply each event in order, and arrive at where you are now. If you want a different view of the same data, you write a different fold.

Commands are the other half. Before anything gets persisted, a command handler validates the intent against the current projected state and decides whether to accept or reject it. If the command is valid, the handler produces new events instead of mutating anything directly. Commands can fail, events cannot. Once an event is in the log, it happened.

CQRS builds on this by splitting the write and read sides entirely. The write side lives in aggregates, units of consistency that process commands and emit events. The read side is a set of projections tuned for whatever queries you actually need. The two sides can evolve independently, and you can rebuild the read models at any time from the event log.

For workflows that span multiple aggregates, like "open an account, then fund it, then notify another service", there are process managers. They listen to events from one aggregate and issue commands to others, coordinating multi-step flows without coupling the aggregates directly.

That's the conceptual skeleton. The rest of the post builds a bank on top of it.

## The Domain: A Banking System

We're modeling bank accounts that can be opened, credited, debited, and transfer money between each other. Nothing unusual, but rich enough that real patterns emerge.

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

There are others (`AccountCredited`, `AccountTransferCompleted`, `AccountTransferFailed`, `AccountCreditedFromTransfer`), but they follow the same shape: one record per thing that can happen.

Aggregates and process managers need to work with a closed set of events, so we need sum types. Eventium provides Template Haskell utilities to generate them. At the aggregate level:

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

Sum types fit events well: each constructor is one thing that happened, and the compiler makes sure you handle every case. The TH utilities just save you from writing them by hand. You'll see the `BankEvent` constructors (like `AccountTransferStartedEvent`) later, when we get to process managers.

Commands describe intent. Here's one:

```haskell
data TransferToAccount = TransferToAccount
  { transferId :: UUID
  , amount :: Double
  , targetAccount :: UUID
  }
```

The rest (`OpenAccount`, `CreditAccount`, `DebitAccount`, `AcceptTransfer`, `CompleteTransfer`, `RejectTransfer`) are just as simple.

The aggregate state tracks what we need for validation:

```haskell
data Account = Account
  { balance :: Double
  , owner :: Maybe UUID
  , pendingTransfers :: [PendingAccountTransfer]
  }
```

The `Maybe UUID` for `owner` does double duty: besides holding the owner, `Nothing` means the account hasn't been opened yet. Simple, but it works.

And the error type for when commands are rejected:

```haskell
data AccountCommandError
  = AccountAlreadyOpen
  | InvalidInitialDeposit
  | InsufficientFunds Double
  | AccountNotOpen
```

There's also a `Customer` aggregate alongside `Account`, and we'll see how the two compose later. For now, let's look at how these pieces wire together.

## Projections: Rebuilding State from Events

The central abstraction for state reconstruction is `Projection`:

```haskell
data Projection state event = Projection
  { seed :: state
  , eventHandler :: state -> event -> state
  }
```

`seed` is the initial state before any events have been applied. `eventHandler` takes the current state and one event, and returns the next state. So a `Projection` is just a fold specification, packaged as a first-class value.

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

Each case answers "what does this event mean for the state" directly. Debits subtract, credits add, and opening an account sets the owner and seeds the balance. The transfer cases are a bit more involved (they push to and pop from `pendingTransfers`), but the pattern is the same. Then we wire it together:

```haskell
accountProjection :: Projection Account AccountEvent
accountProjection = Projection accountDefault handleAccountEvent
```

To reconstruct state from a sequence of events, `eventium` provides `latestProjection`:

```haskell
latestProjection :: (Foldable t) => Projection state event -> t event -> state
```

Give it a projection and any `Foldable` of events (a list, a sequence, whatever you have) and you get the current state back. There's no IO and no database round-trip, just a fold. That makes projections easy to test: you can unit test your whole state reconstruction logic by passing in a list of events and checking the result, with no test database, no mocking, and no setup.

`Projection` also has a `Contravariant` instance on the event type. This helps when two event types are isomorphic, for example when you're adapting a projection written for one sum type to work with another: you `contramap` over the event side to adapt the handler. For composing projections across multiple aggregates, `eventium` uses a different mechanism called `TypeEmbedding`, which we'll get to when we look at process managers.

## Command Handlers: Validating Intent

A projection tells you how to reconstruct state. A command handler tells you what to do with it. The type that ties the two together is `CommandHandler`:

```haskell
data CommandHandler state event command err = CommandHandler
  { decide :: state -> command -> Either err [event]
  , projection :: Projection state event
  }
```

All the domain logic lives in `decide`. It's a pure function: current state and an incoming command go in, and either a rejection error or a list of new events comes out. The handler bundles `decide` with a `Projection` so it knows how to rebuild state before making that call, and that's all it needs.

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

Opening an account checks whether one is already open, then validates the initial deposit. Starting a transfer checks that the account exists and that the available balance, after accounting for any in-flight transfers, covers the amount. I've left out the `{ ... }` record fields to keep the focus on validation instead of plumbing. The pattern is the same throughout: inspect state, then reject with a typed error or return a list of events.

Wiring it up is one line:

```haskell
accountCommandHandler :: CommandHandler Account AccountEvent AccountCommand AccountCommandError
accountCommandHandler = CommandHandler handleAccountCommand accountProjection
```

To run a command against a stream, `eventium` provides `applyCommandHandler`. It loads the latest projected state from the event store, calls `decide`, and writes the resulting events back, using `ExactPosition` (a variant of `ExpectedPosition`) for optimistic concurrency. If another write landed on the same stream between the read and the write, the store rejects it, and the conflict comes back as a typed `CommandHandlerError` instead of an exception.

Because `decide` is pure, you can test all the domain logic without any IO: pass in a state and a command, then check the `Either`. You don't mock stores or start databases. Optimistic concurrency means you never hold a lock while running business logic; conflicts are detected on write and returned as values. And the `err` type parameter keeps concerns separate at the type level: `InsufficientFunds` and `AccountNotOpen` live in `AccountCommandError`, while concurrency conflicts live in `CommandHandlerError`, and the compiler makes sure you handle each one.

## Process Managers: Coordinating Transfers

Everything so far happens within a single aggregate: one stream of events, one command handler, one projection, all scoped to a single account. But a bank transfer debits one account and credits another. Those are two separate aggregates, each with its own stream and its own consistency boundary, so you can't just touch both in the same command handler. Coordinating them is the job of process managers.

A process manager watches events from across the system and reacts by issuing commands. Here's the type:

```haskell
data ProcessManager state event command = ProcessManager
  { projection :: Projection state (VersionedStreamEvent event)
  , react :: state -> VersionedStreamEvent event -> [ProcessManagerEffect command]
  }
```

The projection tracks whatever state the process manager needs for its decisions, in our case which transfers are in flight. `react` takes the current state and a new event, and returns a list of effects. It's a pure function: no monadic IO, no database calls, just state and event in, effects out.

The effects are the clever part:

```haskell
data ProcessManagerEffect command
  = IssueCommand UUID command
  | IssueCommandWithCompensation UUID command
      (RejectionReason -> [ProcessManagerEffect command])
```

`IssueCommand` is simple: send this command to this aggregate. `IssueCommandWithCompensation` also carries a function that says what to do if the command gets rejected. The compensation logic sits right there in the type, instead of in a separate rollback service you have to wire up and hope stays in sync.

Here's the core of the transfer process manager's `react` function:

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

When the process manager sees a transfer start, it issues `AcceptTransfer` to the target account. If that command fails (maybe the target account is closed), the compensation function fires and issues `RejectTransfer` back on the source account. The whole decision tree is in one expression.

The full transfer flow runs in four steps:

1. `TransferToAccount` command on the source account emits `AccountTransferStarted`
2. The process manager reacts by issuing `AcceptTransfer` on the target account, with compensation attached
3. **Success:** target emits `AccountCreditedFromTransfer`, process manager reacts with `CompleteTransfer` on the source
4. **Failure:** compensation fires, issuing `RejectTransfer` on the source account

To execute these effects, `eventium` provides `runProcessManagerEffects`, which walks the effect list and dispatches each command through a `CommandDispatcher`. If a command with compensation gets rejected, it evaluates the compensation function and continues with the resulting effects.

Compared to most event-sourcing libraries I've seen, two things are different here. First, `react` returns plain data instead of running in a monad. Most ES frameworks implement sagas or process managers as effectful state machines: you're in IO from the start, and testing means mocking most of the system. Here the whole saga decision tree is a pure function, and you unit test it by passing in a state and an event and checking the returned effects.

Second, compensation is data, not a service. The failure handler is part of the `ProcessManagerEffect` value you return from `react`. There's no separate "compensation service" to register, no rollback handler to wire up, and no hoping that the right callback is connected to the right failure case. The compiler sees all of it.

## Read Models: Queryable Views

Everything so far is the write side: command handlers produce events, and projections reconstruct aggregate state. But what if you want to query across aggregates? "Show me all pending transfers" doesn't belong to any single account. There's no single event stream to fold over, and the aggregate projection only knows about its own events. For this you need a read model.

Read models in `eventium` are first-class values with their own type:

```haskell
data ReadModel m event = ReadModel
  { initialize :: m ()
  , eventHandler :: EventHandler m (GlobalStreamEvent event)
  , checkpointStore :: CheckpointStore m SequenceNumber
  , reset :: m ()
  }
```

The type is parametric over the monad `m`, so it doesn't care about the backend. The bank example uses SQL, but nothing in the type forces that choice. You could back a read model with Redis, an in-memory `TVar`, or anything else that fits `m`.

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

`initialize` runs the database migrations on startup, so the transfers table exists before anything tries to write to it. `eventHandler` processes events from the global stream and updates the read model, in this case by inserting and updating rows in the transfers table. `checkpointStore` tracks the last sequence number processed successfully, so after a restart the model picks up where it left off instead of replaying from the beginning. `reset` clears the table entirely, which matters for rebuilds.

Three operations drive read models:

- `runReadModel` runs forever, polling the global event stream at a configurable interval and feeding new events to the handler. This is normal operation.
- `rebuildReadModel` calls `reset`, then replays all events from sequence number zero. It runs once, and it's what you use after changing the projection logic to regenerate the view.
- `combineReadModels` fans out from a single global stream subscription to multiple read models. You subscribe once and let `eventium` dispatch to all of them, instead of subscribing once per read model.

Most event-sourcing libraries leave this infrastructure to the user: you're on your own for checkpointing, initialization, and deciding how to handle rebuilds. `eventium` puts all of it in the `ReadModel` type, so checkpointing, initialization, reset, and composition work the same way for every read model in your system.

## Putting It All Together

We have all the pieces now: projections, command handlers, process managers, read models. What's left is the wiring. Eventium does it with a few mechanisms that let you connect everything without losing type safety.

**TypeEmbedding** is how you compose across aggregates. We have `AccountEvent` and `AccountCommand` at the aggregate level, but the application works with `BankEvent` and `BankCommand`. The Template Haskell utilities generate the embedding:

```haskell
mkSumTypeEmbedding "accountEventEmbedding" ''AccountEvent ''BankEvent
mkSumTypeEmbedding "accountCommandEmbedding" ''AccountCommand ''BankCommand

accountBankCommandHandler :: CommandHandler Account BankEvent BankCommand AccountCommandError
accountBankCommandHandler =
  embeddedCommandHandler accountEventEmbedding accountCommandEmbedding accountCommandHandler
```

`embeddedCommandHandler` lifts an aggregate-specific handler to work with the application-wide types. Events and commands that don't belong to this aggregate are skipped, with no exceptions and no partial matches. The account handler ignores customer events and returns `Right []` for customer commands. That's what makes composition safe: each handler only sees what it understands.

**Command dispatching** follows from this. `commandHandlerDispatcher` routes application-wide commands to the right aggregate handler. Since each embedded handler returns `Right []` for commands that aren't its own, the dispatcher just tries each handler in sequence (account handler, customer handler) and collects the results. There's no routing table and no command-to-handler mapping to maintain.

**Event publishing** connects the write side to everything downstream. `publishingEventStoreWriter` wraps a store writer so that it dispatches events to process managers and read models after each successful write. You create a publisher from an `EventHandler` using `synchronousPublisher`, and the store writer does the rest. When a command handler writes events, the transfer process manager and the read models all see them without any manual plumbing.

**Backend swapping** is where the polymorphic monad design pays off. The core store abstractions, `EventStoreWriter` and `EventStoreReader`, are parametric over key, position, monad, and event type. The same domain code (command handlers, projections, process managers) works with in-memory STM stores, SQLite, or PostgreSQL. You pick the store constructor at the application boundary: the STM variants in tests, SQL in production. The backend is a deployment decision, not an architectural one.

**Codecs** handle the serialization boundary. The bank example uses `deriveJSON` for the wire format, which gives simple Aeson instances for each event type. If you'd rather avoid Template Haskell, eventium also provides a `Generic`-based alternative via `EventSumType` and `eventSumTypeCodec`. And `lenientCodecProjection` skips unrecognized events instead of failing, which gives you forward compatibility: you can add new event types to a stream without breaking existing consumers that haven't been updated to handle them yet.

Every layer follows the same idea: small, focused pieces that compose cleanly. A projection is a fold. A command handler is a pure function plus a projection. A process manager is a pure function that returns effects. The wiring layer (embeddings, dispatchers, publishers) connects them without any of the pieces needing to know about each other.

## Wrapping Up

One more word on testing. Because `decide` and `react` are pure functions, you can test all your domain and saga logic without any infrastructure. Add the in-memory STM backend and you get fast, deterministic tests for the full write path, with no database, no mocking, and no test containers.

The library has more that I didn't cover here: `ProjectionCache` for snapshotting aggregate state (so you don't replay all events on every command), and `EventSubscription` with resilient polling and retry for production read models that need to survive temporary failures.

The three backends (memory via STM, SQLite, and PostgreSQL) all expose the same interfaces, and swapping is a single constructor call at the application boundary.

The full bank example is [on GitHub](https://github.com/aleks-sidorenko/eventium/tree/v0.2.1/examples/bank) if you want to see everything wired together. The library itself lives at [aleks-sidorenko/eventium](https://github.com/aleks-sidorenko/eventium). If you're building anything event-sourced in Haskell, give it a try. Feedback is welcome.
