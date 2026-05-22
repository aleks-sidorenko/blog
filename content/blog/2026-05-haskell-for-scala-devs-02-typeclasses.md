+++
title = "Haskell for Scala Developers: Part 2 — Type Classes and Implicits"
date = 2026-05-22
description = "Second in a series for working Scala developers picking up Haskell. Type classes, given/using, instance scope, coherence, higher-kinded types, and the Functor/Applicative/Monad hierarchy — and what changes when the feature isn't a workaround."
path = "blog/2026/05/haskell-for-scala-devs-02-typeclasses"
[taxonomies]
tags = ["haskell", "scala", "functional-programming", "haskell-for-scala-devs"]
categories = ["programming"]
+++

Part 1 was the friendly part of the comparison. Functions, ADTs, options, newtypes — Scala does these well, Haskell does them slightly better, and the gap is small. This post is where the gap becomes wide.

Implicits in Scala have an origin story that I think gets understated. They are not "a way to thread context through your code" — that's how we use them, but it's not what they're _for_. Implicits were Scala's mechanism for doing the work of Haskell's type classes inside a language that doesn't have them. Wadler and Blott published the original Haskell type-class paper in 1989; Odersky designed Scala's implicit-parameter machinery explicitly so the same shape of code could be written on the JVM. The mechanism was reverse-engineered from the Haskell feature it was meant to imitate.

Scala 3's `given` / `using` is the cleanup. With the benefit of every Scala-incoherence horror story the community has collected, the language renamed the keywords, narrowed the resolution rules, and tried to hide the implicit-conversion traps that were eating juniors alive. It is much better than what it replaced. And it is still trying to be a thing that Haskell already is.

That's the post. Less ceremony, fewer traps, no implicit-conversion magic, instance coherence by default. We'll walk it from the simplest case — `Eq`, `Show`, `Ord`, same words and same job in both languages — through resolution and coherence, through the type-system feature both languages had to invent for this (HKTs), through the `Functor`/`Applicative`/`Monad` ladder on our own type, and ending with `deriving`. I'll assume you can read Cats fluently. I'm not going to re-teach the abstractions.

_Previous in series: [Part 1 — Functions and Data](@/blog/2026-05-haskell-for-scala-devs-01-basics.md)._

<!-- more -->

## A small anchor for the abstract bits

Most of the comparisons in this post are cleaner with a small type we've written ourselves. Stdlib types like `Either` or `Option` have their instances built in by the language; you can't see the seams. To watch how a `Functor`, an `Applicative`, and a `Monad` actually get added to a type — and where Haskell and Scala disagree about what that even means — we need something we control.

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

Two things to flag before we go further. First, the failure side carries a `List[String]` rather than a single error — that matters later, when the `Applicative` instance will _accumulate_ those reasons across independent computations and the `Monad` instance won't. The tension between those two instances is the only deliberately interesting part of the type. Second, the Haskell version derives `Functor` right there in the data declaration; the Scala version cannot, and the instance has to be hand-written downstream. Hold onto that — it's foreshadowing.

I'll bring back the `Payment` from Part 1 when we need a type with record shape; `Outcome` is for the part of the post where we're watching the abstraction get wired together. Three sections of apparatus first — naming, lookup, and HKTs. Then we add the instances to `Outcome` and watch the language disagree with itself.

## The vocabulary: Eq, Show, Ord, and friends

The simplest type classes are the ones nobody argues about. You want to print a value, compare two of them for equality, sort a list. Both languages have type classes for all three; both call them the same things. This is where the comparison is most boring — which is exactly why it's a good place to start. The boring parts make the interesting parts more visible.

### The Prelude versus Cats

In Haskell, `Eq`, `Show`, and `Ord` live in the `Prelude` — imported into every module by default. The laws (`(==)` is reflexive, `compare` is total, `show` produces something parseable in a non-binding way) are spelled out in the `base` library documentation, and every type that derives them is expected to honor them.

In Scala, the situation is _two stacks_. The language has its own `==`, `hashCode`, `toString`, `Comparable`, and `Ordering` — inherited from Java, defined on `Any`, lawless. Cats then layers `cats.Eq`, `cats.Show`, `cats.Order` on top of those, with proper laws, with `===` and `=!=` and `compare` as typed operations, and with the law-checking machinery in `cats.kernel.laws`. The Cats classes are a re-export of the Haskell vocabulary into a JVM library, because the JVM standard library arrived first with a worse version.

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

