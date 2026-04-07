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

### 3. Domain Model (~300 words)

Introduce the bank domain with Haskell types:

**Show:**
- `AccountEvent` — sum type: `AccountOpened`, `AccountCredited`, `AccountDebited`, `AccountTransferStarted`, `AccountTransferCompleted`, `AccountTransferFailed`, `AccountCreditedFromTransfer`
- `AccountCommand` — sum type: `OpenAccount`, `CreditAccount`, `DebitAccount`, `StartTransfer`, `CompleteTransfer`
- `AccountState` — record: balance, owner, pending transfers
- `AccountError` — domain validation errors (insufficient funds, account not open, etc.)
- Brief mention of `Customer` aggregate existing alongside, but post focuses on `Account`

**Inline note:** Sum types are a natural fit for events — each constructor represents one thing that happened, the compiler ensures you handle them all.

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
- `Contravariant` instance allows adapting event types for multi-aggregate contexts

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
- `applyCommandHandler` — loads projection from store, calls `decide`, writes atomically

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
- Transfer flow: `AccountTransferStarted` triggers credit to target → on failure, compensate by completing transfer with failed status

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
- Bank's `Transfers` read model — SQL table tracking transfer lifecycle, built by consuming the global event stream
- `runReadModel` for long-running subscription, `rebuildReadModel` for replay, `combineReadModels` for fan-out

**Inline notes:**
- Read models are first-class in eventium — checkpointing, initialization, reset, and composition built in
- Most ES libraries leave read model infrastructure to the user

### 8. Wiring It Together (~250 words)

**Show:**
- `EventStoreWriter` / `EventStoreReader` — parametric over key, position, monad, event
- `publishingEventStoreWriter` — wraps store to auto-dispatch events to process managers and read models after writes
- `commandHandlerDispatcher` — routes commands to the right aggregate
- Backend swapping: same domain code with in-memory (STM), SQLite, or PostgreSQL — just different store constructors

**Inline note:** Polymorphic monad design means backend is a deployment decision, not an architectural one.

### 9. Closing (~100 words)

- Testing: pure `decide` and `react` + in-memory store = fast tests, no infrastructure
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

## File

`content/2026-04-eventium.md` with path `blog/2026/04/eventium`
