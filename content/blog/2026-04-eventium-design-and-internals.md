+++
title = "Eventium: Design Decisions and Internals"
date = 2026-04-11
description = "The design decisions behind eventium: schema design, total ordering, optimistic concurrency, metadata pipelines, snapshotting, and resilient event consumption."
path = "blog/2026/04/eventium-design-and-internals"
[taxonomies]
tags = ["haskell", "functional-programming", "event-sourcing"]
categories = ["programming"]
+++

In the [previous post](@/blog/2026-04-eventium-event-sourcing-library-for-haskell.md), I walked through building a banking system with [eventium](https://github.com/aleks-sidorenko/eventium), covering projections, command handlers, process managers, and read models from the user's side. This post goes one layer down: how the event store is structured, what guarantees it gives, and why it's built the way it is.

Each section starts with a problem you hit when building a production event store, then shows how eventium handles it and what the tradeoffs are.

<!-- more -->

## One table, two orderings

An event store has to serve two very different access patterns. Per-aggregate reads fetch all events for a single entity: "give me everything that happened to account X, in order." Global reads fetch events across all aggregates in total order: "give me every event in the system since sequence number 1000." Command handlers use the first to reconstruct state. Read models use the second to catch up.

The naive approach is two tables: one for per-aggregate streams, one for the global log. But dual writes create a consistency problem. What if the per-aggregate insert succeeds and the global log insert fails? Now some events exist in one place but not the other. You need distributed transactions or careful compensation logic, and all that for your own internal storage layer.

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

The unique constraint on `(uuid, version)` enforces per-stream ordering. The auto-increment primary key gives global ordering without a separate sequence table. Per-aggregate reads filter by `uuid` and order by `version`. Global reads just order by `id`.

The tradeoff is simple: one table is easier to reason about and removes dual-write consistency issues entirely. Global reads scan the full table rather than a dedicated log table, but that's fine in practice. Global reads are batch operations for read model catch-up, not latency-sensitive queries on the hot path.

## Gap-free global sequences

Auto-increment IDs seem to give you total ordering for free. Under concurrency, they don't.

Consider two concurrent transactions writing to the same events table:

```
Time 1: Tx A begins, gets auto-increment ID 1
Time 2: Tx B begins, gets auto-increment ID 2
Time 3: Tx B commits (event 2 is now visible)
Time 4: Subscriber polls, sees event 2, advances checkpoint to 2
Time 5: Tx A commits (event 1 is now visible)
Time 6: Subscriber polls for events after 2 — event 1 is missed forever
```

The subscriber saw event 2 and assumed it had everything up to that point. But event 1 was still in flight. Once the subscriber's checkpoint moves past it, that event is invisible for good. This is a real data loss bug in any checkpoint-based system that assumes contiguous IDs.

### PostgreSQL: exclusive locks

In eventium, the PostgreSQL solution is explicit serialization:

```haskell
tableLockFunc :: Text -> Text
tableLockFunc tableName = "LOCK " <> tableName <> " IN EXCLUSIVE MODE"
```

Before inserting events, the writer takes an exclusive lock on the events table. This serializes all inserts: only one transaction can write at a time, so auto-increment IDs are always assigned and committed in order, and readers never see gaps.

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

The `mLockCommand` parameter is a `Maybe (Text -> Text)`: present for PostgreSQL, absent for SQLite. The function takes a table name and returns the lock SQL. This keeps the locking strategy out of the shared write logic.

The PostgreSQL writer passes `Just tableLockFunc`:

```haskell
postgresqlEventStoreWriter config = EventStoreWriter $ transactionalExpectedWriteHelper getLatestVersion storeEvents'
  where
    getLatestVersion = sqlMaxEventVersion config maxPostgresVersionSql
    storeEvents' = sqlStoreEvents config (Just tableLockFunc) maxPostgresVersionSql
```

The tradeoff is a serialization bottleneck on writes. Every event write goes through a single lock. For most event-sourced systems that's acceptable. Event writes are small and fast (a few rows of JSON), and the lock is held only during the insert, not the whole command processing cycle. The read-decide phase happens before the lock is taken.

### SQLite: single-writer by design

SQLite doesn't need explicit locking:

```haskell
sqliteEventStoreWriter config = EventStoreWriter $ transactionalExpectedWriteHelper getLatestVersion storeEvents'
  where
    getLatestVersion = sqlMaxEventVersion config maxSqliteVersionSql
    storeEvents' = sqlStoreEvents config Nothing maxSqliteVersionSql
```

The lock command is `Nothing` because SQLite's write model is already serialized. Only one transaction can write at a time, so you get gap-free sequences for free.

The tradeoff: no write concurrency at all. That's fine for single-process systems, development, testing, or production deployments with low write volume. If you need concurrent writers, use PostgreSQL.

### The abstraction

Both backends expose the same `EventStoreWriter` interface. The gap-free guarantee is a property of the backend, not the abstraction. Application code (command handlers, process managers, read models) doesn't know or care which strategy is in use. You pick the backend at the application boundary:

```haskell
-- PostgreSQL
writer = postgresqlEventStoreWriter config

-- SQLite
writer = sqliteEventStoreWriter config
```

Same type, same interface, different concurrency properties.

## Optimistic concurrency without locks

Two command handlers read the same aggregate at version 5. Both run their business logic against that state. Both decide to write. If both succeed, the event stream is corrupted: it now holds events that were each validated against the same state, not against each other.

You need concurrency control. Pessimistic locking (lock the aggregate before reading and hold the lock through the whole read-decide-write cycle) works but kills throughput. The lock duration includes business logic, which could be arbitrarily slow.

Eventium uses optimistic concurrency instead, through `ExpectedPosition`:

```haskell
data ExpectedPosition position
  = AnyPosition
  | NoStream
  | StreamExists
  | ExactPosition position
```

The command handler captures the stream's current version when it reads events, then asserts that the version hasn't changed when it writes:

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

There are three phases: read (replay events, capture version), decide (pure business logic), and write (assert version, store events). No lock is held during the decide phase. If another writer changed the stream between the read and the write, the version check fails and the write is rejected with `ConcurrencyConflict`.

At the SQL level, `transactionalExpectedWriteHelper` implements the check:

```haskell
transactionalExpectedWriteHelper' (Just f) getLatestVersion' storeEvents' uuid events = do
  latestVersion <- getLatestVersion' uuid
  if f latestVersion
    then storeEvents' uuid events <&> Right
    else return $ Left $ EventStreamNotAtExpectedVersion latestVersion
```

Read the current version, check it against the expected position, then write or reject. It all runs in one database transaction, so the check-then-write is atomic.

The error type makes the two failure modes explicit:

```haskell
data CommandHandlerError err
  = CommandRejected err
  | ConcurrencyConflict (EventWriteError EventVersion)
```

Domain rejection (`InsufficientFunds`, `AccountNotOpen`) and infrastructure conflict (version mismatch) are different types with different handling strategies. The compiler makes sure you handle both.

No retries are built in, on purpose. Retry strategy depends on the domain. Some commands are safe to retry (idempotent reads), others aren't (non-idempotent transfers). The caller decides.

## Records, not typeclasses

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

With typeclasses, each monad gets one instance. If you want an in-memory store and a PostgreSQL store, you need different monads, or `newtype` wrappers with `GeneralizedNewtypeDeriving`, which add boilerplate without adding clarity. Worse, if two store implementations exist for the same monad, you have an orphan instance problem.

With records, stores are values. You can have two different PostgreSQL writers in the same program, one for the main events table and one for an archive table, and pass them wherever they're needed. No typeclass resolution, no orphan instances, no ambiguity.

This also makes composition easy. `runEventStoreReaderUsing` lifts a reader from one monad to another:

```haskell
runEventStoreReaderUsing ::
  (forall a. mstore a -> m a) ->
  EventStoreReader key position mstore event ->
  EventStoreReader key position m event
runEventStoreReaderUsing runStore (EventStoreReader f) = EventStoreReader (runStore . f)
```

It takes a natural transformation (`mstore ~> m`) and produces a new reader. With typeclasses, you'd need `MonadTrans` stacks or `lift` calls scattered through your code. With records, it's one function application at the boundary.

The same pattern applies to codec wrapping. `EventStoreWriter` has a `Contravariant` instance:

```haskell
instance Contravariant (EventStoreWriter key position m) where
  contramap f (EventStoreWriter writer) =
    EventStoreWriter $ \key expectedPos -> writer key expectedPos . fmap f
```

So you can change what a writer accepts with `contramap codec.encode`, turning a writer that stores serialized values into one that accepts domain events. No new type, no new instance, just function composition on a value.

The tradeoff: you lose automatic dispatch. With typeclasses, the compiler picks the implementation based on the type. With records, you pass the implementation explicitly. In practice this is a feature: you want to see event store configuration at the call site, not have the compiler resolve it invisibly.

The same reasoning applies to `Codec` (instead of a `Serializable` typeclass), `ProjectionCache`, `CheckpointStore`, and `CommandDispatcher`. All are records, and all compose as values.

## Metadata as a pipeline

Events need infrastructure metadata: timestamps, event type names, correlation and causation IDs for distributed tracing. But domain event types shouldn't carry infrastructure concerns. `AccountOpened` describes what happened in the business domain. When it happened, which type name to use for serialization routing, and which request triggered it are infrastructure questions.

Eventium keeps the two apart. Metadata lives on `StreamEvent`, not on the domain event:

```haskell
data EventMetadata = EventMetadata
  { eventType :: !Text,
    correlationId :: !(Maybe UUID),
    causationId :: !(Maybe UUID),
    createdAt :: !(Maybe UTCTime),
    occurredAt :: !(Maybe UTCTime)
  }
```

`eventType` is derived automatically from the Haskell type via `Typeable`, so there's no manual string registration. `createdAt` is the wall-clock time at write. `occurredAt` is optional, for backdated events (importing historical data, for example). Correlation and causation IDs support distributed tracing across aggregates.

The pipeline is built around `MetadataEnricher`:

```haskell
type MetadataEnricher = EventMetadata -> EventMetadata
```

It's just a function. Compose enrichers with `.`, and use `id` when you don't need enrichment:

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

For each event, it builds base metadata (type name from `Typeable`, current timestamp), applies the enricher, encodes the event with the codec, wraps both in a `TaggedEvent`, and writes. Domain events go in, tagged serialized events come out.

The enricher flows through the entire command pipeline. `CommandDispatcher` carries it, and so does `ProcessManagerEffect`, so process managers can pass correlation IDs from triggering events to the commands they issue. A transfer started on account A generates events on account B, and the correlation ID threads through the whole flow.

The tradeoff: enrichers are functions, not data. You can't inspect or serialize them. That's fine because they're short-lived, applied once at write time and discarded. But you can't log "what enrichment was applied" unless the enricher does the logging itself.

## Snapshotting aggregate state

Projections replay every event from the start of a stream to rebuild current state. For an aggregate with ten events, that's trivial. For one with ten thousand, every command pays for replaying the whole history before `decide` can even run.

Eventium handles this with `ProjectionCache`:

```haskell
data ProjectionCache key position encoded m
  = ProjectionCache
  { storeSnapshot :: key -> position -> encoded -> m (),
    loadSnapshot :: key -> m (Maybe (position, encoded))
  }
```

It's a key-value store that knows about stream position. Store the projected state at a given version, then load it later and replay only the events since that version.

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

On read, it loads cached state at version N, fetches only events from N+1 onward, and folds those onto the cached state. On a successful write, it computes the new state by folding the just-written events and updates the cache.

Cache invalidation is simple because event streams are append-only. A cached state at version N is always valid, since the events that produced it can never change. You only ever replay forward, so the usual cache invalidation problem doesn't come up.

The tradeoff is less obvious: snapshotting requires a serialization instance for your aggregate state. Domain events already need codecs for persistence, but aggregate state is normally short-lived and exists only in memory during command processing. Once you persist it, changes to the state's shape (adding a field, changing a type) need either a cache migration or a full wipe-and-rebuild.

Not every aggregate needs snapshots. If your streams are short-lived (tens of events, maybe a few hundred), the replay cost is small. Snapshotting pays off for long-lived aggregates with high command throughput, where replaying thousands of events per command becomes a bottleneck.

## Read models: in-memory vs persisted

Not every read model needs a database. Some views are small enough to live entirely in memory, like a running counter or a set of active transfer IDs. Others need to survive process restarts and serve queries from external clients. The same abstraction should support both without forcing one approach.

This is where the monad parameter on `ReadModel` pays off:

```haskell
data ReadModel m event = ReadModel
  { initialize :: m (),
    eventHandler :: EventHandler m (GlobalStreamEvent event),
    checkpointStore :: CheckpointStore m SequenceNumber,
    reset :: m ()
  }
```

The type is parametric over `m`. Each of the four fields has a clear lifecycle role: `initialize` sets up storage (run migrations, create tables), `eventHandler` processes events from the global stream, `checkpointStore` tracks the last consumed position, and `reset` wipes everything for rebuilds.

Persisted read models use SQL:

```haskell
transferReadModel :: ReadModel (SqlPersistT IO) BankEvent
transferReadModel = ReadModel
  { initialize = void $ runMigrationSilent migrateTransfer,
    eventHandler = EventHandler handleTransferEvent,
    checkpointStore = sqliteCheckpointStore (CheckpointName "transfers"),
    reset = deleteWhere ([] :: [Filter TransferEntity])
  }
```

This one is backed by SQLite or PostgreSQL and survives restarts: the checkpoint persists in the database, so on restart the read model picks up where it left off. Other processes can query it with SQL.

In-memory read models use STM:

```haskell
counterReadModel :: TVar Int -> ReadModel IO CounterEvent
counterReadModel tvar = ReadModel
  { initialize = pure (),
    eventHandler = EventHandler $ \event -> atomically $ modifyTVar' tvar (applyEvent event),
    checkpointStore = memoryCheckpointStore checkpointTVar,
    reset = atomically $ writeTVar tvar 0
  }
```

This one is backed by a `TVar`. Initialization is a no-op, and reset writes the initial value. It's fast and has no serialization overhead, but it's lost on restart, so on startup the read model replays from the beginning of the event log.

Which to use: in-memory for derived state that's cheap to rebuild and only used in-process (caches, dashboard counters, internal lookups). Persisted for views that external clients query or that would be expensive to rebuild from scratch (large event histories).

The `ReadModel` type doesn't care. Same four fields, same interface. You make the choice at construction time, and it isn't baked into the abstraction.

## Resilient event consumption

Read models consume the global event stream continuously. The simple approach (poll, process, checkpoint) works until something goes wrong. A temporary database error shouldn't permanently kill your read model. But naive retry, immediately and forever, can overload a recovering database.

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

If the process crashes after handling events but before saving the checkpoint, those events get reprocessed on restart. This is at-least-once delivery, so event handlers must be idempotent. Eventium doesn't try to provide exactly-once semantics, because doing that reliably across arbitrary storage backends is a distributed systems problem that doesn't belong in a library.

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

Call `reset` (drop all data), then `initialize` (re-run migrations), then replay in batches until there are no more events. This is useful when you've changed the projection logic and need to regenerate the view.

### Resilient subscriptions

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

The `unlift` parameter (`forall a. m a -> IO a`) converts monadic actions to `IO` for exception handling. It's the same pattern as `runEventStoreReaderUsing`: a natural transformation that lets you work across monad boundaries.

On success, the consecutive error count resets to zero. On failure, it goes up and the delay grows: `min maxDelay (initialDelay * multiplier ^ (count - 1))`. The `onError` predicate lets the caller separate temporary failures (retry) from fatal ones (re-throw). The `onErrorCallback` is for logging.

The defaults are a 1-second initial delay, a 30-second cap, and a 2x multiplier:

```haskell
defaultRetryConfig = RetryConfig
  { initialDelayMs = 1000,
    maxDelayMs = 30000,
    backoffMultiplier = 2.0,
    onError = const (return True),
    onErrorCallback = \_ _ -> return ()
  }
```

The tradeoff with polling: the delay between an event write and the read model update is bounded by the poll interval. For most CQRS systems that's acceptable, since read models are eventually consistent by design. If you need sub-second latency, you'd need a push-based mechanism, which eventium doesn't currently provide.

## Codec vs TypeEmbedding: same shape, different semantics

Events need two kinds of conversion. Serialization turns domain events into JSON for storage and back. Type embedding fits aggregate-level events (`AccountEvent`) into application-wide sum types (`BankEvent`) and back. Both have the same shape, a total function one way and a partial function back:

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

`Codec` is for the wire boundary. It carries serialization concerns: event type names, JSON encoding, `DecodeError` exceptions. `metadataEnrichingEventStoreWriter` uses it to encode domain events before storage. Going through a codec means data crosses a serialization boundary: in-memory Haskell values become JSON, and JSON becomes Haskell values (or `Nothing` on decode failure).

`TypeEmbedding` is for the type hierarchy, with no serialization involved. It says "AccountEvent is a subset of BankEvent": every `AccountEvent` can be embedded into `BankEvent`, and some `BankEvent` values can be extracted back as `AccountEvent`. `embeddedCommandHandler` and `embeddedProjection` use it to lift aggregate-level handlers to work with application-wide types.

Keeping them separate prevents accidental misuse. Using a `Codec` where you meant a `TypeEmbedding` would serialize and deserialize events that are already in memory, which is wasted work and possibly lossy if the codec doesn't round-trip perfectly. Using a `TypeEmbedding` where you meant a `Codec` would skip serialization entirely and pass raw Haskell values to a store that expects JSON. With two distinct types, the compiler catches both mistakes.

`embeddingToCodec` is an escape hatch for when you really need to cross the boundary:

```haskell
embeddingToCodec :: TypeEmbedding a b -> Codec a b
embeddingToCodec (TypeEmbedding e x) = Codec e x
```

Both types are values, not typeclasses. You can have multiple codecs for the same type (different JSON formats for migration), multiple embeddings (different application-wide sum types for different contexts), and no orphan instance problems. Template Haskell generates both, `mkSumTypeCodec` for wire codecs and `mkSumTypeEmbedding` for type hierarchy embeddings, by matching constructors on inner type.

## Wrapping up

Each of these decisions is a tradeoff made explicit. Single table vs dual tables: simplicity over optimal read performance. Exclusive locks vs single-writer: PostgreSQL serializes writes; SQLite doesn't need to. Optimistic vs pessimistic concurrency: no locks held during business logic, conflicts detected on write. At-least-once vs exactly-once: handlers must be idempotent, but the library doesn't pretend to solve distributed exactly-once delivery.

Eventium picks a side on each of these and makes the choice visible in the types and the API instead of hiding it behind "smart" defaults. `ExpectedPosition` is a value you construct, not a flag buried in configuration. `MetadataEnricher` is a function you compose, not a magic annotation. `ProjectionCache` is a record you pass in, not an implicit layer. When something goes wrong, you can see exactly what was configured and why.

The [previous post](@/blog/2026-04-eventium-event-sourcing-library-for-haskell.md) covers the user-facing side: projections, command handlers, process managers, read models. The library is at [aleks-sidorenko/eventium](https://github.com/aleks-sidorenko/eventium). Feedback and contributions are welcome.