The Scala block is exactly how Cats wants you to do this. Companion-object givens, one `Eq.fromUniversalEquals` per type, one `Show.fromToString`, and a hand-written `Order` because the auto-derived ordering would compare by structure — not what we want here. Scala 3's `derives` keyword can shorten the first part to `derives Eq, Show` for types whose Cats class supports it; in Cats 2.10, `Eq` and `Show` don't ship a `derived` method, so you write the `given`s anyway, or you bring in `kittens`. `derives` plus `kittens` is the modern path. It is also one more dependency.

The Haskell block does all of the same work in the `deriving` clauses of the data declarations themselves. `Eq`, `Show`, and the default `Ord` are derived structurally; you write the one custom `Ord` you actually want. There are no companion objects, no `given` boilerplate, no imports beyond the `Prelude`, no library to pin to a version, and no decision about which derivation flavor to use until we get to `DerivingVia` later in this post.

The whole machinery that Scala has attached to its case classes — `equals`, `hashCode`, `Ordering`, plus Cats's `Eq`, `Show`, `Order` sitting on top — is in Haskell one keyword on one line.

### `==` versus `===`

The reason Cats introduced `===` in the first place is that Scala 2's `==` was universally typed. `1 == "true"` compiled, returned `false`, and caused a small heartbreak when the bug showed up in production. Cats's `===` requires an `Eq[A]` for both sides, so any cross-type comparison fails at compile time. The Scala community has spent over a decade typing five extra characters to avoid this.

Scala 3 has been slowly fixing this. As of 3.4, comparing a primitive with a reference type — `1 == "1"` — is a compile error, no opt-in needed. Cross-type comparison between unrelated case classes still compiles and still returns `false`; closing that gap broadly is what `strictEquality` does opt-in, and what `===` does in Cats. When the language work is finished, `===` ends up being the same thing the language operator already is.

Haskell never had the problem. `(==) :: Eq a => a -> a -> Bool` has been the signature since 1989. There is no universal equality; the only equality is the one the type class defines, and the only types you can compare with `==` are types whose `Eq` instance is in scope. The discipline Cats had to add as a library, and that Scala 3 is slowly making the default, is in Haskell the only option that has ever existed.

So: same names, same shape, same job. The interesting question is what they cost you to use — and the answer for the basics is "five lines of `given`s per type in Scala, zero lines in Haskell." That answer scales up as the type classes get less basic, which is the rest of the post.

## From `given`/`using` to `class`/`instance`

`Eq`, `Show`, `Ord` are the easy case — the language ships them. When you want a type class the language and the standard library don't provide, you have to declare one. Both Scala and Haskell let you do that. The mechanics are not the same.

### Defining a type class

A small example: a `Pretty` class with one method that turns a value into a debug-y display string.

```scala
trait Pretty[A]:
  def pretty(a: A): String

object Pretty:
  given Pretty[Int] with
    def pretty(n: Int) = "Int(" + n + ")"
  given Pretty[String] with
    def pretty(s: String) = "\"" + s + "\""

def greet[A](a: A)(using p: Pretty[A]): String = p.pretty(a)
```

```haskell
class Pretty a where
  pretty :: a -> String

instance Pretty Int where
  pretty n = "Int(" ++ show n ++ ")"

instance Pretty String where
  pretty s = "\"" ++ s ++ "\""

greet :: Pretty a => a -> String
greet = pretty
```

The mechanical translation is small. `trait Pretty[A]` becomes `class Pretty a`. `given Pretty[Int] with` becomes `instance Pretty Int where`. The `(using p: Pretty[A])` constraint on a method becomes `Pretty a =>` to the left of the function arrow.

If this is the first time you've put the two side by side, the lineage is visible. Scala wrote the same idea in slightly different syntax because it had to fit it into a language that already had classes and objects. The `given` keyword exists because `implicit val` was, in retrospect, calling the wrong thing implicit. `with` exists because `extends` would have read as inheritance on a thing that isn't an inheritance relationship. The grammar is hand-designed to avoid colliding with twenty years of Scala-as-OOP. The Haskell version is older than several of the things Scala had to negotiate with.

### How instances get found

