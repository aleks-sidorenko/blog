+++
title = "Haskell for Scala Developers: Part 3 — Effects and Concurrency"
date = 2026-06-17
description = "For working Scala developers picking up Haskell: IO and referential transparency, the Future critique, error handling as an effect, Resource/bracket, Ref and STM, structured concurrency, and ZIO's R/E/A versus Haskell's MTL and effect-handler libraries."
path = "blog/2026/06/haskell-for-scala-devs-03-effects"
[taxonomies]
tags = ["haskell", "scala", "functional-programming", "haskell-for-scala-devs"]
categories = ["programming"]
+++

`IO` is a `Monad` in both Scala and Haskell, and `do { line <- getLine; putStrLn line }` is the same shape as `for { line <- IO.readLine; _ <- IO.println(line) } yield ()`. That equivalence is where this post starts — with the part of the language that made half the Scala community pick up Cats Effect in the first place.

Here's the thesis, stated plainly: **Cats Effect's `IO` is Haskell's `IO`, ported to the JVM.** Not "inspired by." Ported. The referential transparency, the lazy description-of-a-computation, the run-it-at-the-edge model, `bracket`, `Ref`, `race`, fibers — all of it is the Haskell `IO` programming model rebuilt on a runtime that wasn't designed for it. Once you delete `Future` from your mental model, the distance between a Cats Effect program and the equivalent Haskell program is mostly tooling and syntax.

ZIO is the one place that story gets more interesting, and it's why I asked to cover both. ZIO's `ZIO[R, E, A]` is a genuinely different bet — it folds the environment and the error type into the effect type itself. Haskell makes that same bet too, but it spreads the pieces across different tools: `ReaderT` for the `R`, `ExceptT` or plain exceptions for the `E`, and increasingly an effect-handler library (`effectful`, `polysemy`, `fused-effects`) when you want the whole thing in one place. Same problem, different decomposition, real trade-offs on both sides.

The map: why `Future` is the thing to delete, what `IO`-as-a-value buys you, how errors become just another effect, resource safety, shared state, structured concurrency with a worked example, and finally ZIO against Haskell's MTL. The one neighbor I'm leaving for its own post is streaming — fs2 and ZIO Streams against `conduit` and `streamly` is a comparison that deserves the room.

<!-- more -->

## The thing Future got wrong

`Future` is eager. The moment you construct one, it starts running on some thread pool. That single design decision is the reason `Future` is not referentially transparent, and referential transparency is the entire pitch for `IO`.

Referential transparency means you can replace a name with its definition and the program behaves identically. It's the property that lets you refactor without fear — pull a repeated expression into a `val`, inline a `val` back to its use sites, and nothing changes. `Future` breaks it. Watch:

```scala
val f = Future { println("running"); 42 }
val a = Await.result(f, 1.second)
val b = Await.result(f, 1.second)
println(s"sum = ${a + b}")
```

```
running
sum = 84
```

The body runs once. The `Future` started executing when it was constructed, and the result is memoized, so the two `Await`s observe the same completed value. Now inline `f` — replace the name with its definition at both use sites, which referential transparency promises is a safe edit:

```scala
val a = Await.result(Future { println("running"); 42 }, 1.second)
val b = Await.result(Future { println("running"); 42 }, 1.second)
println(s"sum = ${a + b}")
```

```
running
running
sum = 84
```

Two `running`s. The "obviously safe" refactor changed the observable behavior of the program. A `Future` is not a description of work to be done; it's work that is already happening, wearing the costume of a value. You cannot reason about it equationally, you cannot retry it by re-running it, and you cannot pass it around as a plain value without smuggling its execution along with it.

`Future` is fine for what the standard library needed it for — fire off some async work, get a handle, `await` it once. It's the right tool for a great many small jobs and it ships in the box. But it is the wrong foundation for a program built out of composable effects, and that is precisely the gap Cats Effect and ZIO exist to fill. They give you back the thing `Future` traded away.

## IO is a value

`IO[A]` is a description of a computation that, when run, produces an `A` (or fails, or runs forever). Constructing it does nothing. It's an immutable value like any other — you build big ones out of small ones, pass them around, store them in a `Map`, and none of that executes a single line until you hand the finished description to a runtime at the edge of your program.

