# Eventium Blog Post Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write a blog post introducing the eventium Haskell event-sourcing library through the bank example.

**Architecture:** Single markdown file `content/2026-04-eventium.md` following existing blog conventions. Story-driven structure building up from domain model to full CQRS system using the bank example.

**Tech Stack:** Zola static site generator, Markdown with TOML front matter, Haskell code blocks.

**Spec:** `docs/superpowers/specs/2026-04-07-eventium-blog-post-design.md`

---

### Task 1: Front Matter and Introduction

**Files:**
- Create: `content/2026-04-eventium.md`

- [ ] **Step 1: Create the blog post file with front matter and introduction**

Write the TOML front matter and introductory section (~100 words). Include `<!-- more -->` marker.

```markdown
+++
title = "Event Sourcing in Haskell with Eventium"
date = 2026-04-07
description = "A walkthrough of eventium, a typed and composable event-sourcing library for Haskell — building a banking system step by step."
path = "blog/2026/04/eventium"
[taxonomies]
tags = ["haskell", "functional-programming", "event-sourcing"]
categories = ["programming"]
+++

Introduction paragraph: hook about building an ES library in Haskell, what eventium is (typed, composable ES/CQRS library, fork of eventful modernized for GHC 9.10+), what the post covers (building a bank to demonstrate each abstraction), version note (v0.2.1), link to GitHub repo.

<!-- more -->
```

- [ ] **Step 2: Verify file exists and front matter is valid**

Run: `cd /Users/oleksandrsy/Projects/Self/blog && nix develop --command zola build 2>&1 | head -20`
Expected: Build succeeds, no front matter errors.

- [ ] **Step 3: Commit**

```bash
git add content/2026-04-eventium.md
git commit -m "post: add eventium blog post - introduction"
```

---

### Task 2: ES/CQRS Primer Section

**Files:**
- Modify: `content/2026-04-eventium.md`

- [ ] **Step 1: Write the ES/CQRS primer section**

Add `## Event Sourcing and CQRS` section (~150-200 words). No code. Cover:
- Events as source of truth
- Projections (deriving state from events)
- Command handlers (validating and producing events)
- CQRS (separate write/read models)
- Process managers (cross-aggregate coordination)

Close with transition: "Let's see how this looks in practice by building a bank."

- [ ] **Step 2: Commit**

```bash
git add content/2026-04-eventium.md
git commit -m "post(eventium): add ES/CQRS primer section"
```

---

### Task 3: Domain Model Section

**Files:**
- Modify: `content/2026-04-eventium.md`

- [ ] **Step 1: Write the domain model section**

Add `## The Domain: A Banking System` section (~350 words). Show:

1. Individual event types from `Bank.Models.Account.Events`:
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
-- ... and AccountCredited, AccountTransferCompleted,
--     AccountTransferFailed, AccountCreditedFromTransfer
```

2. Explain TH sum type generation with both naming conventions:
```haskell
-- Aggregate-level: AppendTypeNameToTags
constructSumType "AccountEvent"
  (withTagOptions AppendTypeNameToTags defaultSumTypeOptions)
  accountEvents
-- Generates: AccountOpenedAccountEvent, AccountCreditedAccountEvent, ...

-- Application-level: ConstructTagName
constructSumType "BankEvent"
  (withTagOptions (ConstructTagName (++ "Event")) defaultSumTypeOptions)
  (accountEvents ++ customerEvents)
-- Generates: AccountOpenedEvent, AccountCreditedEvent, ...
```
Note: process manager code pattern-matches on `BankEvent` constructors (e.g., `AccountTransferStartedEvent`), not `AccountEvent` constructors.

3. Command types (briefly list them, show 1-2):
```haskell
data TransferToAccount = TransferToAccount
  { transferId :: UUID
  , amount :: Double
  , targetAccount :: UUID
  }
```

4. Account state:
```haskell
data Account = Account
  { balance :: Double
  , owner :: Maybe UUID
  , pendingTransfers :: [PendingAccountTransfer]
  }
```

5. Error type:
```haskell
data AccountCommandError
  = AccountAlreadyOpen
  | InvalidInitialDeposit
  | InsufficientFunds Double
  | AccountNotOpen