The interesting differences start at the call site. When you write `greet(42)` in Scala or `greet (42 :: Int)` in Haskell, each compiler has to find the `Pretty[Int]` to use. The lookup rules are not the same.

In **Scala 3**, the compiler searches, in order: arguments you passed explicitly (`greet(42)(using somePretty)` always works); givens in the current local scope; givens imported into scope with `import SomeObject.given`; givens defined in the companion object of the type (`object Pretty` for `Pretty[Int]`, then `object Int` — though you can't actually define givens on built-in `Int`); and package-level givens visible from the current location. Specificity rules break ties when more than one is possible. The model Scala 3 settled on is documented, stable, and mostly predictable. It is also a list of five different ways the answer can be supplied, and they interact.

In **Haskell**, instance lookup is one rule: at any given point in the program, an `instance Pretty Int` either exists or it doesn't, and if it exists it's reachable through the import graph. There is no "instance in the companion object" or "instance brought in by an import alias" — when you `import` a module, you get its type class declarations and all instances defined inside it. When you `import` a module that defines a type, you get the type and all instances defined alongside it. The instance lookup the compiler performs is "is there one." Coherence is what keeps that question answerable.

The full module-system comparison — what `package` and `object` and `package object` and companion objects all do in Scala, and how Haskell's single `module` construct collapses those — is Part 4. For now: Scala has five lookup paths because it has five places things can live. Haskell has one because it has one.

### Coherence — and its cost

Here is what falls out of those rules. Take the Scala class above and create two competing instances in unrelated places:

```scala
object PrettyA:
  given Pretty[Int] with
    def pretty(n: Int) = "PrettyA(" + n + ")"

object PrettyB:
  given Pretty[Int] with
    def pretty(n: Int) = "PrettyB(" + n + ")"

@main def demo(): Unit =
  import PrettyA.given
  import PrettyB.given
  println(summon[Pretty[Int]].pretty(42))
```

The Scala 3 compiler accepts this program. It runs. It prints `PrettyB(42)`, because the later import shadowed the earlier one in lexical scope. There is no warning. The same expression `summon[Pretty[Int]].pretty(42)`, in a module that imported the two givens in the opposite order, would print `PrettyA(42)` and still compile. This is the coherence problem — and it's not a made-up one; it's the shape every "we depend on two libraries that both provide a `Show` instance for `LocalDate`" bug has ever taken.

The Haskell equivalent, where you declare `Pretty Int` twice in one program, looks like this:

```haskell
instance Pretty Int where
  pretty n = "Int(" ++ show n ++ ")"

instance Pretty Int where
  pretty n = "different(" ++ show n ++ ")"
```

GHC refuses:

```
error: [GHC-59692]
    Duplicate instance declarations:
      instance Pretty Int -- Defined at ... line 6
      instance Pretty Int -- Defined at ... line 10
```

There is no path through which the program can be made to compile. There is one `Pretty Int` instance for any given Haskell program, ever, full stop. If two modules ship competing instances, the program that wants to use both modules will not link. Two libraries that both define an instance for the same `(class, type)` pair cannot be used together — pick one.

What this guarantees is exactly what Scala can't: a call to `pretty x` always means the same thing, regardless of who imported what, in what order. Substitute the same `x` and you get the same string back, anywhere in the program. Scala's `summon[Pretty[Int]].pretty(42)` is referentially transparent _given the imports in scope_, which is a different and weaker promise.

The cost is real though, and it has a name: **orphan instance**. An orphan is an `instance Pretty Foo` defined in a module that owns neither `Pretty` nor `Foo`. Orphans break the coherence guarantee: nothing prevents library A from defining `instance Pretty Int` and library B from defining a different `instance Pretty Int`, both as orphans. If a downstream project imports both, GHC refuses to build. With non-orphan instances, the only place to put `instance Pretty Foo` is in the module that defines `Foo` (it travels with the type) or the module that defines `Pretty` (it travels with the class) — and the import-graph reachability rule ensures the compiler always sees the same one.

GHC will warn you when you write an orphan, if you ask it to:

```
warning: [GHC-90177] [-Worphans]
    Orphan class instance: instance Pretty Int
    Suggested fix:
      Move the instance declaration to the module of the class or of the type, or
      wrap the type with a newtype and declare the instance on the new type.
```

The suggested fix is the entire discipline in one sentence. Put the instance with the type, put it with the class, or wrap the type in a `newtype` (Part 1) and declare the instance on the wrapper — at which point it's no longer an orphan, because the wrapper belongs to your module. In practice, Haskell developers internalize this and you almost never see orphans in production code outside of a few valid cases (compatibility shims between libraries that can't import each other).