Here's a small Cats Effect program, and the thing that gives Scala developers pause the first time they see it:

```scala
object IoValue extends IOApp.Simple:
  // Constructed but never run — produces no output.
  val unused: IO[Unit] = IO.println("this is never printed")

  val program: IO[Int] =
    for
      _ <- IO.println("step 1")
      n <- IO.pure(42)
      _ <- IO.println(s"step 2: got $n")
    yield n

  def run: IO[Unit] =
    program.flatMap(result => IO.println(s"result = $result"))
```

```
step 1
step 2: got 42
result = 42
```

`unused` is a perfectly good `IO[Unit]` that says "print this line." It never prints, because nothing ever runs it. That's not a quirk; that's the whole model. The Haskell version is the same program, and behaves identically:

```haskell
program :: IO Int
program = do
  putStrLn "step 1"
  let n = 42
  putStrLn ("step 2: got " ++ show n)
  pure n

main :: IO ()
main = do
  -- Bound but never sequenced — produces no output.
  let unused = putStrLn "this is never printed"
  result <- program
  putStrLn ("result = " ++ show result)
```

```
step 1
step 2: got 42
result = 42
```

`let unused = putStrLn "..."` binds a name to an `IO ()` value and the line never prints, for exactly the reason the Scala line never prints. The two programs are structurally the same: a sequence of effects composed with `for` / `do`, bound names where you need an intermediate value, run at one well-defined point.

Two things to notice. First, `IO` is just another `Monad`. The `for`-comprehension and the `do`-block you already understand for `Option` and `Either` are the same `for` and `do` here. There's no new control-flow construct to learn; `IO` slots into the abstraction you already have. Cats Effect's `IO` is a lawful `Monad` (and `MonadCancel`, and a dozen other things), and that's why `for` works over it. Haskell's `IO` is a `Monad`, and that's why `do` works over it. Same machinery, all the way down.

Second, the running. A Haskell program *is* a value of type `IO ()` named `main` — the runtime system takes that description and executes it. There is no `unsafeRunSync` sprinkled through your code; the only "run" is the one the runtime does to `main`. Cats Effect gives you `IOApp` for exactly this discipline: your `run` returns an `IO`, the framework executes it once at the true edge. You *can* call `unsafeRunSync()` in Cats Effect — the word `unsafe` is the library telling you that you've left the description world and you'd better have a good reason. Haskell doesn't even offer the equivalent in normal code; the edge is `main` and that's that.

This is the property the type system is protecting, and it's the subject of an [earlier post on why Haskell's effect tracking matters](@/blog/2026-04-haskell-was-waiting-for-this.md): a function whose type is `Int -> Int` *cannot* touch the world. No logging, no clock, no database, no surprise. If it touches the world, its type says `IO` and you can see it at the call site. Cats Effect recreates this discipline by convention and by wrapping every effect in `IO`; Haskell enforces it because there is no other way to perform an effect. The discipline is the same. In one language it's a library asking nicely, and in the other it's the only door in the building.

## Errors are an effect (the Try story)

Scala's `Try[A]` doesn't translate to Haskell one-to-one, because exceptions are an effect, and Haskell tracks effects in the type. Here's what that means in practice.

In Scala you have a few overlapping tools for "this might throw": `Try[A]`, `Either[Throwable, A]`, and — once you're in an effect type — `IO`'s own error channel. Cats Effect's `IO` carries failure the same way Haskell's `IO` does: the effect can fail with a `Throwable`, and you have combinators to observe and recover. `attempt` reifies a possible failure into a value, and `handleErrorWith` recovers with a fallback effect:

```scala
val boom: IO[Int] = IO.raiseError(new RuntimeException("boom"))

def run: IO[Unit] =
  for
    // attempt: turn failure into a value -> IO[Either[Throwable, Int]]
    e <- boom.attempt
    _ <- IO.println(s"attempt: $e")
    // handleErrorWith: recover with a fallback effect
    n <- boom.handleErrorWith(_ => IO.pure(-1))
    _ <- IO.println(s"handleErrorWith: $n")
  yield ()
```

```
attempt: Left(java.lang.RuntimeException: boom)
handleErrorWith: -1
```