```

6. Mention Customer aggregate existing alongside (pays off in Section 8).

Inline note: sum types as natural fit for events + TH reducing boilerplate.

- [ ] **Step 2: Verify build with code blocks**

Run: `cd /Users/oleksandrsy/Projects/Self/blog && nix develop --command zola build 2>&1 | grep -i error`
Expected: No errors. This catches malformed code blocks early.

- [ ] **Step 3: Commit**

```bash
git add content/2026-04-eventium.md
git commit -m "post(eventium): add domain model section"
```

---

### Task 4: Projections Section

**Files:**
- Modify: `content/2026-04-eventium.md`

- [ ] **Step 1: Write the projections section**

Add `## Projections: Rebuilding State from Events` section (~300 words). Show:

1. Core `Projection` type:
```haskell
data Projection state event = Projection
  { seed :: state
  , eventHandler :: state -> event -> state
  }
```

2. The account projection handler (simplified excerpt from `handleAccountEvent`):
```haskell
handleAccountEvent :: Account -> AccountEvent -> Account
handleAccountEvent account (AccountOpenedAccountEvent evt) =
  account { owner = Just evt.owner, balance = evt.initialFunding }
handleAccountEvent account (AccountCreditedAccountEvent evt) =
  account { balance = account.balance + evt.amount }
handleAccountEvent account (AccountDebitedAccountEvent evt) =
  account { balance = account.balance - evt.amount }
-- ... transfer events update pendingTransfers

accountProjection :: Projection Account AccountEvent
accountProjection = Projection accountDefault handleAccountEvent
```

3. `latestProjection` usage:
```haskell
latestProjection :: (Foldable t) => Projection state event -> t event -> state
```

Inline notes: pure fold (no IO), Contravariant instance for isomorphic event types, multi-aggregate uses TypeEmbedding (covered later).

- [ ] **Step 2: Commit**

```bash
git add content/2026-04-eventium.md
git commit -m "post(eventium): add projections section"
```

---

### Task 5: Command Handlers Section

**Files:**
- Modify: `content/2026-04-eventium.md`

- [ ] **Step 1: Write the command handlers section**

Add `## Command Handlers: Validating Intent` section (~350 words). Show:

1. `CommandHandler` type:
```haskell
data CommandHandler state event command err = CommandHandler
  { decide :: state -> command -> Either err [event]
  , projection :: Projection state event
  }
```

2. Excerpt of `decide` from bank (the interesting validation cases):
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

3. Wiring it together:
```haskell
accountCommandHandler :: CommandHandler Account AccountEvent AccountCommand AccountCommandError
accountCommandHandler = CommandHandler handleAccountCommand accountProjection
```

4. Mention `applyCommandHandler` — loads projection from store, calls `decide`, writes with optimistic concurrency.

Inline notes: pure `decide`, `ExpectedPosition` for optimistic locking, typed errors (`CommandHandlerError` vs domain errors), `err` type parameter.

- [ ] **Step 2: Commit**

```bash
git add content/2026-04-eventium.md
git commit -m "post(eventium): add command handlers section"
```

---

### Task 6: Process Managers Section

**Files:**
- Modify: `content/2026-04-eventium.md`

- [ ] **Step 1: Write the process managers section**

Add `## Process Managers: Coordinating Transfers` section (~400 words). Show:

1. Motivating problem: transfer = debit source + credit target, needs coordination.

2. `ProcessManager` type:
```haskell
data ProcessManager state event command = ProcessManager
  { projection :: Projection state (VersionedStreamEvent event)
  , react :: state -> VersionedStreamEvent event -> [ProcessManagerEffect command]
  }
```

3. `ProcessManagerEffect`:
```haskell
data ProcessManagerEffect command
  = IssueCommand UUID command
  | IssueCommandWithCompensation UUID command
      (RejectionReason -> [ProcessManagerEffect command])
```

4. Transfer manager's `react` (key excerpt from `TransferManager.hs`):
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

5. Explain the four-step flow:
   1. `TransferToAccount` → emits `AccountTransferStarted`
   2. Process manager reacts → `AcceptTransfer` on target (with compensation)
   3. Success → target emits `AccountCreditedFromTransfer` → `CompleteTransfer` on source
   4. Failure → compensation → `RejectTransfer` on source

6. `runProcessManagerEffects` executes effects via `CommandDispatcher`.

Inline notes: pure `react` (key differentiator), compensation as data not a service, testable without IO.

