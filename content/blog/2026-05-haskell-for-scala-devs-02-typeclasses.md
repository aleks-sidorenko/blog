+++
title = "Haskell for Scala Developers: Part 2 — Type Classes and Implicits"
date = 2026-05-22
description = "Second in a series for working Scala developers picking up Haskell. Type classes, given/using, instance scope, coherence, higher-kinded types, and the Functor/Applicative/Monad hierarchy — and what changes when the feature isn't a workaround."
path = "blog/2026/05/haskell-for-scala-devs-02-typeclasses"
[taxonomies]
tags = ["haskell", "scala", "functional-programming", "haskell-for-scala-devs"]
categories = ["programming"]
+++

Part 1 was the friendly part of the comparison. Functions, ADTs, options, newtypes — Scala does these well, Haskell does them a hair better, the gap is small. This post is where the gap stops being a hair.

Implicits in Scala have an origin story that I think gets understated. They are not "a way to thread context through your code" — that's how we use them, but it's not what they're _for_. Implicits were Scala's mechanism for doing the work of Haskell's type classes inside a language that doesn't have them. The design lineage runs straight back to Wadler, who co-authored the original Haskell type-class paper in 1989 and then, two decades later, co-authored the paper that put implicits in Scala. The mechanism was reverse-engineered backwards from the Haskell feature it was meant to imitate.

Scala 3's `given` / `using` is the cleanup. With the benefit of every Scala-incoherence horror story the community has accumulated, the language renamed the keywords, narrowed the resolution rules, and tried to hide the implicit-conversion footguns that were eating juniors alive. It is much better than what it replaced. And it is still trying to be a thing that Haskell already is.

That's the post. Less ceremony, fewer footguns, no implicit-conversion magic, instance coherence by default. We'll walk it from the simplest case — `Eq`, `Show`, `Ord`, same words and same job in both languages — through resolution and coherence, through the type-system feature both languages had to invent for this (HKTs), through the `Functor`/`Applicative`/`Monad` ladder on our own type, and out the back via `deriving`. I'll assume you can read Cats fluently. I'm not going to re-teach the abstractions.

_Previous in series: [Part 1 — Functions and Data](@/blog/2026-05-haskell-for-scala-devs-01-basics.md)._

<!-- more -->

A note on what this post does _not_ cover. Effects, `IO`, and the `Future`-versus-`IO` argument are Part 3. Anything OOP-shaped — inheritance, traits as mixins, encapsulation, mutable state, the full module-system comparison — is Part 4. Optics, the deeper derivation story, and Template Haskell versus Scala 3 macros land in Part 5. Variance, GADTs, type families, refinement types, and the dependent-type adjacencies wait until Part 6. The basics — functions, ADTs, `Option`/`Either`, newtypes — were Part 1. If a topic feels conspicuously skipped here, that's where it lives.

## A small anchor for the abstract bits

Most of the comparisons in this post are cleaner with a small type we've written ourselves. Stdlib types like `Either` or `Option` have their instances baked in by the language; you can't see the seams. To watch how a `Functor`, an `Applicative`, and a `Monad` actually get installed on a type — and where Haskell and Scala disagree about what that even means — we need something we control.

Call it `Outcome`. It's a two-case sum: either we have a valid value, or we have a list of reasons we don't. Roughly the shape of Cats's `Validated`.

In Scala 3:

```scala
enum Outcome[+A]:
  case Invalid(reasons: List[String])
  case Valid(value: A)
```

In Haskell:

```haskell
data Outcome a
  = Invalid [String]
  | Valid a
  deriving (Show, Eq, Functor)
```

Two things to flag before we go further. First, the failure side carries a `List[String]` rather than a single error — that matters later, when the `Applicative` instance will _accumulate_ those reasons across independent computations and the `Monad` instance won't. The tension between those two instances is the only deliberately interesting bit in the type. Second, the Haskell version derives `Functor` right there in the data declaration; the Scala version cannot, and the instance has to be hand-written downstream. Hold onto that — it's foreshadowing.

I'll bring back the `Payment` from Part 1 when we need a type with record shape; `Outcome` is for the part of the post where we're watching the abstraction get wired up.

## The vocabulary: Eq, Show, Ord, and friends

<!-- TODO: The simplest type classes first. Cats Eq/Show/Order and Scala 3 derives → Haskell deriving (Eq, Show, Ord). Where the equivalences are 1:1, where Cats adds laws and Haskell ships them silently in the Prelude. Bring back Payment for a tiny Eq/Ord/Show example. -->

## From `given`/`using` to `class`/`instance`

<!-- TODO: A new type class (e.g. Pretty) defined in both languages. How Scala 3 looks up givens (companion-object lookup, imported givens, package-level givens) vs Haskell's flat top-level instances with module-import control. Coherence: Scala can have multiple instances in scope; Haskell guarantees one. Honest acknowledgment of orphan instances as Haskell's cost. -->

## Higher-kinded types

<!-- TODO: `F[_]` → `f`. Why both languages need it. One use site (a tiny generic helper). One sentence about kinds (`* -> *`), one mention of `:k`, then move on. Defer variance/Contravariant/roles to Part 6. -->

## Functor, Applicative, Monad — on a custom type

<!-- TODO: Use Outcome (the anchor from §1). Walk Functor → Applicative → Monad in three subsections, defining the Cats instance and the Haskell instance side by side. Show the consequence: do-notation, <-, >>=, the fact that this all just works for any Monad. One paragraph at the end on laws (mentioned, not relitigated). One-sentence forward link: "IO is a Monad too — Part 3." -->

## Deriving: from `derives` to `deriving via`

<!-- TODO: Scala 3 `derives` and Shapeless typeclass derivation → Haskell `deriving`, `DerivingStrategies`, `DerivingVia`. One worked example with a newtype reusing an instance via `DerivingVia` (matching Part 1's Score/Sum example). One paragraph on why deriving is so much more usable in Haskell. One-line forward link: "Part 5 goes deeper — generics, Shapeless's heir, Template Haskell, the lot." -->

## Where this is going

<!-- TODO: One short closing paragraph restating the thesis in past tense. One paragraph forward-pointer to Part 3 (Effects and Concurrency). NO hyperlink — Part 3 doesn't exist yet. Plain prose. A follow-up task (after Part 3 ships) will swap this for a link. -->