Scala 3 made the opposite bet. It accepts that multiple `given`s may be in scope and pushes the resolution into the language's lookup rules — companion objects, imports, package givens, locals. The model is more flexible. It also gives you the silent-winner behavior above, and it requires the programmer to keep a mental model of which import path produced which `given`. We'll see how Haskell's `module` plus `instance` quietly does the work of several different Scala constructs in Part 4. For now: same problem, different bet — and the bet matters more in shared, long-lived code that you didn't write by yourself.

## Higher-kinded types

Both Scala and Haskell had to invent syntax for a particular kind of type — the kind whose values are themselves "containers" or "contexts" parameterized over another type. `List` of what? `Option` of what? `IO` returning what? You can write a function that doesn't care what's inside, but only if the language has a way to abstract over the wrapper.

Scala spells it `F[_]`:

```scala
def sequence[F[_]: Applicative, A](fs: List[F[A]]): F[List[A]]
```

Haskell uses a lowercase type variable in a place where the compiler can tell you mean a one-hole type constructor:

```haskell
sequence :: Applicative f => [f a] -> f [a]
```

These are the same signature. Both `F[_]` and `f` mean "any type that has one hole left in it" — `List`, `Maybe` / `Option`, `IO`, `Either e` (with the `e` already filled), our `Outcome` from earlier. The syntactic difference exists because Scala has to disambiguate: lowercase `f` in Scala is just a value name. Haskell, where type variables and value names live in separate namespaces, gets the "lowercase means variable" convention for free, and the _kind_ of the variable is inferred from where you use it.

`sequence` is the standard example. It takes a list of "context-wrapped" values and turns them into a single context wrapping a list of values. Concretely:

```scala
val xs: List[Option[Int]] = List(Some(1), Some(2), Some(3))
xs.sequence              // Some(List(1, 2, 3))

val ys: List[Option[Int]] = List(Some(1), None, Some(3))
ys.sequence              // None
```

```haskell
sequence [Just 1, Just 2, Just 3]    -- Just [1,2,3]
sequence [Just 1, Nothing,  Just 3]  -- Nothing
```

The implementation is identical: walk the list, combine the results with the `Applicative` instance, short-circuit when the context says to. The signature is identical too, once you look past the syntax. The only reason either language has this primitive is that both have the feature `F[_]` / `f` represents.

If you've ever wondered why Scala uses `F[_]` with the underscore in the type-parameter position, this is why. The underscore is the visible mark of a feature Haskell never needed to invent special syntax for. In Haskell, `sequence :: Applicative f => [f a] -> f [a]` is normal in shape, and the compiler infers the _kind_ `* -> *` from the way `f` is used (`f a`, `f [a]`). If you want to see the inferred kind in GHCi, `:k Maybe` prints `Maybe :: * -> *`. That's the entire ceremony.

Variance — Scala's `+A` and `-A`, plus the question of when a `Functor` instance is even expected to exist for a given `F[_]` — is its own subject and lives in Part 6. So does `Contravariant` and the type-system roles machinery that Haskell uses to control what you can derive on a parameterized type.

## Functor, Applicative, Monad — on a custom type

This is the part the walkthrough has been building toward. Three type classes, in order of strength: `Functor` is "I can map a function over the wrapped value." `Applicative` is "I can apply a wrapped function to a wrapped value, and I can lift a plain value into the wrapper." `Monad` is "I can chain computations where each step's input depends on the previous step's output, and I get a context-respecting result back."

In both languages, these classes are layered — `Monad` requires `Applicative` requires `Functor` — and in both, the standard library / Cats supplies instances for the obvious stdlib types and lets you declare your own. The interesting thing is what happens on `Outcome` from earlier in this post, because `Outcome`'s natural `Applicative` and `Monad` fight.

### Functor

In Haskell, deriving `Functor` is one word in the data declaration:

```haskell
data Outcome a
  = Invalid [String]
  | Valid a
  deriving (Show, Eq, Functor)
```