Haskell's `IO` works the same way, with the same two moves. `try` reifies a failure into `IO (Either SomeException a)` — which is exactly `Try`, spelled as the thing it always was — and `handle` (the argument-flipped `catch`) recovers with a fallback effect:

```haskell
{-# LANGUAGE ScopedTypeVariables #-}

boom :: IO Int
boom = throwIO (userError "boom")

main :: IO ()
main = do
  -- try: turn failure into a value -> IO (Either SomeException Int)
  e <- try boom :: IO (Either SomeException Int)
  putStrLn ("try: " ++ show e)
  -- handle: recover with a fallback effect
  n <- handle (\(_ :: SomeException) -> pure (-1)) boom
  putStrLn ("handle: " ++ show n)
```

```
try: Left user error (boom)
handle: -1
```

There it is. `try boom :: IO (Either SomeException Int)` is `Try` — it's the type `IO (Either SomeException a)`, produced on demand by a combinator rather than handed to you as a separate wrapper type. The reason Haskell doesn't ship a standalone `Try` is that it doesn't need one: the catch-and-recover combinators live on `IO` itself, because throwing is an effect and effects live in `IO`. You don't wrap a maybe-throwing computation in a new type; you run it in the effect type that already models "this interacts with a world where things go wrong."

The honest mechanics, briefly. `throwIO` raises an exception inside `IO` with a guaranteed ordering relative to other effects. `try` runs an action and hands you `Left e` on failure or `Right a` on success. `catch` and `handle` run an action and, on a matching exception, run your handler instead. The `MonadThrow` / `MonadCatch` classes (from the `exceptions` package, and re-exported all over the ecosystem) generalize `throwIO` / `catch` so the same code works in `IO` or in a monad transformer stack on top of it — the same way Cats Effect's `MonadError` / `ApplicativeError` generalize `raiseError` / `handleErrorWith`. The vocabularies line up almost word for word: `raiseError`/`throwIO`, `attempt`/`try`, `handleErrorWith`/`handle`, `MonadError`/`MonadThrow`.

What this post deliberately won't relitigate is the typed-versus-untyped-errors debate. `IO`'s error channel in both languages is untyped (a `Throwable`, a `SomeException`) — you find out what can go wrong by reading, not by checking a type. The typed-error story is real and it's where ZIO's `E` and Haskell's `ExceptT` come in; we get to it at the end of the post. For the mechanical translation of "I have a thing that throws," the answer is: it's an `IO`, and you `try` it.

## Resources: bracket and Resource

Acquire something, use it, release it — and release it even if the use blows up or gets cancelled. Every language has a version of this; Java has try-with-resources, Scala has `Using`. In effectful code the primitive is `bracket`, and Cats Effect and Haskell spell it almost identically.

Cats Effect gives you two front-ends to the same idea. `Resource` is the composable, value-level one — you build a `Resource[IO, A]` and `use` it:

```scala
val resource: Resource[IO, Int] =
  Resource.make(IO.println("acquire").as(42))(_ => IO.println("release"))

def run: IO[Unit] =
  for
    _ <- resource.use(h => IO.println(s"use handle=$h"))
    _ <- IO.println("---")
    r <- resource.use(_ => IO.raiseError(new RuntimeException("boom"))).attempt
    _ <- IO.println(s"result=$r")
  yield ()
```

```
acquire
use handle=42
release
---
acquire
release
result=Left(java.lang.RuntimeException: boom)
```

The second `use` raises mid-flight, and `release` still runs before the error propagates. That's the guarantee. Haskell's `bracket` from `Control.Exception` is the same three arguments — acquire, release, use — with the same promise that release runs on both the normal and the exceptional path:

```haskell
acquire :: IO Int
acquire = putStrLn "acquire" >> pure 42

release :: Int -> IO ()
release _ = putStrLn "release"

main :: IO ()
main = do
  bracket acquire release (\h -> putStrLn ("use handle=" ++ show h))
  putStrLn "---"
  r <- try (bracket acquire release (\_ -> ioError (userError "boom")))
         :: IO (Either SomeException ())
  putStrLn ("result=" ++ show r)
```