- [ ] **Step 2: Commit**

```bash
git add content/2026-04-eventium.md
git commit -m "post(eventium): add process managers section"
```

---

### Task 7: Read Models Section

**Files:**
- Modify: `content/2026-04-eventium.md`

- [ ] **Step 1: Write the read models section**

Add `## Read Models: Queryable Views` section (~300 words). Show:

1. Motivating question: write side is done, how to query across aggregates?

2. `ReadModel` type:
```haskell
data ReadModel m event = ReadModel
  { initialize :: m ()
  , eventHandler :: EventHandler m (GlobalStreamEvent event)
  , checkpointStore :: CheckpointStore m SequenceNumber
  , reset :: m ()
  }
```

3. Bank's `Transfers` read model (excerpt from `Transfers.hs`):
```haskell
transferReadModel :: ReadModel (SqlPersistT IO) BankEvent
transferReadModel = ReadModel
  { initialize = void $ runMigrationSilent migrateTransfer
  , eventHandler = EventHandler handleTransferEvent
  , checkpointStore = sqliteCheckpointStore (CheckpointName "transfers")
  , reset = deleteWhere ([] :: [Filter TransferEntity])
  }
```

4. Operations: `runReadModel` (long-running), `rebuildReadModel` (replay), `combineReadModels` (fan-out).

Inline notes: ReadModel is backend-agnostic (parametric over `m`), SQL is the example's choice. First-class abstraction — checkpointing, init, reset, composition built in.

- [ ] **Step 2: Commit**

```bash
git add content/2026-04-eventium.md
git commit -m "post(eventium): add read models section"
```

---

### Task 8: Wiring Section

**Files:**
- Modify: `content/2026-04-eventium.md`

- [ ] **Step 1: Write the wiring section**

Add `## Putting It All Together` section (~350 words). Show:

1. TypeEmbedding for multi-aggregate composition:
```haskell
mkSumTypeEmbedding "accountEventEmbedding" ''AccountEvent ''BankEvent
mkSumTypeEmbedding "accountCommandEmbedding" ''AccountCommand ''BankCommand

accountBankCommandHandler :: CommandHandler Account BankEvent BankCommand AccountCommandError
accountBankCommandHandler =
  embeddedCommandHandler accountEventEmbedding accountCommandEmbedding accountCommandHandler
```

2. `publishingEventStoreWriter` for post-write dispatch to handlers.

3. `commandHandlerDispatcher` routing BankCommand to Account or Customer handler.

4. Backend swapping: same domain code, swap store constructor (memory/SQLite/PostgreSQL).

5. Brief Codec mention: `deriveJSON` for wire format, lenient codecs for forward compatibility.

Inline note: polymorphic monad → backend is a deployment decision.

- [ ] **Step 2: Commit**

```bash
git add content/2026-04-eventium.md
git commit -m "post(eventium): add wiring section"
```

---

### Task 9: Closing Section and Final Review

**Files:**
- Modify: `content/2026-04-eventium.md`

- [ ] **Step 1: Write the closing section**

Add `## Wrapping Up` section (~100 words). Cover:
- Testing: pure `decide` and `react` + in-memory store
- Not covered: `ProjectionCache` for snapshotting, `EventSubscription` with resilient polling
- Backends: memory, SQLite, PostgreSQL
- Link to repo and full bank example
- Invite to try it

- [ ] **Step 2: Build and verify the blog locally**

Run: `cd /Users/oleksandrsy/Projects/Self/blog && nix develop --command zola build 2>&1 | tail -5`
Expected: Build succeeds, site generated.

Run: `cd /Users/oleksandrsy/Projects/Self/blog && nix develop --command zola build 2>&1 | grep -i error`
Expected: No errors.

- [ ] **Step 3: Verify post appears in build output**

Run: `ls /Users/oleksandrsy/Projects/Self/blog/public/blog/2026/04/eventium/`
Expected: `index.html` exists.

- [ ] **Step 4: Commit**

```bash
git add content/2026-04-eventium.md
git commit -m "post(eventium): add closing section"
```

- [ ] **Step 5: Final commit with complete post**

Review the entire post for flow, accuracy, and word count. Make any final edits, then:

```bash
git add content/2026-04-eventium.md
git commit -m "post: add eventium event-sourcing library blog post"
```