`{-# LANGUAGE DeriveFunctor #-}` makes the compiler write the obvious `fmap`: leave `Invalid` alone, apply the function to the contents of `Valid`. There are types where you'd want non-default behavior, but for `Outcome` the obvious thing is right.

Scala can't derive `Functor`. You write it:

```scala
given Functor[Outcome] with
  def map[A, B](fa: Outcome[A])(f: A => B): Outcome[B] = fa match
    case Outcome.Invalid(rs) => Outcome.Invalid(rs)
    case Outcome.Valid(a)    => Outcome.Valid(f(a))
```

This block, on every parameterized data type you ever ship, is the price of using Cats. Scala 3's `derives` keyword can shorten it with the right derivation library (`kittens`), but Cats's vocabulary doesn't ship the `derived` method out of the box. So you write the `Functor` by hand — the way Haskell developers stopped writing them by hand in 2012, when `DeriveFunctor` shipped in GHC 7.4.

### Applicative

`Applicative` is where `Outcome` gets interesting. The natural instance accumulates errors — combine two `Invalid`s and you get the concatenation of their reasons:

```scala
given Applicative[Outcome] with
  def pure[A](a: A): Outcome[A] = Outcome.Valid(a)
  def ap[A, B](ff: Outcome[A => B])(fa: Outcome[A]): Outcome[B] =
    (ff, fa) match
      case (Outcome.Invalid(r1), Outcome.Invalid(r2)) => Outcome.Invalid(r1 ++ r2)
      case (Outcome.Invalid(rs), _)                   => Outcome.Invalid(rs)
      case (_, Outcome.Invalid(rs))                   => Outcome.Invalid(rs)
      case (Outcome.Valid(f),    Outcome.Valid(a))    => Outcome.Valid(f(a))
```

```haskell
instance Applicative Outcome where
  pure = Valid
  (Invalid r1) <*> (Invalid r2) = Invalid (r1 ++ r2)
  (Invalid rs) <*> _            = Invalid rs
  _            <*> (Invalid rs) = Invalid rs
  (Valid f)    <*> (Valid x)    = Valid (f x)
```

This is the satisfying instance — validate name, validate email, validate password, and if all three fail you get all three error messages back instead of just the first one. Cats's `Validated`, Haskell's `Validation`, the validation pattern in every effect library — same shape, same `Applicative`.

It has one problem.

### Monad — and the disagreement

You can't write a lawful `Monad` instance for `Outcome` that keeps the accumulating behavior. The Monad laws require `ap` (the `Applicative` operation) to agree with `liftA2 id` implemented via `>>=`. With `Invalid r1 >>= \f -> Invalid r2 >>= \x -> pure (f x)`, the right-hand bind never runs — `r2` is invisible, you get `Invalid r1`. The Monad-implied `<*>` short-circuits. The standalone accumulating `<*>` does not. The two are different functions, and a lawful `Monad` requires them to be the same.

So you pick. The Haskell ecosystem picks for you: there's `Either e` (lawful Monad, short-circuit on failure) and `Validation e` (Applicative-only, accumulating). Cats does the same: `Either[E, A]` (Monad, short-circuit) and `Validated[E, A]` (Applicative-only, accumulating). `Outcome` as written above with _both_ instances is doing the thing the ecosystem warns against — useful as a teaching example, not what you'd ship.

For the rest of this section, pretend `Outcome` is the short-circuiting variant — `Applicative` derived from `Monad`, errors stop at the first failure. That's what the `do`-block and the `for`-comprehension below assume.

```scala
given Monad[Outcome] with
  def pure[A](a: A): Outcome[A] = Outcome.Valid(a)
  def flatMap[A, B](fa: Outcome[A])(f: A => Outcome[B]): Outcome[B] = fa match
    case Outcome.Invalid(rs) => Outcome.Invalid(rs)
    case Outcome.Valid(a)    => f(a)
  def tailRecM[A, B](a: A)(f: A => Outcome[Either[A, B]]): Outcome[B] = ???
  // tailRecM is a Cats requirement for stack-safe recursion; elided.
```

```haskell
instance Monad Outcome where
  return = pure
  (Invalid rs) >>= _ = Invalid rs
  (Valid a)    >>= f = f a
```