```
acquire
use handle=42
release
---
acquire
release
result=Left user error (boom)
```

Line for line, the same program. `bracket acquire release use` is `Resource.make(acquire)(release).use(use)` with the arguments in a different order. The acquire/use/release triple is identical because the problem is identical; the only difference is how many spellings each ecosystem ships. Cats Effect offers `bracket`, `bracketCase` (the release sees *how* the use finished — completed, errored, or cancelled), and the `Resource` data type for when you want to compose a dozen of these and thread them through your program as one value. Haskell offers `bracket`, `bracketOnError`, `finally`, `onException` in `base`, and the `resourcet` / `managed` packages when you want the composable, `Resource`-shaped version. ZIO has its own twin — `ZIO.acquireRelease` and the `Scope` type — built on the same bones.

The thing worth internalizing: cancellation is part of this story in both ecosystems. A `Resource`/`bracket` release runs when the surrounding fiber is cancelled, not just when it errors or completes. That's what makes the next section's "cancel the rest on first failure" safe — the resources held by the cancelled work get cleaned up.

## Shared state: Ref, IORef, and STM

Mutable state in an effect system isn't a field you assign; it's a value you allocate and then read and write through effects. The simplest is a mutable cell. Cats Effect calls it `Ref`; Haskell calls it `IORef`. Here's a shared counter incremented a thousand times concurrently, which must total exactly 1000:

```scala
def run: IO[Unit] =
  for
    counter <- Ref.of[IO, Int](0)
    _       <- (1 to 1000).toList.parTraverse(_ => counter.update(_ + 1))
    total   <- counter.get
    _       <- IO.println(s"total=$total")
  yield ()
```

```
total=1000
```

```haskell
main :: IO ()
main = do
  counter <- newIORef (0 :: Int)
  mapConcurrently (\_ -> atomicModifyIORef' counter (\n -> (n + 1, ()))) [1..1000]
  total <- readIORef counter
  putStrLn ("total=" ++ show total)
```

```
total=1000
```

