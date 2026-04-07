# Eventium Blog Post — Design Spec

## Overview

A blog post for sidorenko.me introducing [eventium](https://github.com/aleks-sidorenko/eventium) (v0.2.1), a Haskell event-sourcing library. The post uses the bank example to walk through each core abstraction, building up from domain events to a full CQRS system.

**Target audience:** Developers who know Haskell (intermediate+), with a brief ES/CQRS primer making the post self-contained for those new to event sourcing.

**Code depth:** Core type signatures and key usage snippets. Readers go to the repo for full code.

**Differentiators:** Woven inline as each concept is introduced — not a separate comparison section.

**Reference version:** eventium v0.2.1 ([tag](https://github.com/aleks-sidorenko/eventium/tree/v0.2.1))

---

## Post Structure

### 1. Introduction (~100 words)

Hook: "I've been building an event-sourcing library in Haskell called eventium."

- What it is: a typed, composable event-sourcing/CQRS library for Haskell
- Origin: modernized fork of `eventful`, updated for GHC 9.10+
- What the post covers: walking through building a banking system to demonstrate each abstraction
- Note: "This post is based on eventium v0.2.1" with link to tag
- Link to GitHub repo

### 2. Event Sourcing & CQRS Primer (~200 words)

No code. Concepts only:

- **Events as source of truth** — instead of storing current state, store the sequence of things that happened
- **Projections** — derive current state by folding over events
- **Command handlers** — validate intent against current state, produce new events
- **CQRS** — separate write model (aggregates handling commands) from read models (optimized query views)
- **Process managers** — coordinate workflows spanning multiple aggregates

Close with: "Let's see how this looks in practice by building a bank."

### 3. Domain Model (~350 words)

Introduce the bank domain with Haskell types.

**Presentation strategy:** Show events and commands as individual record types (as they are in the source), then explain that eventium provides Template Haskell to generate sum types (`constructSumType`) that wrap them. Note the two TH naming conventions: aggregate-level uses `AppendTypeNameToTags` (producing `AccountOpenedAccountEvent`), while application-level uses `ConstructTagName` (producing `AccountOpenedEvent` in `BankEvent`). Show simplified versions for readability but mention the actual naming so readers can follow the source.

**Show:**
- Individual event types: `AccountOpened`, `AccountCredited`, `AccountDebited`, `AccountTransferStarted`, `AccountTransferCompleted`, `AccountTransferFailed`, `AccountCreditedFromTransfer`
- Individual command types: `OpenAccount`, `CreditAccount`, `DebitAccount`, `TransferToAccount`, `AcceptTransfer`, `CompleteTransfer`, `RejectTransfer`
- `Account` state record: `balance :: Double`, `owner :: Maybe UUID` (encodes "not yet opened"), `pendingTransfers :: [PendingAccountTransfer]`
- `AccountError` — domain validation errors (insufficient funds, account not open, etc.)
- Mention the `Customer` aggregate existing alongside — this pays off in Section 8 when showing `commandHandlerDispatcher` routing commands to multiple aggregates

**Inline note:** Sum types are a natural fit for events — each constructor represents one thing that happened, the compiler ensures you handle them all. Eventium's TH utilities reduce the boilerplate of defining the sum type + codec by hand.

### 4. Projections (~300 words)

**Show:**
- `Projection` type definition:
  ```haskell
  data Projection state event = Projection
    { seed :: state
    , eventHandler :: state -> event -> state
    }
  ```
- Bank's account projection — how each event case updates state (balance adjustments, tracking pending transfers)
- `latestProjection` applying events to rebuild state

**Inline notes:**
- Projections are pure folds — no IO, trivially testable
- `Contravariant` instance allows adapting between isomorphic event types (multi-aggregate composition uses `TypeEmbedding` instead — covered in Section 8)

### 5. Command Handlers (~350 words)

**Show:**
- `CommandHandler` type:
  ```haskell
  data CommandHandler state event command err = CommandHandler
    { decide :: state -> command -> Either err [event]
    , projection :: Projection state event
    }
  ```
- Bank's `decide` function — validation logic (check balance for debits, transfer limits, account must be open)
- `applyCommandHandler` — loads projection from store, calls `decide`, writes with optimistic concurrency (`ExactPosition`)

**Inline notes:**
- `decide` is pure: state + command in, either error or events out. Entire domain logic testable without mocking stores
- Optimistic concurrency via `ExpectedPosition` — conflicts surface as typed `CommandHandlerError`, not runtime exceptions
- `err` type parameter keeps domain errors separate from infrastructure errors at the type level

### 6. Process Managers (~400 words)

Motivating problem: "A transfer debits one account and credits another. These must be coordinated."

**Show:**
- `ProcessManager` type with pure `react`:
  ```haskell
  react :: state -> VersionedStreamEvent event -> [ProcessManagerEffect command]
  ```
- `ProcessManagerEffect`:
  ```haskell
  data ProcessManagerEffect command
    = IssueCommand UUID command
    | IssueCommandWithCompensation UUID command (RejectionReason -> [ProcessManagerEffect command])
  ```
- Full four-step transfer flow:
  1. `TransferToAccount` on source account emits `AccountTransferStarted`
  2. Process manager reacts: issues `AcceptTransfer` on target account (with compensation)
  3. Success path: target emits `AccountCreditedFromTransfer`, process manager reacts with `CompleteTransfer` on source
  4. Failure path: compensation issues `RejectTransfer` on source account

**Inline notes:**
- Key differentiator: `react` is pure data, not monadic. The entire saga decision tree is testable without IO
- Compensation is encoded in the type — `IssueCommandWithCompensation` carries a function that produces further effects on failure. No separate compensation service
- `runProcessManagerEffects` executes the effect list via a `CommandDispatcher`

### 7. Read Models (~300 words)

Motivate: "Command handlers and projections give us the write side. How do we query across aggregates?"

**Show:**
- `ReadModel` type:
  ```haskell
  data ReadModel m event = ReadModel
    { initialize :: m ()
    , eventHandler :: EventHandler m (GlobalStreamEvent event)
    , checkpointStore :: CheckpointStore m SequenceNumber
    , reset :: m ()
    }
  ```
- Bank's `Transfers` read model — in this example, a SQL table tracking transfer lifecycle, built by consuming the global event stream. Note that `ReadModel` itself is backend-agnostic (parametric over monad `m`) — the SQL choice is the example's, not the abstraction's.
- `runReadModel` for long-running subscription, `rebuildReadModel` for replay, `combineReadModels` for fan-out

**Inline notes:**
- Read models are first-class in eventium — checkpointing, initialization, reset, and composition built in
- Most ES libraries leave read model infrastructure to the user

### 8. Wiring It Together (~350 words)

**Show:**
- `TypeEmbedding` — the mechanism for multi-aggregate composition. Show how `AccountEvent`/`AccountCommand` are embedded into application-wide `BankEvent`/`BankCommand` via `mkSumTypeEmbedding`, then used with `embeddedCommandHandler` and `embeddedProjection`. This is how aggregate-specific types compose into a unified application.
- `EventStoreWriter` / `EventStoreReader` — parametric over key, position, monad, event
- `EventPublisher` and `publishingEventStoreWriter` — wraps store to auto-dispatch events to process managers and read models after writes. `synchronousPublisher` creates a publisher from an `EventHandler` for in-process dispatch.
- `commandHandlerDispatcher` — routes `BankCommand` to the right aggregate handler (Account or Customer). Show how this uses `TypeEmbedding` to try each handler — non-matching commands return `Right []`, no exceptions.
- Backend swapping: same domain code with in-memory (STM), SQLite, or PostgreSQL — just different store constructors
- Brief mention of `Codec` — how events are serialized to JSON for persistence. The bank example uses TH-generated embeddings + aeson `deriveJSON` for wire format. Eventium also provides a `Generic`-based alternative via `EventSumType` / `eventSumTypeCodec`. Lenient codecs (`lenientCodecProjection`) skip unrecognized events, enabling forward compatibility.

**Inline note:** Polymorphic monad design means backend is a deployment decision, not an architectural one.

### 9. Closing (~100 words)

- Testing: pure `decide` and `react` + in-memory store = fast tests, no infrastructure
- Production features not covered in detail: `ProjectionCache` for snapshotting, `EventSubscription` with resilient polling and retry
- Available backends: memory, SQLite, PostgreSQL
- Link to repo and full bank example
- Invite readers to try it

---

## Conventions

- Front matter: TOML with title, date, description, path, taxonomies (tags + categories)
- `<!-- more -->` marker after intro paragraph
- `##` for main sections, `###` for subsections
- Haskell code blocks with ` ```haskell `
- Conversational but technical tone, first person
- Type signatures prominently featured
- ~2500-3000 words total (medium-form, matching existing posts)
- Code snippets use simplified types for readability, with a note that the actual bank example uses TH-generated sum types with longer constructor names

## File

`content/2026-04-eventium.md` with path `blog/2026/04/eventium`