With those in scope, the parsing pipeline that says "parse two integers, sum them, error out on the first failure" is exactly the wiring both languages built sugar for:

```scala
def parseInt(s: String): Outcome[Int] =
  s.toIntOption match
    case Some(i) => Outcome.Valid(i)
    case None    => Outcome.Invalid(List(s"not an int: $s"))

val ok = for
  a <- parseInt("10")
  b <- parseInt("20")
yield a + b
// Valid(30)

val ko = for
  a <- parseInt("oops")
  b <- parseInt("20")
yield a + b
// Invalid(List(not an int: oops))
```

```haskell
parseInt :: String -> Outcome Int
parseInt s = case readMaybe s of
  Just i  -> Valid i
  Nothing -> Invalid ["not an int: " ++ s]

ok = do
  a <- parseInt "10"
  b <- parseInt "20"
  pure (a + b)
-- Valid 30

ko = do
  a <- parseInt "oops"
  b <- parseInt "20"
  pure (a + b)
-- Invalid ["not an int: oops"]
```

Scala's `for { x <- ... }` desugars to `flatMap` / `map` / `withFilter`. Haskell's `do { x <- ... }` desugars to `(>>=)` / `return`. The translations are mechanical. The same `for`-block runs over `Option`, `Either`, `List`, `IO`, `Outcome`, any type whose `Monad` instance is in scope; the same `do`-block runs over any Haskell `Monad`. The notation is the same shape because the abstraction underneath is the same shape.

Both languages document the laws — `Functor` identity and composition, `Applicative` identity / homomorphism / interchange / composition, `Monad` left-identity / right-identity / associativity. Both rely on the implementer to honor them, both let you write instances that don't, and both ship a way to test that you haven't (`cats-laws` and `quickcheck-classes`, respectively). The difference, when it shows up, is that Haskell's coherence guarantee makes a broken instance more dangerous — it's broken _everywhere_ in your program — and also easier to find, because the single-instance rule means there's exactly one place to fix. And `IO` is a `Monad` in both languages: `do { line <- getLine; putStrLn line }` is the same shape as `for { line <- IO.readLine; _ <- IO.println(line) } yield ()`. That's where Part 3 starts.

## Deriving: from `derives` to `deriving via`

We've already used `deriving` a half-dozen times in this post and in Part 1 without remarking on it. It's time to remark.

In Scala 3, the syntax is:

```scala
case class Payment(id: String, amount: BigDecimal)
  derives CanEqual
```

`derives X` is a Scala 3 keyword that tells the compiler "look for `X.derived` and use it to construct an instance." `CanEqual` from `scala.CanEqual` provides one, so `derives CanEqual` works out of the box. Cats's `Eq`, `Show`, `Functor` do not, in cats-core 2.10 — you bring in `kittens` (the deriving sibling library) or write the `given`s by hand, as we did in the Vocabulary section. `Magnolia` and `shapeless` are the older derivation engines; the modern story is `derives` plus `kittens`. The Shapeless-as-machinery era is fading out with Scala 3.

The Haskell equivalent is in the data declaration itself, and is older than most Scala features:

```haskell
{-# LANGUAGE DerivingStrategies #-}

data Payment = Payment { paymentId :: String, amount :: Double }
  deriving stock (Show, Eq)
```

`stock` is one of three strategies you can ask GHC to use, opt-in via the `DerivingStrategies` pragma. `stock` is "compiler writes the instance based on the type's structure" — what you get for `Show`, `Eq`, `Ord`, `Functor`, `Foldable`, `Traversable`, `Generic`. `newtype` is "the wrapper borrows its underlying type's instance," at zero runtime cost, for any class at all:

```haskell
newtype Cents = Cents Int
  deriving stock (Show, Eq)
  deriving newtype (Num, Ord)
```

`Cents 5 + Cents 3` is `Cents 8`. The `Num` instance from `Int` is reused as-is, and the type discipline of the newtype stays in place — you can't accidentally pass an `Int` where a `Cents` is wanted. Scala has no built-in equivalent. Scala 3's opaque types (Part 1) are zero-cost wrappers but can't reuse the underlying type's instances; you re-declare each one in the module where the underlying representation is visible. `kittens` and clever derivation libraries can shorten this for stdlib classes. For user-defined classes you write the instance again.

