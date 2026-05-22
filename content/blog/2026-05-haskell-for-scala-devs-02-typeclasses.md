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

The simplest type classes are the ones nobody argues about. You want to print a value, compare two of them for equality, sort a list. Both languages have type classes for all three; both call them the same things. This is where the comparison is most boring — which is exactly why it's a good place to start. The boring parts make the interesting parts more visible.

### The Prelude versus Cats

In Haskell, `Eq`, `Show`, and `Ord` live in the `Prelude` — imported into every module by default. The laws (`(==)` is reflexive, `compare` is total, `show` produces something parseable in a non-binding way) are spelled out in the `base` library documentation, and every type that derives them is expected to honor them.

In Scala, the situation is _two stacks_. The language has its own `==`, `hashCode`, `toString`, `Comparable`, and `Ordering` — inherited from Java, defined on `Any`, lawless. Cats then layers `cats.Eq`, `cats.Show`, `cats.Order` on top of those, with proper laws, with `===` and `=!=` and `compare` as typed operations, and with the law-checking machinery in `cats.kernel.laws`. The Cats classes are a re-export of the Haskell vocabulary into a JVM library, because the JVM standard library got there first with a worse version.

This isn't subtle. Cats is literally trying to give Scala what `Prelude` gives Haskell, as a library, because the language couldn't make it the default without breaking every existing program written to `Any.equals`.

### Deriving the basics

Take a `Payment` from Part 1:

```scala
import cats.{Eq, Show, Order}
import cats.syntax.all.*

enum Currency:
  case USD, EUR, UAH

object Currency:
  given Eq[Currency]   = Eq.fromUniversalEquals
  given Show[Currency] = Show.fromToString

case class Payment(id: String, amount: BigDecimal, currency: Currency)

object Payment:
  given Eq[Payment]   = Eq.fromUniversalEquals
  given Show[Payment] = Show.fromToString
  given Order[Payment] with
    def compare(a: Payment, b: Payment): Int =
      a.amount.compare(b.amount)
```

In Haskell:

```haskell
data Currency = USD | EUR | UAH
  deriving (Show, Eq, Ord)

data Payment = Payment
  { paymentId :: String
  , amount    :: Double
  , currency  :: Currency
  } deriving (Show, Eq)

instance Ord Payment where
  compare a b = compare (amount a) (amount b)
```

The Scala block is exactly how Cats wants you to do this. Companion-object givens, one `Eq.fromUniversalEquals` per type, one `Show.fromToString`, and a hand-written `Order` because the auto-derived ordering would compare structurally — not what we want here. Scala 3's `derives` keyword can shorten the first part to `derives Eq, Show` for types whose Cats class supports it; in Cats 2.10, `Eq` and `Show` don't ship a `derived` method, so you write the `given`s anyway, or you bring in `kittens`. `derives` plus `kittens` is the modern path. It is also one more dependency.

The Haskell block does all of the same work in the `deriving` clauses of the data declarations themselves. `Eq`, `Show`, and the default `Ord` are derived structurally; you write the one custom `Ord` you actually want. There are no companion objects, no `given` boilerplate, no imports beyond the `Prelude`, no library to pin to a version, and no decision about which derivation flavor to use until we get to `DerivingVia` later in this post.

The whole apparatus that Scala has bolted onto its case classes — `equals`, `hashCode`, `Ordering`, plus Cats's `Eq`, `Show`, `Order` sitting on top — is in Haskell one keyword on one line.

### `==` versus `===`

The reason Cats introduced `===` in the first place is that Scala 2's `==` was universally typed. `1 == "true"` compiled, returned `false`, and gave you a small heartbreak when the bug landed in production. Cats's `===` requires an `Eq[A]` for both sides, so any cross-type comparison fails at compile time. The Scala community has spent over a decade typing five extra characters to avoid this.

Scala 3 has been chipping away at it. As of 3.4, comparing a primitive with a reference type — `1 == "1"` — is a compile error, no opt-in needed. Cross-type comparison between unrelated case classes still compiles and still returns `false`; closing that gap broadly is what `strictEquality` does opt-in, and what `===` does in Cats. When the language work is finished, `===` ends up being the same thing the language operator already is.

Haskell never had the problem. `(==) :: Eq a => a -> a -> Bool` has been the signature since 1989. There is no universal equality; the only equality is the one the type class defines, and the only types you can compare with `==` are types whose `Eq` instance is in scope. The discipline Cats had to add as a library, and that Scala 3 is slowly making default, is in Haskell the only option that has ever existed.

So: same names, same shape, same job. The interesting question is what they cost you to use — and the answer for the basics is "five lines of `given`s per type in Scala, zero lines in Haskell." That answer scales up as the type classes get less basic, which is the rest of the post.

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
