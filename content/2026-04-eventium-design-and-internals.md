+++
title = "Eventium: Design Decisions and Internals"
date = 2026-04-11
description = "A deep dive into the design decisions behind eventium — schema design, total ordering, optimistic concurrency, metadata pipelines, snapshotting, and resilient event consumption."
path = "blog/2026/04/eventium-design-and-internals"
[taxonomies]
tags = ["haskell", "functional-programming", "event-sourcing"]
categories = ["programming"]
+++

In the [previous post](@/2026-04-eventium-event-sourcing-library-for-haskell.md), I walked through building a banking system with [eventium](https://github.com/aleks-sidorenko/eventium) — covering projections, command handlers, process managers, and read models from the user's perspective. This post goes one layer deeper: how the event store is structured, what guarantees it provides, and why things are built the way they are.

Each section opens with a problem that arises when you try to build a production event store, then shows how eventium addresses it and what tradeoffs that involves.

<!-- more -->

## One Table, Two Orderings

An event store has to serve two fundamentally different access patterns. Per-aggregate reads fetch all events for a single entity — "give me everything that happened to account X, in order." Global reads fetch events across all aggregates in total order — "give me every event in the system since sequence number 1000." The first is how command handlers reconstruct state. The second is how read models catch up.

The naive approach is two tables: one for per-aggregate streams, one for the global log. But dual-write creates a consistency problem. What if the per-aggregate insert succeeds but the global log insert fails? Now your system has events that exist in one place but not the other. You need distributed transactions or careful compensation logic — for your own internal storage layer.

Eventium uses a single table instead:

```haskell
share
  [mkPersist sqlSettings, mkMigrate "migrateSqlEvent"]
  [persistLowerCase|
SqlEvent sql=events
    uuid UUID
    version EventVersion
    payload JSONString
    metadata JSONString Maybe
    UniqueUuidVersion uuid version
    deriving Show
|]
```

This is a [Persistent](https://hackage.haskell.org/package/persistent) entity definition that generates the following schema:

| Column | Type | Purpose |
|--------|------|---------|
| `id` (PK) | auto-increment | Global sequence number |
| `uuid` | UUID | Aggregate / stream identifier |
| `version` | integer | Position within the stream |
| `payload` | JSON | Serialized event |
| `metadata` | JSON (nullable) | Event type, correlation/causation IDs, timestamps |

The unique constraint on `(uuid, version)` enforces per-stream ordering. The auto-increment primary key provides global ordering without a separate sequence table. Per-aggregate reads filter by `uuid` and order by `version`. Global reads just order by `id`.

The tradeoff is straightforward: a single table is simpler and eliminates dual-write consistency issues entirely. Global reads scan the full table rather than a dedicated log table, but that's fine in practice — global reads are batch operations for read model catch-up, not latency-sensitive queries on the hot path.

## Gap-Free Global Sequences

Auto-increment IDs seem to give you total ordering for free. They don't — not under concurrency.

Consider two concurrent transactions writing to the same events table:

```
Time 1: Tx A begins, gets auto-increment ID 1
Time 2: Tx B begins, gets auto-increment ID 2
Time 3: Tx B commits (event 2 is now visible)
Time 4: Subscriber polls, sees event 2, advances checkpoint to 2
Time 5: Tx A commits (event 1 is now visible)
Time 6: Subscriber polls for events after 2 — event 1 is missed forever
```

The subscriber saw event 2 and assumed it had everything up to that point. But event 1 was still in-flight. Once the subscriber's checkpoint advances past it, that event is permanently invisible. This isn't a theoretical concern — it's a real data loss bug in any checkpoint-based system that assumes contiguous IDs.

### PostgreSQL: Exclusive Locks

PostgreSQL's solution in eventium is explicit serialization:

```haskell
tableLockFunc :: Text -> Text
tableLockFunc tableName = "LOCK " <> tableName <> " IN EXCLUSIVE MODE"
```

Before inserting events, the writer acquires an exclusive lock on the events table. This serializes all inserts — only one transaction can write at a time, so auto-increment IDs are always assigned and committed in order. No gaps visible to readers.

The lock is applied conditionally inside `sqlStoreEvents`:

```haskell
sqlStoreEvents config mLockCommand maxVersionSql uid events = do
  versionNum <- sqlMaxEventVersion config maxVersionSql uid
  let entities = zipWith (\v e -> config.sequenceMakeEntity uid v e Nothing) [versionNum + 1 ..] events
  -- NB: We need to take a lock on the events table or else the global sequence
  -- numbers may not increase monotonically over time.
  for_ mLockCommand $ \lockCommand -> rawExecute (lockCommand tableName) []
  _ <- insertMany entities
  return $ versionNum + EventVersion (length events)
```

The `mLockCommand` parameter is a `Maybe (Text -> Text)` — present for PostgreSQL, absent for SQLite. The function takes a table name and returns the lock SQL. This keeps the locking strategy out of the shared write logic.

The PostgreSQL writer passes `Just tableLockFunc`:

```haskell
postgresqlEventStoreWriter config = EventStoreWriter $ transactionalExpectedWriteHelper getLatestVersion storeEvents'
  where
    getLatestVersion = sqlMaxEventVersion config maxPostgresVersionSql
    storeEvents' = sqlStoreEvents config (Just tableLockFunc) maxPostgresVersionSql
```

The tradeoff: serialization bottleneck on writes. Every event write goes through a single lock. For most event-sourced systems this is acceptable — event writes are small and fast (a few rows of JSON), and the lock is held only for the duration of the insert, not the entire command processing cycle. The read-decide phase happens before the lock is acquired.

### SQLite: Single-Writer by Design

SQLite doesn't need explicit locking:

```haskell
sqliteEventStoreWriter config = EventStoreWriter $ transactionalExpectedWriteHelper getLatestVersion storeEvents'
  where
    getLatestVersion = sqlMaxEventVersion config maxSqliteVersionSql
    storeEvents' = sqlStoreEvents config Nothing maxSqliteVersionSql
```

`Nothing` for the lock command — because SQLite's write model is inherently serialized. Only one transaction can write at a time, so gap-free sequences fall out naturally.

The tradeoff: no write concurrency at all. Fine for single-process systems, development, testing, or low-write-volume production deployments. If you need concurrent writers, use PostgreSQL.

### The Abstraction

Both backends expose the same `EventStoreWriter` interface. The gap-free guarantee is a property of the backend, not the abstraction. Application code — command handlers, process managers, read models — doesn't know or care which strategy is in use. You pick the backend at the application boundary:

```haskell
-- PostgreSQL
writer = postgresqlEventStoreWriter config

-- SQLite
writer = sqliteEventStoreWriter config
```

Same type, same interface, different concurrency properties.

## Optimistic Concurrency Without Locks

Two command handlers read the same aggregate at version 5. Both run their business logic against that state. Both decide to write. If both succeed, the event stream is corrupted — events that were validated against the same state, not against each other.

You need concurrency control. Pessimistic locking — acquire a lock on the aggregate before reading, hold it through the entire read-decide-write cycle — works but kills throughput. The lock duration includes business logic execution, which could be arbitrarily slow.

Eventium uses optimistic concurrency instead, via `ExpectedPosition`:

```haskell
data ExpectedPosition position
  = AnyPosition
  | NoStream
  | StreamExists
  | ExactPosition position
```

The command handler captures the stream's current version when it reads events, then asserts that version hasn't changed when it writes:

```haskell
applyCommandHandler writer reader cmdHandler uuid command = do
  sp <- getLatestStreamProjection reader (versionedStreamProjection uuid cmdHandler.projection)
  case cmdHandler.decide sp.state command of
    Left err -> return $ Left (CommandRejected err)
    Right events -> do
      result <- writer.storeEvents uuid (ExactPosition sp.position) events
      case result of
        Left writeErr -> return $ Left (ConcurrencyConflict writeErr)
        Right _ -> return $ Right events
```

Three phases: read (replay events, capture version), decide (pure business logic), write (assert version, store events). No lock is held during the decide phase. If another writer modified the stream between the read and write, the version check fails and the write is rejected with `ConcurrencyConflict`.

At the SQL level, `transactionalExpectedWriteHelper` implements the check:

```haskell
transactionalExpectedWriteHelper' (Just f) getLatestVersion' storeEvents' uuid events = do
  latestVersion <- getLatestVersion' uuid
  if f latestVersion
    then storeEvents' uuid events <&> Right
    else return $ Left $ EventStreamNotAtExpectedVersion latestVersion
```

Read the current version, check it against the expected position, write or reject. All within a single database transaction, so the check-then-write is atomic.

The error type makes the two failure modes explicit:

```haskell
data CommandHandlerError err
  = CommandRejected err
  | ConcurrencyConflict (EventWriteError EventVersion)
```

Domain rejection (`InsufficientFunds`, `AccountNotOpen`) and infrastructure conflict (version mismatch) are different types with different handling strategies. The compiler ensures you address both.

No retries are built in. This is deliberate — retry strategy depends on the domain. Some commands are safe to retry (idempotent reads), others aren't (non-idempotent transfers). The caller decides.

## Records, Not Typeclasses

Most Haskell libraries that need pluggable backends reach for typeclasses. You'd expect something like:

```haskell
class EventStore m where
  getEvents :: QueryRange key position -> m [event]
  storeEvents :: key -> ExpectedPosition position -> [event] -> m (Either ...)
```

Eventium doesn't do this. The store abstractions are plain record types:

```haskell
newtype EventStoreReader key position m event =
  EventStoreReader { getEvents :: QueryRange key position -> m [event] }

newtype EventStoreWriter key position m event =
  EventStoreWriter { storeEvents :: key -> ExpectedPosition position -> [event]
                  -> m (Either (EventWriteError position) EventVersion) }
```

This is a deliberate design choice, and it matters more than it might seem.

With typeclasses, each monad gets one instance. If you want an in-memory store and a PostgreSQL store, you need different monads — or you reach for `newtype` wrappers with `GeneralizedNewtypeDeriving`, which adds ceremony without adding clarity. Worse, if two store implementations exist for the same monad, you have an orphan instance problem.

With records, stores are values. You can have two different PostgreSQL writers in the same program — one for the main events table, one for an archive table — and pass them wherever they're needed. No typeclass resolution, no orphan instances, no ambiguity.

This also makes composition straightforward. `runEventStoreReaderUsing` lifts a reader from one monad to another:

```haskell
runEventStoreReaderUsing ::
  (forall a. mstore a -> m a) ->
  EventStoreReader key position mstore event ->
  EventStoreReader key position m event
runEventStoreReaderUsing runStore (EventStoreReader f) = EventStoreReader (runStore . f)
```

It takes a natural transformation (`mstore ~> m`) and produces a new reader. With typeclasses, you'd need `MonadTrans` stacks or `lift` calls scattered through your code. With records, it's one function application at the boundary.

The same pattern applies to codec wrapping. Since `EventStoreWriter` has a `Contravariant` instance:

```haskell
instance Contravariant (EventStoreWriter key position m) where
  contramap f (EventStoreWriter writer) =
    EventStoreWriter $ \key expectedPos -> writer key expectedPos . fmap f
```

You can transform what a writer accepts with `contramap codec.encode` — turning a writer that stores serialized values into one that accepts domain events. No new type, no new instance, just function composition on a value.

The tradeoff: you lose automatic dispatch. With typeclasses, the compiler picks the right implementation based on the type. With records, you pass the implementation explicitly. In practice this is a feature — event store configuration is something you want to see at the call site, not resolved invisibly by the compiler.

The same reasoning extends to `Codec` (vs a `Serializable` typeclass), `ProjectionCache`, `CheckpointStore`, and `CommandDispatcher`. All are records. All compose as values.

## Metadata as a Pipeline

Events need infrastructure metadata — timestamps, event type names, correlation and causation IDs for distributed tracing. But domain event types shouldn't carry infrastructure concerns. `AccountOpened` describes what happened in the business domain. When it happened, what type name to use for serialization routing, which request triggered it — those are infrastructure questions.

Eventium separates the two. Metadata lives on `StreamEvent`, not on the domain event:

```haskell
data EventMetadata = EventMetadata
  { eventType :: !Text,
    correlationId :: !(Maybe UUID),
    causationId :: !(Maybe UUID),
    createdAt :: !(Maybe UTCTime),
    occurredAt :: !(Maybe UTCTime)
  }
```

`eventType` is derived automatically from the Haskell type via `Typeable` — no manual string registration. `createdAt` is wall-clock time at write. `occurredAt` is optional, for backdated events (importing historical data, for instance). Correlation and causation IDs support distributed tracing across aggregates.

The pipeline is built around `MetadataEnricher`:

```haskell
type MetadataEnricher = EventMetadata -> EventMetadata
```

Just a function. Compose enrichers with `.`, use `id` when no enrichment is needed:

```haskell
-- Set occurredAt for backdated events
let enricher = \m -> m { occurredAt = Just pastTime }

-- Compose multiple enrichments
let enricher = (\m -> m { occurredAt = Just pastTime })
             . (\m -> m { correlationId = Just corrId })
```

`metadataEnrichingEventStoreWriterWithEnricher` applies the full pipeline at write time:

```haskell
metadataEnrichingEventStoreWriterWithEnricher enricher codec (EventStoreWriter write) =
  EventStoreWriter $ \key pos events -> do
    now <- liftIO getCurrentTime
    let tagged =
          map
            ( \e ->
                TaggedEvent
                  (enricher (EventMetadata (T.pack . show $ typeOf e) Nothing Nothing (Just now) (Just now)))
                  (codec.encode e)
            )
            events
    write key pos tagged
```

For each event: generate base metadata (type name from `Typeable`, current timestamp), apply the enricher, encode the event via the codec, wrap both in a `TaggedEvent`, and write. Domain events go in, tagged serialized events come out.

The enricher flows through the entire command pipeline. `CommandDispatcher` carries it, `ProcessManagerEffect` carries it — so process managers can propagate correlation IDs from triggering events to the commands they issue. A transfer started on account A generates events on account B, and the correlation ID threads through the whole flow.

The tradeoff: enrichers are functions, not data. You can't inspect or serialize them. This is fine because they're transient — applied once at write time and discarded. But it means you can't log "what enrichment was applied" without the enricher itself doing the logging.

## Snapshotting Aggregate State

Projections replay every event from the beginning of a stream to reconstruct current state. For an aggregate with ten events, this is trivial. For an aggregate with ten thousand events, every command pays the cost of replaying the entire history before `decide` can even run.

Eventium addresses this with `ProjectionCache`:

```haskell
data ProjectionCache key position encoded m
  = ProjectionCache
  { storeSnapshot :: key -> position -> encoded -> m (),
    loadSnapshot :: key -> m (Maybe (position, encoded))
  }
```

A key-value store with knowledge of stream position. Store the projected state at a given version, load it later and only replay events since that version.

`applyCommandHandlerWithCache` uses this to skip replayed events:

```haskell
applyCommandHandlerWithCache writer reader cache cmdHandler uuid command = do
  sp <- getLatestVersionedProjectionWithCache reader cache (versionedStreamProjection uuid cmdHandler.projection)
  case cmdHandler.decide sp.state command of
    Left err -> return $ Left (CommandRejected err)
    Right events -> do
      result <- writer.storeEvents uuid (ExactPosition sp.position) events
      case result of
        Left writeErr -> return $ Left (ConcurrencyConflict writeErr)
        Right endVersion -> do
          let newState = foldl' cmdHandler.projection.eventHandler sp.state events
          cache.storeSnapshot uuid endVersion newState
          return $ Right events
```

On read: load cached state at version N, then only fetch events from N+1 onward and fold those onto the cached state. On successful write: compute the new state by folding the just-written events, update the cache.

Cache invalidation is simple because event streams are append-only. A cached state at version N is always valid — the events that produced it can never change. You only ever need to replay forward. There's no traditional cache invalidation problem here.

The second tradeoff is less obvious: snapshotting requires a serialization instance for your aggregate state. Domain events already need codecs for persistence, but aggregate state is normally transient — it exists only in memory during command processing. Making it persistent means state shape changes (adding a field, changing a type) require either a cache migration or a full wipe-and-rebuild.

When to snapshot: not every aggregate needs it. If your streams are short-lived — tens of events, maybe a few hundred — the replay cost is negligible. Snapshotting pays off for long-lived aggregates with high command throughput, where replaying thousands of events per command becomes a bottleneck.

## Read Models: In-Memory vs Persisted

Not every read model needs a database. Some views are small enough to live entirely in memory — a running counter, a set of active transfer IDs. Others need to survive process restarts and serve queries from external clients. The same abstraction should support both without forcing one approach.

This is where the monad parameter on `ReadModel` earns its keep:

```haskell
data ReadModel m event = ReadModel
  { initialize :: m (),
    eventHandler :: EventHandler m (GlobalStreamEvent event),
    checkpointStore :: CheckpointStore m SequenceNumber,
    reset :: m ()
  }
```

The type is parametric over `m`. The four fields have clear lifecycle roles: `initialize` sets up storage (run migrations, create tables), `eventHandler` processes events from the global stream, `checkpointStore` tracks the last consumed position, `reset` wipes everything for rebuilds.

**Persisted read models** use SQL:

```haskell
transferReadModel :: ReadModel (SqlPersistT IO) BankEvent
transferReadModel = ReadModel
  { initialize = void $ runMigrationSilent migrateTransfer,
    eventHandler = EventHandler handleTransferEvent,
    checkpointStore = sqliteCheckpointStore (CheckpointName "transfers"),
    reset = deleteWhere ([] :: [Filter TransferEntity])
  }
```

Backed by SQLite or PostgreSQL. Survives restarts — the checkpoint persists in the database, so on restart the read model picks up where it left off. Queryable from other processes via SQL.

**In-memory read models** use STM:

```haskell
counterReadModel :: TVar Int -> ReadModel IO CounterEvent
counterReadModel tvar = ReadModel
  { initialize = pure (),
    eventHandler = EventHandler $ \event -> atomically $ modifyTVar' tvar (applyEvent event),
    checkpointStore = memoryCheckpointStore checkpointTVar,
    reset = atomically $ writeTVar tvar 0
  }
```

Backed by a `TVar`. Initialization is a no-op. Reset writes the initial value. Fast, no serialization overhead — but lost on restart. On startup, the read model replays from the beginning of the event log.

When to use which: in-memory for derived state that's cheap to rebuild and only consumed in-process — caches, dashboard counters, internal lookups. Persisted for views that external clients query or that would be expensive to rebuild from scratch (large event histories).

The `ReadModel` type doesn't care. Same four fields, same interface. The choice is made at construction time, not embedded in the abstraction.

## Resilient Event Consumption

Read models consume the global event stream continuously. The simple approach — poll, process, checkpoint — works until something goes wrong. A transient database error shouldn't permanently kill your read model. But naive retry — immediately, forever — can DDoS a recovering database.

### Checkpointing

The checkpoint tracks the last successfully processed sequence number. After handling a batch of events, the read model saves the final position:

```haskell
pollReadModelOnce globalReader pollIntervalMs rm = do
  latestSeq <- rm.checkpointStore.getCheckpoint
  newEvents <- globalReader.getEvents (eventsStartingAt () $ latestSeq + 1)
  handleEvents rm.eventHandler newEvents
  case NE.nonEmpty newEvents of
    Nothing -> return ()
    Just ne -> rm.checkpointStore.saveCheckpoint (NE.last ne).position
  liftIO $ threadDelay (pollIntervalMs * 1000)
```

If the process crashes after handling events but before saving the checkpoint, those events will be reprocessed on restart. This is at-least-once delivery — event handlers must be idempotent. Eventium doesn't try to provide exactly-once semantics, because doing so reliably across arbitrary storage backends is a distributed systems problem that doesn't belong in a library.

### Rebuild

`rebuildReadModel` wipes the read model and replays everything:

```haskell
rebuildReadModel globalReader rm = do
  rm.reset
  rm.initialize
  replayAll
  where
    replayAll = do
      latestSeq <- rm.checkpointStore.getCheckpoint
      newEvents <- globalReader.getEvents (eventsStartingAt () $ latestSeq + 1)
      case NE.nonEmpty newEvents of
        Nothing -> return ()
        Just ne -> do
          handleEvents rm.eventHandler newEvents
          rm.checkpointStore.saveCheckpoint (NE.last ne).position
          replayAll
```

Call `reset` (drop all data), `initialize` (re-run migrations), then replay in batches until there are no more events. Useful when you've changed the projection logic and need to regenerate the view.

### Resilient Subscriptions

For production, `resilientPollingSubscription` adds error recovery with exponential backoff:

```haskell
resilientPollingSubscription unlift globalReader checkpoint pollIntervalMs retryCfg =
  EventSubscription $ \handler -> loop handler 0
  where
    loop handler consecutiveErrors = do
      result <- liftIO $ try $ unlift $ pollOnce globalReader checkpoint pollIntervalMs handler
      case result of
        Right () -> loop handler 0
        Left (ex :: SomeException) -> do
          shouldRetry <- liftIO $ retryCfg.onError ex
          if shouldRetry
            then do
              let newCount = consecutiveErrors + 1
              liftIO $ retryCfg.onErrorCallback ex newCount
              liftIO $ threadDelay (backoffMicros retryCfg newCount)
              loop handler newCount
            else liftIO $ throwIO ex
```

A few things worth noting:

The `unlift` parameter (`forall a. m a -> IO a`) converts monadic actions to `IO` for exception handling. This follows the same pattern as `runEventStoreReaderUsing` — a natural transformation that lets you work across monad boundaries.

On success, the consecutive error count resets to zero. On failure, it increments and the delay grows: `min maxDelay (initialDelay * multiplier ^ (count - 1))`. The `onError` predicate lets the caller distinguish transient failures (retry) from fatal ones (re-throw). The `onErrorCallback` is for logging.

Sensible defaults: 1-second initial delay, 30-second cap, 2x multiplier:

```haskell
defaultRetryConfig = RetryConfig
  { initialDelayMs = 1000,
    maxDelayMs = 30000,
    backoffMultiplier = 2.0,
    onError = const (return True),
    onErrorCallback = \_ _ -> return ()
  }
```

The tradeoff with polling: latency between event write and read model update is bounded by the poll interval. For most CQRS systems this is acceptable — read models are eventually consistent by design. If you need sub-second latency, you'd need a push-based mechanism, which eventium doesn't currently provide.

## Codec vs TypeEmbedding: Same Shape, Different Semantics

Events need two kinds of conversion. Serialization: turning domain events into JSON for storage and back. Type embedding: fitting aggregate-level events (`AccountEvent`) into application-wide sum types (`BankEvent`) and back. Both have the same shape — a total function one way, a partial function back:

```haskell
data Codec a b = Codec
  { encode :: a -> b,
    decode :: b -> Maybe a
  }

data TypeEmbedding a b = TypeEmbedding
  { embed :: a -> b,
    extract :: b -> Maybe a
  }
```

Structurally identical. So why two types?

**Codec** is for the wire boundary. It carries serialization concerns — event type names, JSON encoding, `DecodeError` exceptions. It's used by `metadataEnrichingEventStoreWriter` to encode domain events before storage. Going through a codec means data crosses a serialization boundary: in-memory Haskell values become JSON, and JSON becomes Haskell values (or `Nothing` on decode failure).

**TypeEmbedding** is for the type hierarchy. No serialization involved. It says "AccountEvent is a subset of BankEvent" — every `AccountEvent` can be embedded into `BankEvent`, and some `BankEvent` values can be extracted back as `AccountEvent`. It's used by `embeddedCommandHandler` and `embeddedProjection` to lift aggregate-level handlers to work with application-wide types.

The separation prevents accidental misuse. Using a `Codec` where you meant a `TypeEmbedding` would serialize and deserialize events that are already in memory — unnecessary work and potentially lossy if the codec isn't perfectly round-tripping. Using a `TypeEmbedding` where you meant a `Codec` would skip serialization entirely, passing raw Haskell values to a store that expects JSON. Having two distinct types means the compiler catches both mistakes.

`embeddingToCodec` exists as an escape hatch when you genuinely need to cross the boundary:

```haskell
embeddingToCodec :: TypeEmbedding a b -> Codec a b
embeddingToCodec (TypeEmbedding e x) = Codec e x
```

Both types are values, not typeclasses. You can have multiple codecs for the same type (different JSON formats for migration), multiple embeddings (different application-wide sum types for different contexts), and no orphan instance problems. Template Haskell generates both — `mkSumTypeCodec` for wire codecs, `mkSumTypeEmbedding` for type hierarchy embeddings — by matching constructors on inner type.

## Wrapping Up

The recurring theme across all of these decisions is that each one is a tradeoff made explicit. Single table vs dual tables — simplicity over optimal read performance. Exclusive locks vs single-writer — PostgreSQL serializes writes; SQLite doesn't need to. Optimistic vs pessimistic concurrency — no locks held during business logic, conflicts detected on write. At-least-once vs exactly-once — handlers must be idempotent, but the library doesn't pretend to solve distributed exactly-once delivery.

Eventium picks a side on each of these and makes the choice visible in the types and the API rather than hiding it behind "smart" defaults. `ExpectedPosition` is a value you construct, not a flag buried in configuration. `MetadataEnricher` is a function you compose, not a magic annotation. `ProjectionCache` is a record you pass in, not an implicit layer. When something goes wrong, you can see exactly what was configured and why.

The [previous post](@/2026-04-eventium-event-sourcing-library-for-haskell.md) covers the user-facing side — projections, command handlers, process managers, read models. The library itself is at [aleks-sidorenko/eventium](https://github.com/aleks-sidorenko/eventium). Feedback and contributions are welcome.