The third strategy is `anyclass`, which says "use the class's default-method definitions to derive the instance" — useful when a class is designed for it, rarer than `stock` or `newtype` in practice.

Then there is `DerivingVia`, which we touched on briefly in Part 1 and which has no equivalent in Scala. The idea: borrow an instance not from the underlying type, but from a "stand-in" newtype that already has the instance you actually want.

```haskell
{-# LANGUAGE DerivingVia #-}
import Data.Monoid (Sum(..))

newtype Bracketed a = Bracketed a
instance Pretty a => Pretty (Bracketed a) where
  pretty (Bracketed a) = "[" ++ pretty a ++ "]"

newtype Score = Score Int
  deriving stock (Show, Eq)
  deriving (Semigroup, Monoid) via (Sum Int)
  deriving Pretty              via (Bracketed Int)
```

`Score 1 <> Score 2` is `Score 3` — the `Sum Int` newtype's `Semigroup` instance combines by adding, and the `via (Sum Int)` clause tells the compiler that `Score`'s `Semigroup` should behave the same way. `pretty (Score 7)` is `"[Int(7)]"` — the `Bracketed Int` instance wraps the underlying `Pretty Int` output in brackets, and `via (Bracketed Int)` says that's what `Pretty Score` should mean.

`Bracketed` is the stand-in. It exists only to carry that "wrap in brackets" `Pretty` instance, available to any type that can be coerced to its representation. This is a feature Cats developers spend years asking for: the ability to say "I want this instance, _but_ derived this way, not that way." Haskell ships it as a one-line declaration.

The takeaway: in Scala, deriving is a language feature still maturing through libraries. Each Cats class needs a derivation library to plug into the `derives` keyword. Each new pattern — DerivingVia-style instance reuse, generic JSON encodings, ORM mappings — requires its own library design. In Haskell, the compiler was built around the assumption that you'd want this. `stock` derives the obvious instances for the obvious classes. `newtype` is one keyword. `DerivingVia` is two. The ecosystem _starts_ from "your types should mostly write themselves" and lets you opt out where you want custom behavior.

Part 5 goes deeper — `GHC.Generics` is the engine underneath `stock` derivation, Template Haskell is the metaprogramming back door, and the comparison to Scala 3's `inline` / `quotes` macros is its own post.

## Where this is going

The thesis at the top was that implicits started life as a way to do Haskell's type-class job inside a language that didn't have type classes. We've now seen it land in six places. `Eq`, `Show`, `Ord` — same names, same shape, the language has the words and you write the boilerplate. `given` / `using` versus `class` / `instance` — five different lookup paths versus one. Coherence — Scala silently picks a winner, Haskell forbids the ambiguity at the cost of policing orphans. HKTs — both languages had to invent the syntax; Haskell needed less of it. `Functor` / `Applicative` / `Monad` — same hierarchy, same laws, same `do` / `for` sugar over the same `>>=` / `flatMap`. Deriving — Scala adds it through libraries, Haskell ships three first-class strategies plus `DerivingVia`, which has no Scala equivalent at all.

The main thread is the one from the top: every cleanup in this list is something Scala 3 is in the middle of, that Haskell shipped a long time ago and built the rest of the ecosystem around. The cleanups will land in Scala. The ecosystem will take longer to catch up.

Two things this post deliberately did not weigh. One is the platform — the JVM is a real reason to write Scala, not because of language features. Java interop, the GraalVM AOT story, the large group of people who know how to run JVMs in production: these are not parts of the type-class comparison, and Haskell has its own answers, mostly worse on operational tooling and often better on the small-binary deployment side. The other is the developer experience — IntelliJ understands Scala in ways that no Haskell IDE currently understands Haskell. HLS has become impressive, but Scala still wins on autocomplete-through-implicits in a way that matters for hour-by-hour productivity. Neither of those changes the conclusions about the abstractions; both of them change which language is the right pick for a given team. Worth saying once, before the rest of the series pushes harder on the abstractions.

Part 3 is about `IO`. Cats Effect, ZIO, `Future`, and the thing all three are translating into the JVM: Haskell's `IO`, with referential transparency built in, `Resource` and `bracket` for cleanup, `STM` for shared state, and `async` for everything that `Future` was supposed to be. It's the post where the comparison stops being about machinery and starts being about whether the JVM was ever the right host language for the abstractions we've been pricing out here.