`Ref.update` is atomic; so is `atomicModifyIORef'` (the strict, atomic variant — plain `modifyIORef` would race, and the prime keeps the strictness so you don't build up a tower of unevaluated increments). ZIO's `Ref` is the same thing under a third name. For a single cell, atomic update is all you need.

The interesting one is `STM` — software transactional memory. When you need to update *several* cells together, atomically, with no locks and no possibility of observing a half-finished state, you reach for transactions. Haskell's version is the original, and it's genuinely lovely:

```haskell
main :: IO ()
main = do
  counter <- newTVarIO (0 :: Int)
  mapConcurrently (\_ -> atomically (modifyTVar' counter (+ 1))) [1..1000]
  total <- readTVarIO counter
  putStrLn ("total=" ++ show total)
```

```
total=1000
```

A `TVar` is a transactional variable. Anything you do inside `atomically` is one transaction — it either commits as a unit or retries from the top, and the type system stops you from doing `IO` inside a transaction (you can't `putStrLn` in there, because that couldn't be rolled back). The `STM` monad also gives you `retry` (block until some `TVar` you read changes, then try again) and `orElse` (attempt one transaction, fall back to another) — the building blocks for queues, semaphores, and every other concurrency structure, composed transactionally instead of with hand-rolled locks. The counter above doesn't need `retry`/`orElse`; a real bounded queue does.

Here's the honest framing of the comparison, because it's easy to oversell. Haskell's `STM` lives in the `stm` package, the `STM` monad is part of the standard toolbox, and — this is the real point — the GHC runtime was built with transactional memory in mind. Cats Effect has an `STM` now, and ZIO has `ZSTM`; they're good, and they give you the same `atomically` / `retry` / `orElse` shape. The difference isn't that the JVM "can't" do STM — it plainly does. It's that on the JVM, STM is a library riding on a runtime that was designed for locks and threads, while in Haskell it's a feature the runtime was designed to support. Same idea, different provenance, and in practice the Haskell version has had thirty years to become the default answer rather than an advanced option. (The deeper "mutation is an effect, not a default" framing — and what that does to the OOP habits you bring from Scala — is a topic of its own.)

## Concurrency: fibers, async, race, timeout

Now the payoff. Both ecosystems give you lightweight concurrency — green threads, scheduled by the runtime, cheap enough to spawn millions of — plus a set of combinators for running things in parallel, racing them, and timing them out. The names differ; the model is the same.

A *fiber* in Cats Effect is a `forkIO`-d thread in Haskell or an `async` in the `async` package. You `start` a fiber and `join` it (Cats Effect), or `async` an action and `wait` for it (Haskell). You rarely write that by hand, though, because the high-level combinators cover most needs. The two you'll reach for constantly:

`race` runs two effects concurrently, returns whichever finishes first, and cancels the loser. `timeout` runs an effect with a deadline. Here they are:

```scala
val slow: IO[String] = IO.sleep(200.millis) *> IO.pure("slow")
val fast: IO[String] = IO.sleep(50.millis)  *> IO.pure("fast")

for
  winner <- IO.race(slow, fast)              // faster wins, loser cancelled
  _      <- IO.println(s"race winner: $winner")
  result <- slow.timeout(100.millis).attempt // deadline -> raises TimeoutException
  _      <- result match
              case Right(v)                  => IO.println(s"timeout: got $v")
              case Left(_: TimeoutException)  => IO.println("timeout: timed out")
              case Left(e)                    => IO.raiseError(e)
yield ()
```

```
race winner: Right(fast)
timeout: timed out
```

```haskell
slow :: IO String
slow = threadDelay 200000 >> pure "slow"   -- 200ms

fast :: IO String
fast = threadDelay 50000  >> pure "fast"   -- 50ms

main :: IO ()
main = do
  winner <- race slow fast                 -- faster wins, loser cancelled
  putStrLn ("race winner: " ++ show winner)
  result <- timeout 100000 slow            -- microseconds! deadline -> Nothing
  case result of
    Just v  -> putStrLn ("timeout: got " ++ v)
    Nothing -> putStrLn "timeout: timed out"
```

```
race winner: Right "fast"
timeout: timed out
```

`IO.race` and `Control.Concurrent.Async.race` are the same primitive, down to returning an `Either` that tells you which side won. There's one genuine difference, and it's worth flagging because it bites: **`timeout` means slightly different things in the two libraries.** Cats Effect's `.timeout` *raises* a `TimeoutException` when the deadline passes — a timeout is a failure, and it propagates like one. Haskell's `System.Timeout.timeout` *returns* `Maybe a` — `Nothing` on expiry — so a timeout is a value you pattern-match, not an exception that unwinds. Neither is wrong; they're different choices about whether "we ran out of time" is exceptional. If you want Haskell's `timeout` to behave like Cats Effect's — raise and propagate — you build it from `race`: race the action against a `threadDelay` that throws. That's exactly the construct, and it matters for the anchor below.

The anchor for this post is a concurrent fetcher: fetch a list of URLs in parallel, with a per-call timeout, and cancel the in-flight fetches the moment one fails. (The `fetch` here is simulated — a `sleep` and a canned response — so the example is deterministic and the snippet actually runs. Swapping in a real HTTP client, `http4s`/`sttp` on the Scala side or `http-client`/`req` on the Haskell side, changes none of the concurrency structure.)

```scala
def fetch(url: String): IO[String] =
  if url.endsWith("/bad") then
    IO.raiseError(new RuntimeException(s"failed to fetch $url"))
  else
    IO.sleep(100.millis) *> IO.pure(s"<body of $url>")

def fetchAll(urls: List[String]): IO[List[String]] =
  urls.parTraverse(url => fetch(url).timeout(2.seconds))
```

```haskell
fetch :: String -> IO String
fetch url
  | "/bad" `isSuffixOf` url = throwIO (ErrorCall ("failed to fetch " ++ url))
  | otherwise               = threadDelay 100000 >> pure ("<body of " ++ url ++ ">")

fetchAll :: [String] -> IO [String]
fetchAll urls = map orFail <$> mapConcurrently (\u -> timeout 2000000 (fetch u)) urls
  where orFail = maybe "<timed out>" id
```

`parTraverse` (Cats Effect) and `mapConcurrently` (Haskell's `async`) are the same combinator: map an effectful function over a list, run all the effects concurrently, collect the results. And both give you cancel-on-first-failure *for free* — that's the structured-concurrency guarantee. When one `fetch` throws, the combinator cancels every sibling that's still in flight and re-raises the error. I verified this in both languages by giving the slow fetches an observable cancellation hook and putting a `/bad` URL in the batch; both printed the cancellations as the siblings were torn down, then surfaced the failure. You don't write the cancellation logic. The combinator owns it, the same way it owns it in Cats Effect.

The timeout difference from above shows up right here, and the snippets are honest about it. Cats Effect's `.timeout(2.seconds)` raises on expiry, so a timed-out fetch behaves like a failed fetch — it aborts the whole `parTraverse` and cancels the siblings. Haskell's `timeout 2000000` returns `Nothing`, which the code maps to `"<timed out>"`, so a slow fetch is absorbed and the batch carries on. If you want the Haskell version to abort-on-timeout like Cats Effect, you swap `System.Timeout.timeout` for a `race` against a throwing delay, and the two behave identically again. Same primitives, one decision made differently, fixable in one line once you know it's there.

ZIO covers all of this with the same shapes under its own names: `ZIO.foreachPar` for the concurrent map, `race`, and `timeout` (which returns an `Option`, like Haskell, rather than raising). If you've internalized the Cats Effect or Haskell versions, the ZIO ones read on sight — which is a good segue, because ZIO is where the comparison stops being a vocabulary exercise.

## ZIO's R/E/A, and how Haskell spells it

Everything so far has had Cats Effect's `IO[A]` and Haskell's `IO a` as near-perfect mirrors. ZIO breaks the symmetry on purpose. Its effect type is `ZIO[R, E, A]`: an effect that needs an environment `R`, may fail with a typed error `E`, and succeeds with an `A`. Three type parameters instead of one, and the extra two encode things that Cats Effect leaves to convention and Haskell leaves to other tools.

Here's a small ZIO program that exercises all three. It needs a `Config` service (`R`), can fail with a typed `AppError` (`E`), and produces an `Int` (`A`):

```scala
trait Config:
  def lookup(key: String): UIO[Option[String]]

object Config:
  val live: ULayer[Config] = ZLayer.succeed:
    new Config:
      private val data = Map("port" -> "8080")
      def lookup(key: String): UIO[Option[String]] = ZIO.succeed(data.get(key))

sealed trait AppError
case class MissingKey(key: String) extends AppError

def getPort: ZIO[Config, AppError, Int] =
  for
    raw  <- ZIO.serviceWithZIO[Config](_.lookup("port"))
    port <- raw match
              case Some(v) => ZIO.succeed(v.toInt)
              case None    => ZIO.fail(MissingKey("port"))
  yield port

object ZioRea extends ZIOAppDefault:
  val run =
    getPort
      .provide(Config.live)
      .foldZIO(
        err  => Console.printLine(s"error: $err"),
        port => Console.printLine(s"port = $port"),
      )
```

```
port = 8080
```

Read the type `ZIO[Config, AppError, Int]` and you know three things without reading the body: it requires a `Config` to run, the only way it can fail is an `AppError`, and on success you get an `Int`. `ZIO.serviceWithZIO[Config]` reaches into the environment; `.provide(Config.live)` supplies it and the requirement disappears from the type; `ZIO.fail` produces a typed error; `foldZIO` handles both channels. That's real expressive power, and ZIO's inference is tuned to make it feel natural. Dependency injection and typed errors, both in the effect type, both checked by the compiler. It's a coherent and defensible design, and for a lot of teams it's the reason they chose ZIO.

Haskell makes the same bet — track the environment and the error in the type — but it doesn't put them in the effect type. It composes them on top of `IO` with monad transformers. The `R` becomes a `ReaderT`, the `E` becomes an `ExceptT`, and the `A` is the result. Here's the same program:

```haskell
{-# LANGUAGE FlexibleContexts #-}

newtype Env = Env { config :: Map.Map String String }   -- R
data Err = MissingKey String deriving Show               -- E

type App a = ReaderT Env (ExceptT Err IO) a

getPort :: App Int
getPort = do
  cfg <- asks config
  case Map.lookup "port" cfg of
    Just v  -> pure (read v)
    Nothing -> throwError (MissingKey "port")

runApp :: Env -> App a -> IO (Either Err a)
runApp env = runExceptT . flip runReaderT env

main :: IO ()
main = do
  ok  <- runApp (Env (Map.fromList [("port", "8080")])) getPort
  putStrLn ("ok: " ++ show ok)
  bad <- runApp (Env Map.empty) getPort
  putStrLn ("bad: " ++ show bad)
```

```
ok: Right 8080
bad: Left (MissingKey "port")
```

The mapping is exact. `R` is `ReaderT Env` and you read it with `ask`/`asks`. `E` is `ExceptT Err` and you raise it with `throwError`. `A` is the success value. `ZIO.provide(layer)` is `runReaderT env`. `foldZIO` over the two channels is pattern-matching the `Either` that `runExceptT` hands back. The type `App a = ReaderT Env (ExceptT Err IO) a` is `ZIO[Env, Err, A]`, written as a stack instead of a triple.

Now the honest part, because this is one of the few places where I don't think Haskell wins outright. ZIO's three-type encoding is genuinely more ergonomic for this. One type, great inference, no transformer stack to assemble and unwrap in the right order, no `lift` when you're three layers deep, and tooling that understands the whole thing. Haskell's MTL approach is more *composable* in theory — each transformer is an independent, reusable piece — but in practice deep stacks get awkward, the ordering matters in ways that surprise people, and performance can suffer from all the wrapping. The Haskell ecosystem knows this, which is why the modern answer is increasingly an effect-handler library — `effectful`, `polysemy`, or `fused-effects` — that gives you ZIO-like "all my effects in one place" ergonomics with a single type and better performance than transformer towers, while keeping the à-la-carte composability. I'm using plain `mtl` here because it's the mainstream baseline and it makes the `R`/`E`/`A` mapping legible; in a real codebase you'd likely pick `effectful` for the same reasons a Scala team picks ZIO.

So this is the genuine trade-off, not a verdict. ZIO bakes the environment and error into the effect type and gets inference and a unified model for it. Haskell spreads them across tools — transformers, or an effect-handler library — and gets composability and coherence with the rest of the language, at some cost in ergonomics and a real choice to make about which library. The deeper type-level machinery underneath all of this — tagless final, free monads, the type families that make effect systems tick — is a subject of its own, and deserves more than a paragraph.

## Where this is going

The thesis at the top was that Cats Effect's `IO` is Haskell's `IO` ported to the JVM, and that once you delete `Future`, the gap is mostly tooling. We've now watched that hold across the whole surface. `IO` is a lazy, referentially transparent description in both, run at the edge. Errors are an effect in both, with `try`/`attempt` and `catch`/`handleErrorWith` lining up almost word for word — and `Try` turned out to be `IO (Either SomeException a)`, produced by a combinator rather than shipped as a type. `bracket`, `Ref`, `STM`, `race`, `timeout`, and concurrent-map-with-cancellation are the same primitives wearing different names. The single real divergence — `timeout` raising versus returning — is one line to reconcile. And ZIO's `R/E/A` is the one place the languages make a different bet, which Haskell answers with `ReaderT`/`ExceptT` or an effect-handler library, trading ergonomics for composability in a way that's an honest draw.

Two things this post didn't weigh. The JVM is a real operational asset — mature profilers, a scheduler that's been hammered on for twenty years, and a deployment story a lot of teams already run. Haskell's runtime is excellent at lightweight concurrency and its STM is the real thing, but the operational tooling around it is thinner. And `Future` deserves one more kind word: for fire-and-forget async on the standard library, with no dependencies, it's fine — it's only the wrong foundation for *composable* effects, which is a different job than the one it was built for.

---

*Part of the **Haskell for Scala Developers** series:*

1. [Functions and Data](@/blog/2026-05-haskell-for-scala-devs-01-basics.md)
2. [Type Classes and Implicits](@/blog/2026-05-haskell-for-scala-devs-02-typeclasses.md)
3. **Effects and Concurrency**
4. [Objects and Modules](@/blog/2026-07-haskell-for-scala-devs-04-oop.md)
5. [Optics and Deriving](@/blog/2026-08-haskell-for-scala-devs-05-optics.md)
