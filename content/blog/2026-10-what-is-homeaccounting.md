+++
title = "What Is HomeAccounting?"
date = 2026-10-05
description = "What HomeAccounting does today, and how its event-sourced household ledger works inside: transactions as sagas, corrections without overwrites, bank providers as values, idempotent imports, and an LLM that only fills in a form."
path = "blog/2026/10/what-is-homeaccounting"
[taxonomies]
tags = ["haskell", "event-sourcing", "personal-finance", "self-hosting", "homeaccounting"]
categories = ["programming"]
+++

The [previous post](@/blog/2026-09-why-did-i-build-homeaccounting.md) was the *why*: eleven years of tracking household money, two tools that didn't survive, and the one requirement left standing at the end, that recording what you spend should cost no time at all.

This one is the *what* and the *how*. [HomeAccounting](https://www.homeaccounting.com) is a free, open-source accounting system for households. It's AGPL-licensed, built in the open, and meant to be shaped by the people who use it, not only by me. First, what you can do with it today. Then the inside: how a transaction gets from a bank statement or a Telegram message to a balance, what happens when you correct one, and what running [eventium](@/blog/2026-04-eventium-design-and-internals.md) in a real application taught me that the library's examples never did.

<!-- more -->

## What it does today

First, the tour. This is what the code does right now, not a roadmap.

**Accounts.** Cash, bank accounts, e-wallets, assets, loans. Each account has its own currency and an optional overdraft limit. Accounts can be renamed, retyped, closed and reopened. You can change an account's currency only until its first transaction, because after that the history would stop meaning what it says.

**Transactions.** Four kinds: income, expense, transfer, and a balance adjustment for when the ledger and reality disagree and you just want them to agree. Income and expense can be *split* across several categories, so one supermarket receipt can go to three. Transfers can cross currencies. Move UAH to a USD account and both amounts are stored, along with the rate. There are also labels, contacts, a free-text description, and relations between transactions (this one refunds that one, these two were merged into one).

**Capture, three ways.** A connected bank imports on its own. A sentence typed into the web app or sent to the Telegram bot, like `coffee 45, taxi 200, groceries 380`, becomes three categorized transactions. And there are ordinary forms for everything else, which should be the rare path.

**Categories that fit a household.** Income and expense categories, labels and contacts are four dictionaries, each a shallow tree: groups like *Food* containing items like *Groceries* and *Restaurants*. A default tree ships in English and Ukrainian, and you can reshape it however you like.

**Reports.** Spending by category, income versus expense, and net worth across every account you own, converted into your base currency at the rate from each transaction's own date, not today's rate applied to last year.

**Sharing.** Every account has an access list with three roles: Owner, Editor, Viewer. A partner can record into the shared card without seeing your personal savings, or a parent can watch an account without being able to touch it.

**Closing the books.** You can mark a period as closed. After that, nothing on or before that date can be edited. A correction to last year has to be a new transaction this year, the way an accountant would insist.

**It speaks your language, roughly.** Pick a country and you get a regional preset: Ukraine gives you Ukrainian and UAH, the US gives English and USD, the eurozone gives English and EUR. The UI, the bot and the default categories are translated into English and Ukrainian.

**Sign-in.** Email and password, Google, GitHub, Microsoft, or no web account at all, since you can sign up from inside Telegram.

**And you can keep it.** All of it is open source and free, with no paid tier and no feature held back. There's a [seeded demo](https://demo.homeaccounting.com) with no signup, the [hosted app](https://homeaccounting.com/app) that's free during the beta, and a [self-host stack](https://github.com/homeaccounting/docker) that is literally the same Compose file the hosted instance runs.

The rest of this post is about what's underneath.

## The shape of the system

Under the web app and the bot there's one Haskell backend: Servant for HTTP, PostgreSQL for storage, and eventium for everything that counts as a fact. Four aggregates do the work:

- **User**: identity, sign-in methods, linked Telegram and OAuth accounts.
- **Configuration**: one per user. Currencies, language and country, the four dictionaries, bank connections, default accounts, the closed-books date.
- **Account**: balance, currency, access list, lifecycle.
- **Transaction**: one movement of money, and everything that later happens to it.

Their events all live in one application-wide sum type, `AccountingEvent`, written to a single eventium store. It's the same one-table design from [the internals post](@/blog/2026-04-eventium-design-and-internals.md#one-table-two-orderings).

Two modelling decisions shape everything else, so I'll start with them.

### Money is a rational number, all the way down

```haskell
data Money = Money
  { amount :: Rational,
    currency :: Currency
  }
  deriving (Show, Eq, Ord, Generic)

instance ToJSON Money where
  toJSON (Money rat cur) =
    object
      [ "amount" .= show rat,
        "currency" .= cur
      ]
```

Amounts are an exact `Rational`, not a `Double` and not even a fixed-point decimal. In the event store they're serialized as a ratio string like `"91899 % 100"`. Statement parsers read amounts straight from the bank's text into `Rational` without ever touching floating point. Split allocations must sum exactly to the transaction total, and with rationals "exactly" means exactly. It looks odd in a JSON dump, but it has never once produced a balance that's off by a kopiyka.

### Every household has an outside

Double-entry bookkeeping says money never appears or disappears. It moves from one account to another. That's a good discipline, and 1C taught me what it costs when it's imposed on a household as a chart of accounts. HomeAccounting keeps the discipline and hides the ceremony with one trick: when you register, the system creates an **External** account for you. It represents the rest of the world.

Then there's only one kind of movement, and the accounts involved decide the transaction kind:

- Regular → External is an **expense**.
- External → Regular is **income**.
- Regular → Regular is a **transfer**.

A salary is money arriving from outside. A coffee is money leaving to outside. You never see the External account in the UI. You can't share it or close it, and it can go as negative as it likes, because it's the world, not a wallet. But because it exists, every transaction is a debit on one account and a credit on another, and the books always balance without anyone having to think about it.

## A transaction is a saga

Behind that last sentence is the most important design decision in the system: a Transaction aggregate never changes a balance itself.

The Transaction stream records *intent*, as in "move this much from here to there". The balances live on Account streams. Getting from one to the other is the job of a process manager, the posting saga:

1. `TransactionPostingInitiated` on the transaction → issue `DebitAccount` on the source account, with a compensation attached: if the debit is rejected, fail the posting.
2. `AccountDebited` on the source → issue `CreditAccount` on the target, and `CompleteTransactionPosting` on the transaction.
3. `AccountCredited` on the target → the saga forgets the transaction.

Step 2, as code:

```haskell
reactToTransactionPostingEvent manager (StreamEvent _ _ trigMeta (AccountDebitedEvent evt)) =
  case Map.lookup evt.transactionId (manager ^. #transfers) of
    Nothing -> []
    Just td ->
      [ IssueCommand
          (unAccountId td.targetAccount)
          (embedWith accountCommandEmbedding
             (CreditAccountAccountCommand
                CreditAccount {amount = td.targetAmount, transactionId = evt.transactionId}))
          (propagateContext trigMeta),
        IssueCommand
          (unTransactionId evt.transactionId)
          (embedWith transactionCommandEmbedding
             (CompleteTransactionPostingTransactionCommand CompleteTransactionPosting))
          (propagateContext trigMeta)
      ]
```

It's a pure function from saga state and one event to a list of commands. There's no IO, no database, nothing to mock. `propagateContext` carries the correlation id from the triggering event into every command it issues. That's the [metadata pipeline](@/blog/2026-04-eventium-design-and-internals.md#metadata-as-a-pipeline) from the eventium post doing exactly what it was designed for: one request in the logs, followed across three streams.

Why go to this trouble for a household ledger? The Account aggregate is the only thing that knows its own balance, so it's the only thing that can enforce rules about it:

```haskell
handleAccountCommand account (DebitAccountAccountCommand DebitAccount {..})
  | T.null (account ^. #name) = Left AccountDoesNotExist
  | moneyCurrency amount /= moneyCurrency (account ^. #balance) = Left CurrencyMismatch
  -- Bank imports set 'allowOverdraft': the money already moved at the bank, so
  -- the debit must post regardless of the local balance mirror. A resulting
  -- negative balance truthfully signals an earlier transaction still awaiting
  -- import, rather than being an error to reject.
  | allowOverdraft = Right [AccountDebitedAccountEvent AccountDebited {amount = amount, transactionId = transactionId}]
  | otherwise =
      case account ^. #overdraftLimit of
        ...
```

That comment is my favourite piece of domain modelling in the codebase. A manual expense that would overdraw your cash wallet is a mistake, and the system rejects it. The same expense arriving from the bank is a *fact*: the money is already gone. If the local balance goes negative, the bank isn't wrong. The ledger is telling you that something earlier hasn't been imported yet. It's the same command on the same aggregate with the opposite meaning, and where the fact came from decides which one applies.

### Synchronous on purpose

The eventium post describes read models as [polling subscribers](@/blog/2026-04-eventium-design-and-internals.md#resilient-event-consumption) that catch up eventually. HomeAccounting doesn't run them that way.

Every saga and every read model runs **inside the write transaction**. eventium's in-process publisher dispatches depth-first: the posting event triggers the debit, the debit triggers the credit and the completion, the read-model tables are updated and their checkpoints advanced, and only then does the database transaction commit. If any step throws, none of it happened.

When the API returns, the books are consistent. Most CQRS writing treats eventual consistency as part of the package, so why I think this is the right default here gets its own section below.

One small piece of Haskell makes it work. The sagas need a writer to dispatch their commands into, and that writer has to publish to the sagas:

```haskell
accountingEventStoreWriterWithRaw telemetry rawWriter config pmFactory persistentReadModels =
  let globalReader = accountingGlobalEventStoreReader config
      versionedReader = accountingVersionedEventStoreReader config
      -- The process manager receives publishingWriter so events produced by
      -- dispatched commands re-enter the bus (lazy binding resolves the cycle).
      versionedHandler = pmFactory publishingWriter globalReader versionedReader
      globalPublisher =
        mconcat (map readModelPublisher persistentReadModels)
          <> synchronousGlobalPublisher (globalToVersionedHandler versionedHandler)
      observedRawWriter = telemetryEventStoreWriter telemetry rawWriter
      publishingWriter =
        publishingGlobalTaggedCodecEventStoreWriter accountingEventCodec observedRawWriter globalPublisher
   in publishingWriter
```

`publishingWriter` is defined in terms of `globalPublisher`, which is defined in terms of the sagas, which take `publishingWriter`. In most languages that's a dependency-injection framework or a mutable setter. In Haskell it's a `let`. And because the stores are [records rather than typeclasses](@/blog/2026-04-eventium-design-and-internals.md#records-not-typeclasses), the whole write path (raw store, telemetry, codec, read models, sagas) is assembled from values in fifteen lines.

### Consistency

CQRS and event sourcing usually arrive bundled with eventual consistency, often presented as part of the pattern. It's a trade, though: you accept that reads lag behind writes, and you get something specific in exchange. So the question for this system is what eventual consistency would buy *here*, and what it would cost.

**What it buys, in general.** Read models can scale independently of the write side. A slow or broken consumer can't hold up writes. Services can own their data and keep working behind a network partition. And write throughput goes up, because a write only has to append to the log and can leave the projecting to someone else.

**What it would buy here: very little, even at scale.** Go down that list with a household ledger in mind, or rather the thousands of households a hosted instance has to serve.

- *Independent scaling.* Growth here means many small, independent units, not one big stream. Even a busy household produces only a handful of events a day. Apart from an account two people share, nothing it writes depends on another household's state, so the consistency it needs ends at its own books. Thousands of households at that rate is the write volume of an ordinary web app, and nothing about that load calls for a read side that scales separately from the write side.
- *Isolation and partitions.* There's one backend process and one PostgreSQL database. The read models are tables in the same database as the event log. Updating them in the same transaction is a local operation, and there's no network between the two sides for a partition to happen on.
- *Write throughput.* This is the one that looks real, and it's the most surprising non-answer. As the [eventium post](@/blog/2026-04-eventium-design-and-internals.md#postgresql-exclusive-locks) explains, the PostgreSQL writer takes an exclusive lock on the events table so the global sequence has no gaps. Writes are serialized *regardless* of how the read models are wired. Moving projection work out of the transaction would shorten the time the lock is held, but it wouldn't let two writes run in parallel. So the ceiling at scale is that lock, and it's there either way. Short transactions from thousands of households are still far from saturating it. If it ever does saturate, the fix belongs in the store (sequencing writes so unrelated households stop queueing behind one another), not in making each user's reads trail behind their own writes.

**What it would cost: quite a lot.** None of it is exotic. It's the ordinary price of eventual consistency, and every item would land on a person looking at their own money.

- *Read-your-own-writes.* You type `coffee 45`, the bot says it's recorded, you open the app, and the coffee isn't there yet. Or it is, but the balance hasn't moved. In a to-do app that's a glitch. In a ledger it's a reason to stop trusting the numbers, and the [previous post](@/blog/2026-09-why-did-i-build-homeaccounting.md) was about what happens when you stop trusting the numbers.
- *Half-finished money.* The posting saga debits one account and then credits another. Run asynchronously, it leaves a window in which the money has left your card and not yet arrived anywhere, and every report computed in that window is wrong. With the saga inside the transaction, nobody can ever see that state, because it never commits.
- *Failure handling as a subsystem.* Asynchronous sagas need retries, compensations that run later, idempotent handlers for at-least-once delivery, and somewhere for poison messages to go. Synchronously, a failed step is a rolled-back transaction and an error response. The user retries, and there's nothing to clean up.
- *Invariants that span the write and the read side.* Import dedup is the sharpest example. The `imported_transactions` row is written in the same transaction as the event it guards. If the two were updated separately, two imports running close together could both check the table, both find nothing, and both post. That's the exact duplicate the [import section](#importing-the-same-thing-twice) below spends a thousand words preventing.
- *Honest answers.* The prompt handler [checks](#the-llm-only-fills-in-a-form) that a transaction actually posted, not just that it was accepted. That only works because the saga's outcome is known when the request returns. Asynchronously, the honest reply to "did it work?" is "probably, check again in a second".

**What I give up instead.** Every write pays for every read model and every saga that cares about it, so write latency grows with the number of projections. The [saga snapshot fix](#sagas-needed-snapshots-too) further down exists because that cost briefly got out of hand. A bug in a projection also doesn't fall behind quietly. It fails the write. For money I think that's the right failure mode: I'd rather have it loud and immediate than have a projection that's been silently wrong for a week. It's still a real constraint, and it means projection code has to be as careful as domain code.

**And it's reversible.** Nothing here gives up event sourcing. The log is still the source of truth, and every read model still has its own checkpoint and can be rebuilt from scratch. eventium's `ReadModel` is the same record whether it's fed synchronously or by a polling subscription, so if a projection ever does need to run behind (a heavy analytics view, say), moving that one to polling is a change to how it's wired, not a redesign.

Eventual consistency does still exist in the system, but only at the edges, where it's real. The web app learns about changes made elsewhere, such as from the Telegram bot, by polling a per-user data-version counter, so a second device can be a few seconds behind. And the ledger as a whole is only ever eventually consistent with your bank. That gap is the domain itself, and reconciliation is how it's handled. The server never makes you wait on itself.

## Corrections without overwrites

The previous post promised that nothing true is ever unwritten. "Corrections are new events" is easy to say and fiddly to do, so here's what it means in practice.

There are three ways to correct a posted transaction, and each one is its own saga.

**Amendment**: change the amount, the account, the currency. The naive approach is to reverse the old posting completely and post the new one. That works, but it's noisy: change 380 to 385 and the account history shows −380, +380, −385. So the amendment saga computes the *minimal* set of legs instead. If the source account is unchanged and the amount grew, the only new fact is a debit of the difference, 5. If the account changed, the old leg is reversed and a new one posted.

This is where the types earn their keep. Of all the legs an amendment can produce, exactly one can fail: debiting a new source, which might hit an overdraft limit. Reversals and credits always succeed, and the saga's types say so:

```haskell
newtype FallibleLeg = DebitNewSource (AccountId, Money, TransactionId)

data NonFallibleLeg
  = ReverseOldTarget AccountId Money TransactionId UTCTime
  | ReverseOldSource AccountId Money TransactionId UTCTime
  | CreditNewTarget AccountId Money TransactionId

data TransactionAmendmentPhase
  = AwaitingDebit FallibleLeg [NonFallibleLeg]
  | ReadyToFinalize [NonFallibleLeg]
```

The saga attaches compensation only to a `FallibleLeg`, and there's no way to construct a phase in which a non-fallible leg runs before the fallible one has succeeded. Nobody has to remember a comment saying "the debit goes first, and only the debit can be rolled back", because it's the only program that type-checks. The aggregate's own fields (amount, accounts, rate) change only when `TransactionAmendmentCompleted` lands. Until then the transaction says what it said before.

**Cancellation**: reverse both legs. The saga issues both reversals at once and tracks two booleans, and whichever reversal arrives second completes the cancellation. It has no failure path, because reversing money that was actually moved can't be refused. A cancelled transaction doesn't disappear. It stays in the list, marked cancelled, with its full history.

**Merge**: the bank imported a payment, and you'd already typed it in by hand. The merge saga *composes the other two*. It amends the target to absorb the sources, adds a `Merge` relation from each source to the target, then cancels each source. So sagas issue commands that start other sagas, all inside one database transaction and all reversible as a unit.

Every one of these leaves the original events where they were. Open a transaction's history and the backend reads its raw stream (not a projection) and shows every event in order: posted, amended, amended again, merged into. The audit view is just the event log with nicer formatting, which is the point of keeping a log.

## Banks are values, not code paths

The previous post said that nothing in the core knows the name of a bank. This is what that looks like. A bank integration is a record:

```haskell
data BankProviderDescriptor = BankProviderDescriptor
  { providerId :: !BankProviderId,
    displayName :: !Text,
    coverage :: !ProviderCoverage,
    interpretation :: TransactionInterpretation,
    pull :: !(Maybe (BankProviderCredential -> PullCapability)),
    fileImport :: !(Maybe FileImportCapability)
  }

data PullCapability = PullCapability
  { fetchAccounts :: IO (Either Text [BankAccount]),
    fetchStatements :: ExternalAccountId -> UTCTime -> UTCTime -> IO (Either Text [BankTransaction]),
    registerWebhook :: Text -> IO (Either Text ())
  }
```

A provider can pull from a live API, parse statement files, both, or (in principle) neither. `pull` is a function from a decrypted credential to a set of IO actions that already hold it, so the import service never sees a token. It gets capabilities. `fileImport` maps a format, CSV or XLSX, to a *pure* parser: bytes in, rows out. A broken file fails as a whole, but a broken row fails alone and gets reported back to you instead of silently dropped.

`coverage` is `GlobalCoverage | RegionalCoverage (Set Country)`, with no default. A provider that forgets to say where it operates doesn't quietly appear for everyone. It fails to compile.

`interpretation` is the provider's say in what its transactions mean, and it's where banks really differ. Monobank sends a merchant category code, so its expenses are categorized by MCC through a table of about 150 codes. PrivatBank's statements have a human-readable category column instead, in Ukrainian, so they're categorized by label. PrivatBank's business export has neither, but it has the counterparty's company registration number, so it's categorized by counterparty. The core supports all three, and each provider says which one it speaks.

The same goes for recognizing your own transfers. A transfer from your card to your savings shows up as two unrelated lines on two statements, and the importer should post one transfer, not an expense and an income. What counts as "these two lines are the same movement" is bank-specific, so a provider contributes a `TransferMatcher`, and matchers form a monoid:

```haskell
instance Semigroup TransferMatcher where
  TransferMatcher f <> TransferMatcher g = TransferMatcher (\a b -> f a b || g a b)

instance Monoid TransferMatcher where
  mempty = TransferMatcher (\_ _ -> False)
```

The default pairs opposite legs of the same amount and currency within five minutes. PrivatBank's business accounts add a second matcher with `<>` for currency conversions, where the two legs are in different currencies and the only common ground is the exact conversion amount buried in the description. The pairing engine itself enforces exactly one rule, that the two legs must be in different local accounts, and asks the provider about everything else.

Registering a provider is one line in a list. Configuration decides which ones are enabled. `Main.hs` never changes.

Bank credentials are encrypted with AES-256-GCM under a versioned key ring before they go anywhere. Only the ciphertext, plus the last four characters so you can tell your tokens apart, is ever written into an event. The event log is forever, and the token in it shouldn't be readable by anyone who gets a database dump.

## Importing the same thing twice

Import is where most of the real bugs have been, and they all have the same shape: the same real-world payment arrives twice and becomes two transactions. A household ledger with duplicates is worse than no ledger, because you can't trust any number in it.

Dedup starts simply. Every imported row has an external id, and an `imported_transactions` table with a unique constraint records which ones the ledger already holds. Each row is written in the same database transaction as the event that posts it. That mapping is permanent. It's never removed, even if posting later fails. An earlier version evicted the id on failure, and the duplicates that let through taught me not to.

Then it gets less simple.

**Some banks don't give you an id.** PrivatBank's retail statement has no reference column, so the importer builds one from the date, the amount and the running balance. Once that id has been stored, it's a contract. I learned this the hard way. A harmless-looking change normalized the amount formatting so that CSV and XLSX exports produced the same id, and every row imported under the old format now had a new id and got imported again. The fix is recorded as an architecture decision: the id derivation is pinned by a golden test, and any future change ships as a normalizer applied when stored ids are *read*, never as a rewrite of the log:

```haskell
    -- Ids are normalized on the way IN to the view, not by rewriting the log:
    -- a PrivatBank retail id written before commit 38968e9 lands on today's
    -- derivation, so 'isImported' matches what the parser now produces
    -- (backend#3 / ADR 004). Doing it here rather than as a one-off table
    -- migration keeps a rebuild correct, and it is idempotent.
    record txId extIds =
      forM_ extIds $ \extId ->
        void $ insertUnique (ImportedTransactionEntity (normalizePrivatBankRetailId extId) txId)
```

That's the same move as [upcasting events on read](#schema-evolution-without-migrations), where the stored facts stay as they were and the interpretation catches up, applied to a dedup key instead of an event payload. Shipping it took one read-model rebuild.

**Some banks don't tell you the time zone.** PrivatBank's statements are in Kyiv wall-clock time with no offset, and for a while they were stored as if they were UTC. That's two or three hours off, enough to move an evening purchase onto the next day. Parsers now convert through the IANA time-zone database, and the zone belongs to the provider, not the user. The already-stored timestamps were deliberately *not* corrected, because that would mean rewriting posted financial facts. The dedup ids keep using the raw date text, so the conversion couldn't change a dedup key and cause a fresh round of duplicates.

**And sometimes you got there first.** You typed `coffee 45` into Telegram at the counter, and an hour later the bank imports the same 45. That isn't a duplicate external id, since the manual transaction has none. So before posting, the importer tries to *reconcile*: find an existing transaction of the same kind, same amount and currency, on the same account, within three days, and attach the bank's id to it instead of posting a new one. And it refuses to guess:

```haskell
reconcile window imported candidates =
  case [key | (key, cand) <- candidates, isReconciliationMatch window imported cand] of
    [] -> NoMatch
    [only] -> UniqueMatch only
    matched -> Ambiguous matched
```

`Ambiguous` means skip. With two 45-hryvnia coffees in three days, the importer won't decide which one the bank meant. It posts the import as new, and you can merge it by hand. A missed reconciliation is a duplicate you can see and fix. A wrong one silently corrupts a transaction you trusted, and that's the one I can't accept.

Reconciliation used to be tracked with a boolean on the transaction: reconciled or not. That broke on transfers, which have *two* bank legs. The first leg set the flag, and the second found it set and posted itself as a duplicate. The boolean was replaced with a capacity:

```haskell
-- Enumerated constructor by constructor (like 'kindOf') rather than via a
-- catch-all, so that adding a 'TransactionType' is a compile error here instead
-- of silently inheriting a capacity of one.
importAttributionCapacity :: TransactionType -> Int
importAttributionCapacity Transfer = 2
importAttributionCapacity (Income _) = 1
importAttributionCapacity (Expense _) = 1
importAttributionCapacity Adjustment = 1
```

The idea in that comment shows up all over the codebase. There's no wildcard pattern, on purpose, so the compiler *forces* the next person who adds a transaction type to decide its capacity instead of inheriting a default nobody chose. That's the "exhaustive matches over every event type" argument from the previous post, applied deliberately: give up a `_ ->` to get a compile error.

## The LLM only fills in a form

`coffee 45, taxi 200, groceries 380` becoming three transactions is the feature people ask about, so here's exactly how much of it is the model.

Less than you'd think. The pipeline splits the work into what a model is good at and what it must never be trusted with.

| The model decides | Deterministic code decides |
|---|---|
| How many transactions, and of what kind | Which account each one hits |
| Amounts, as text | The exact amount, as a positive `Rational` |
| Which of *your* category names fits | The category id, or your default |
| A date, from "yesterday" and today's date | Whether that date is valid |
| One payment split three ways, or three payments | Everything the domain enforces |

The model gets two messages. The system message carries the contract, today's date, your actual account names and your actual category names (`Food / Groceries`, in whatever language you named them), plus a handful of examples built from your own dictionary rather than English placeholders. The user message is your text, untouched. It runs at temperature zero against any OpenAI-compatible endpoint. The default is an open-weights model on Groq, and a local Ollama or vLLM works the same way.

What comes back is a form, not an answer:

```haskell
-- | One transaction element of the @record_transactions@ payload. Names and
-- amounts are text (in any language); deterministic code resolves them later.
data TransactionIntent = TransactionIntent
  { kind :: !IntentKind,
    amount :: !(Maybe Text),
    allocations :: ![IntentAllocation],
    currency :: !(Maybe Text),
    sourceAccount :: !(Maybe Text),
    targetAccount :: !(Maybe Text),
    description :: !(Maybe Text),
    date :: !(Maybe Text)
  }
```

Every field is text or absent. The model never produces an `AccountId`, a `Money` or a category id, because the intent type has nowhere to put one. Its strings go through a resolver written in pure Haskell, with no IO and no model anywhere near it. Account names are matched exactly first, then by a single unambiguous substring, and two candidates is a refusal rather than a guess. The prompt also goes out of its way to prevent the most dangerous failure, an invented account:

```haskell
      "sourceAccount / targetAccount: output ONE of —",
      "  * the exact name of a listed account, when the user clearly names one;",
      "  * else, when the user refers to a KIND of account in ANY language, the",
      "    English type word \"cash\", \"card\", \"bank\", or \"wallet\" (e.g. Ukrainian",
      "    готівка->\"cash\", карта->\"card\"; Spanish efectivo->\"cash\"). The system maps",
      "    the type to the user's default account of that kind;",
      "  * else null — the system uses the user's default account.",
      "NEVER echo the user's own word for an account or invent a name: use a listed",
      "name, one of those four type words, or null.",
```

That's the division of labour. The model handles language: `готівка` means cash, `вчора` means yesterday, "three things in one line with no punctuation" means three things. The code handles identity. Cross-lingual matching is never attempted in Haskell. The model maps your word to a canonical name, and the code then matches that name exactly or not at all.

A response that doesn't parse gets exactly one retry with a "JSON only" nudge, and then an error. Each transaction in the response decodes and resolves independently, so one garbled item doesn't take the other two down with it. Then each resolved transaction goes through the same write path as a form submission: same commands, same sagas, same invariants. The LLM has no back door into the ledger.

One detail I'm glad got caught: a command being *accepted* isn't the same as a transaction being *posted*. The saga runs after acceptance, and it can still fail the posting on an overdraft. So the prompt handler checks the transaction's final status before telling you it was recorded:

```haskell
            -- A successful *initiation* is not a successful *posting*. The posting
            -- saga runs synchronously in the write path, so an accepted command can
            -- still leave the transaction Failed (e.g. insufficient funds). Report
            -- that as a failed row — never as a recorded transaction — ...
            Right (_tid, TransactionData {status = Failed reason}) ->
              pure (Left (FailedTransaction {index = idx, reason = reason}))
```

That check is only possible because the saga is synchronous, which is one of the reasons spelled out under [Consistency](#consistency).

## Running eventium for real

The [eventium internals post](@/blog/2026-04-eventium-design-and-internals.md) was written about a library with example applications. This is the first time it's carried a real one, and three things changed in practice.

### Sagas needed snapshots too

The internals post described [snapshotting for aggregates](@/blog/2026-04-eventium-design-and-internals.md#snapshotting-aggregate-state) and said, reasonably, that short streams don't need it. It said nothing about process managers.

A saga's state is a projection over the *global* stream. The original wiring rebuilt it from the beginning of the store on every event it handled. So the cost of a write was the number of events written, times the number of sagas, times the total size of the store. That's invisible in a demo and catastrophic as the store grows, and with many households writing to one store, it grows on everyone's behalf. Changing your country, which re-localizes your whole category tree in one go, went from instant to a wait measured in seconds, and even ordinary writes picked up a noticeable delay.

The fix went into eventium itself, as a snapshot-cached process-manager handler:

```haskell
cachedProcessManagerEventHandler relevant pm globalReader cache dispatcher =
  EventHandler $ \event ->
    when (relevant event.payload) $ do
      let globalProj = globalStreamProjection pm.projection
      sp <- getLatestGlobalProjectionWithCache globalReader cache globalProj
      cache.storeSnapshot () sp.position sp.state
      let effects = pm.react sp.state event
      runProcessManagerEffects dispatcher effects
```

Load the last snapshot, fold only the events since, save, react. The `relevant` filter skips the snapshot I/O entirely for events no saga cares about: configuration changes, user events, exchange rates. And because the snapshot is written in the same transaction as the events, it can never get ahead of them. If a snapshot ever fails to decode (say, after the saga's state shape changes), the saga simply replays once and writes a fresh one. There's no migration step, because none is needed.

### Read models are tables, and they rebuild

Every read model (accounts, transactions, users, configuration, exchange rates, import dedup) is a PostgreSQL table updated in the write transaction, with its checkpoint advanced alongside. On startup each one catches up from its checkpoint, and setting `REBUILD_READ_MODELS=transaction` (or `all`) wipes and replays from the log. Every bug fix in the import section used that escape hatch: change how a projection reads the events, rebuild it, and the past is reinterpreted without a single stored fact changing.

One read model is barely a model at all. The web app needs to know when to refetch, so there's a per-user counter bumped whenever any account that user can see changes, and the client polls it. Even that has a correctness story: it's always incremented, never set to the event's sequence number, because a slower concurrent transaction with a lower sequence number would otherwise turn an invalidation into a no-op. And its event classifier has no catch-all pattern, so adding a new event type breaks the build until someone decides whether it should invalidate the client.

### Schema evolution without migrations

Events are forever, but their shapes aren't. When `ConfigurationCreated` gained `language` and `country` fields, the old events in the store didn't get rewritten. Instead, every event is stored in a versioned envelope, and the codec runs a chain of single-hop upcasters on read:

```haskell
configurationCreatedV1toV2 :: Value -> Value
configurationCreatedV1toV2 =
  atKey "contents" (addFieldIfAbsent "language" (String "en") . addFieldIfAbsent "country" Null)

accountingSchemaRegistry :: SchemaRegistry Value
accountingSchemaRegistry =
  registerUpcasters (eventTypeName @ConfigurationCreated) [configurationCreatedV1toV2] emptyRegistry
```

The Haskell type describes only the current shape. History lives in the upcaster list, which is append-only (new hops go on the end, old ones are never edited), and each hop is tested against a fixture copied verbatim from a real production row. The machinery is generic and lives in eventium. The app supplies only the registry.

That's one live hop so far, which is about right for a project this young. But it's the reason I can change an event type on a Tuesday without writing a data migration for a ledger that's supposed to last ten years.

## Around the core

The rest is less interesting to write about, which is how it should be.

**The Telegram bot** runs on a webhook in production and long polling locally. Any free text goes to the prompt pipeline. There are also guided `/income`, `/expense` and `/transfer` flows with inline keyboards for when you'd rather tap than type. Linking an existing web account is a deep link: the web app issues a short-lived single-use code, you open `t.me/...?start=LINK_<code>`, and the bot redeems it. Every recorded transaction gets its own confirmation message, so you can see exactly what the model made of your sentence.

**The web app** is React and TypeScript with TanStack Query, in English and Ukrainian. The [public demo](https://demo.homeaccounting.com) is the same app with the backend swapped out for an in-browser mock seeded with a realistic household. The end-to-end tests and the screenshots on the site run against that mock too.

**The self-host stack** is one Compose file with profiles: Caddy for TLS and routing, the API, the web app, PostgreSQL (or bring your own), and an opt-in observability profile with Prometheus, Loki and Grafana dashboards for events, HTTP, runtime and business metrics. It needs four settings: your domain, a database password, a JWT secret and the key that encrypts bank tokens. The API creates its own schema on first start. It's the same file homeaccounting.com runs on, and the hosted instance differs only in its secrets.

## What it doesn't do yet

Same as last time, in more detail.

**Bank import isn't continuous yet.** Monobank is a live API connection: fetch your accounts, fetch a date range, import. PrivatBank and PrivatBank Business are statement files. You download a CSV or XLSX and drop it in. What's missing is the scheduler and the webhooks that would make the Monobank path fully hands-off. The webhook registration exists in the provider, but the endpoint to receive it doesn't, because I'd rather ship it with proper request authentication than ship a placeholder. For now, "automatic" means one click per month instead of zero.

**There's no confirm step on the prompt.** A sentence becomes transactions immediately, and you correct afterwards if the model got something wrong. With per-transaction confirmations and cheap amendments that's been fine in practice, but a preview is on the list. Labels are passed to the model and not yet applied from its answer.

**"As of" means business time.** You can ask what an account's balance was on any past date, and it's computed from the event log, not a stored snapshot. What you can't yet ask is what the ledger *said* on that date, before later corrections. The events to answer that are all there, since nothing has been thrown away, but the query isn't built.

**Two languages, three banks.** The mechanisms don't care about any of those numbers. The data does.

## Where this leaves it

The design comes down to one rule repeated at every boundary: **facts are kept, interpretation is code**. A bank row is a fact; its category is an interpretation that a provider supplies and a rebuild can change. A posted transaction is a fact; its correction is a new fact, never an edit. An old event is a fact; its current shape is an upcaster. The model's output isn't a fact at all. It's a suggestion that has to get through a pure resolver and the same sagas as everything else before it's allowed to become one.

That's what event sourcing bought here, more than audit trails: the freedom to be wrong about interpretation and fix it later, because the facts underneath never moved.

## Built in the open

HomeAccounting is open source and free, and I want it to be community-driven rather than a one-person project with a public repo. Everything is at [github.com/homeaccounting](https://github.com/homeaccounting): the backend, the web app and the deployment stack. Contributions are welcome.

A lot of the design above is built to be extended, and most of those places don't need you to know event sourcing, or even much Haskell:

- **Your bank.** A provider is the descriptor above plus a parser or an API client. If your bank exports a CSV, that's a pure function from bytes to rows, which makes it the most self-contained contribution in the codebase.
- **Your currency.** The currency set is meant to grow with the people using it.
- **Your language.** The UI, the bot and the default categories are translation catalogs, and English and Ukrainian are only the first two.
- **Your categories.** The MCC table and the default category tree are plain data, and they were written from one household's point of view.
- **The rough edges.** Everything in [What it doesn't do yet](#what-it-doesn-t-do-yet) is a real, scoped piece of work.

Pull requests, issues, bug reports and "this is how my household actually does it" are all useful. The [community links are here](https://www.homeaccounting.com/community), and the [demo](https://demo.homeaccounting.com) needs no signup if you just want to look first.

---

*Part of the **HomeAccounting** series:*

1. [Why Did I Build HomeAccounting?](@/blog/2026-09-why-did-i-build-homeaccounting.md)
2. **What Is HomeAccounting?**
