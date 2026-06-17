+++
title = "Haskell for Scala Developers: Part 3 — Effects and Concurrency"
date = 2026-06-17
description = "Third in a series for working Scala developers picking up Haskell. IO and referential transparency, the Future critique, error handling as an effect, Resource/bracket, Ref and STM, structured concurrency, and ZIO's R/E/A versus Haskell's MTL and effect-handler libraries."
path = "blog/2026/06/haskell-for-scala-devs-03-effects"
[taxonomies]
tags = ["haskell", "scala", "functional-programming", "haskell-for-scala-devs"]
categories = ["programming"]
+++

<!-- TODO: Opening framing — 3–4 paragraphs. Backlink to Part 2 (one line). State the thesis: Cats Effect's IO is Haskell's IO ported to the JVM; once you remove Future, the gap is mostly tooling. ZIO's R/E/A is a different bet that Haskell makes via MTL / effect-handler libraries. End on a one-paragraph map of the post + the out-of-scope note. -->

<!-- more -->

## The thing Future got wrong

<!-- TODO: Referential transparency. One runnable snippet showing Future's eager eval / memoization surprise (a Future starts running when constructed; binding it to a val changes behavior). Contrast: an IO is a value/description that does nothing until run. Acknowledge Future's ergonomic wins in one sentence. This sets up why CE IO exists. -->

## IO is a value

<!-- TODO: Cats Effect IO side by side with Haskell IO. IO as first-class description; composition with map/flatMap/for vs fmap/>>=/do; "run at the end of the world" — IOApp/unsafeRunSync vs Haskell's main :: IO (). One-line callback to Part 2: IO is just another Monad; the do/for sugar from Part 2 works unchanged. Link Haskell Was Waiting for This when the "type tells you it touches the world" point lands. -->

## Errors are an effect (the Try story, finally)

<!-- TODO: The promise from Part 1. Scala Try / Either[Throwable, A] and CE's MonadError/handleErrorWith → Haskell throwIO / catch / try / handle / MonadThrow / MonadCatch, and IO (Either SomeException a). The point: exceptions are an effect Haskell tracks in IO; you don't get a Try because you don't need a separate wrapper — the catch combinators live in IO. Bound per spec §6: mechanical translation, not the checked-exceptions debate. -->

## Resources: bracket and Resource

<!-- TODO: CE Resource / bracket (and bracketCase) → Haskell bracket (Control.Exception) and Resource/managed (resourcet / managed). The acquire/use/release shape is identical. One worked example: open a handle, use it, guarantee release even on exception/cancellation. ZIO Scope noted in one line. -->

## Shared state: Ref, IORef, and STM

<!-- TODO: CE Ref / ZIO Ref → IORef (and atomicModifyIORef'); MVar for a lock-ish cell. Then STM: TVar + atomically, retry/orElse. The honest point: Haskell's STM monad lives in base/stm and the runtime was built around it; CE STM and ZIO STM are libraries on a runtime that wasn't — same idea, different provenance. One-line forward link to Part 4 (mutation as an effect, not a default). -->

## Concurrency: fibers, async, race, timeout

<!-- TODO: The anchor. CE fiber / start/join, parTraverse / parSequence, race, timeout → Haskell forkIO, async/wait, mapConcurrently / concurrently, race, timeout (System.Timeout). The anchor program: fetch N (simulated) URLs concurrently with a per-call timeout, cancel the rest on first failure. Show CE and Haskell side by side; note ZIO parity in one line (foreachPar / race / timeout). Say once that "fetch" is simulated for determinism. Address the timeout-semantics divergence (CE .timeout raises; Haskell timeout returns Maybe) explicitly in prose. -->

## ZIO's R/E/A, and how Haskell spells it

<!-- TODO: ZIO[R, E, A] on its own terms first (environment, typed error, value). Then map each axis: R → ReaderT / effectful's environment / implicit env; E → typed error via ExceptT / MonadError, or IO + exceptions for the untyped path; A → the result. Honest trade-off: ZIO's three-type encoding buys typed errors and dependency injection with great inference; Haskell spreads the same concerns across MTL transformers or an effect-handler library (effectful / polysemy / fused-effects), trading some ergonomics for composability and coherence. One-line Part 6 pointer for tagless final / free monads. Do NOT crown a winner. -->

## Where this is going

<!-- TODO: One short paragraph restating the thesis in past tense. One paragraph forward-pointer to Part 4 (OOP Without OOP). NO hyperlink — Part 4 doesn't exist yet. Plain prose. A follow-up task (after Part 4 ships) swaps it for a link. -->
