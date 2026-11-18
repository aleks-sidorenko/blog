+++
title = "Haskell for Scala Developers: Part 2 — Type Classes and Implicits"
date = 2026-05-22
description = "For Scala developers picking up Haskell: type classes vs. given/using, instance lookup, coherence, higher-kinded types, the Functor/Applicative/Monad hierarchy, and deriving."
path = "blog/2026/05/haskell-for-scala-devs-02-typeclasses"
[taxonomies]
tags = ["haskell", "scala", "functional-programming", "haskell-for-scala-devs"]
categories = ["programming"]
+++

Scala does functions, ADTs, options, and newtypes well, and Haskell does them slightly better. The gap is small. With type classes, it gets wide.

I think the origin story of Scala implicits gets understated. We use them to thread context through our code, but that's not what they're _for_. Implicits were Scala's way of doing the work of Haskell's type classes in a language that doesn't have them. Wadler and Blott published the original Haskell type-class paper in 1989; Odersky designed Scala's implicit-parameter machinery explicitly so the same shape of code could be written on the JVM. The mechanism was reverse-engineered from the Haskell feature it was meant to imitate.

Scala 3's `given` / `using` is the cleanup. After every incoherence horror story the community has collected, the language renamed the keywords, narrowed the resolution rules, and tried to hide the implicit-conversion traps that were eating juniors alive. It's much better than what it replaced, and it's still trying to be something Haskell already is.

This post is about what you get when the feature is native: less ceremony, fewer traps, no implicit-conversion magic, and instance coherence by default. We'll start with the simplest case (`Eq`, `Show`, `Ord`, same words and same job in both languages), then cover resolution and coherence, the type-system feature both languages had to invent for this (HKTs), the `Functor`/`Applicative`/`Monad` ladder on our own type, and finally `deriving`. I'll assume you can read Cats fluently, so I won't re-teach the abstractions.

<!-- more -->

## A small anchor for the abstract bits

Most comparisons in this post are cleaner with a small type we've written ourselves. Stdlib types like `Either` or `Option` have their instances built in, so you can't see the seams. To watch how a `Functor`, an `Applicative`, and a `Monad` get added to a type, and where Haskell and Scala disagree about what that even means, we need something we control.

Call it `Outcome`. It's a two-case sum: either we have a valid value, or we have a list of reasons we don't. It's roughly the shape of Cats's `Validated`.

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

Two things to note. First, the failure side carries a `List[String]` rather than a single error. That matters later, when the `Applicative` instance will _accumulate_ those reasons across independent computations and the `Monad` instance won't. The tension between those two instances is the only deliberately interesting part of the type. Second, the Haskell version derives `Functor` right in the data declaration. The Scala version can't, so the instance has to be hand-written downstream. Hold onto that; it's foreshadowing.

When we need a type with record shape, I'll use a small `Payment` record. `Outcome` is for the part of the post where we wire the abstractions together. First come three sections of groundwork: naming, lookup, and HKTs. Then we add the instances to `Outcome` and watch the language disagree with itself.

## The vocabulary: Eq, Show, Ord, and friends

The simplest type classes are the ones nobody argues about. You want to print a value, compare two values for equality, or sort a list. Both languages have type classes for all three, and both use the same names. This is the most boring part of the comparison, which makes it a good baseline for the interesting parts.

### The Prelude versus Cats

In Haskell, `Eq`, `Show`, and `Ord` live in the `Prelude`, which every module imports by default. The laws (`(==)` is reflexive, `compare` is total, `show` produces something parseable in a non-binding way) are spelled out in the `base` library documentation, and every type that derives them is expected to honor them.

Scala has _two stacks_. The language has its own `==`, `hashCode`, `toString`, `Comparable`, and `Ordering`, inherited from Java, defined on `Any`, and lawless. Cats layers `cats.Eq`, `cats.Show`, and `cats.Order` on top of those, with proper laws, with `===`, `=!=`, and `compare` as typed operations, and with law-checking machinery in `cats.kernel.laws`. The Cats classes re-export the Haskell vocabulary into a JVM library, because the JVM standard library got there first with a worse version.

Cats is literally trying to give Scala what `Prelude` gives Haskell, as a library, because the language couldn't make it the default without breaking every existing program written to `Any.equals`.

### Deriving the basics

Take a small `Payment` type:

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

The Scala block is exactly how Cats wants you to do this: companion-object givens, one `Eq.fromUniversalEquals` per type, one `Show.fromToString`, and a hand-written `Order`, because the auto-derived ordering would compare by structure and we don't want that here. Scala 3's `derives` keyword can shorten the first part to `derives Eq, Show` for types whose Cats class supports it. In Cats 2.10, `Eq` and `Show` don't ship a `derived` method, so you write the `given`s anyway or bring in `kittens`. `derives` plus `kittens` is the modern path, and it's one more dependency.

The Haskell block does the same work in the `deriving` clauses of the data declarations. `Eq`, `Show`, and the default `Ord` are derived structurally; you write the one custom `Ord` you actually want. There are no companion objects, no `given` boilerplate, no imports beyond the `Prelude`, no library to pin to a version, and no decision about which derivation flavor to use until we get to `DerivingVia` later in this post.

All the machinery Scala attaches to its case classes (`equals`, `hashCode`, `Ordering`, plus Cats's `Eq`, `Show`, `Order` on top) is one keyword on one line in Haskell.

### `==` versus `===`

Cats introduced `===` because Scala 2's `==` was universally typed. `1 == "true"` compiled, returned `false`, and caused a small heartbreak when the bug showed up in production. Cats's `===` requires an `Eq[A]` for both sides, so any cross-type comparison fails at compile time. The Scala community has spent over a decade typing five extra characters to avoid this.

Scala 3 has been slowly fixing this. As of 3.4, comparing a primitive with a reference type (`1 == "1"`) is a compile error, with no opt-in needed. Cross-type comparison between unrelated case classes still compiles and still returns `false`. Closing that gap broadly is what `strictEquality` does as an opt-in, and what `===` does in Cats. Once the language work is finished, `===` will be the same thing the built-in operator already is.

Haskell never had the problem. `(==) :: Eq a => a -> a -> Bool` has been the signature since 1989. There is no universal equality. The only equality is the one the type class defines, and you can only compare types with `==` if their `Eq` instance is in scope. The discipline Cats had to add as a library, and that Scala 3 is slowly making the default, is the only option Haskell has ever had.

So the names, the shape, and the job are the same. What differs is the cost of using them. For the basics, it's "five lines of `given`s per type in Scala, zero lines in Haskell," and the gap grows as the type classes get less basic. That's the rest of the post.

## From `given`/`using` to `class`/`instance`

`Eq`, `Show`, and `Ord` are the easy case because the language ships them. When you want a type class that neither the language nor the standard library provides, you declare one. Both Scala and Haskell let you do that, but the mechanics differ.

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

Side by side, the lineage is easy to see. Scala wrote the same idea in slightly different syntax because it had to fit it into a language that already had classes and objects. The `given` keyword exists because `implicit val` was, in retrospect, calling the wrong thing implicit. `with` exists because `extends` would have read as inheritance on something that isn't an inheritance relationship. The grammar is hand-designed to avoid colliding with twenty years of Scala-as-OOP. The Haskell version is older than several of the things Scala had to negotiate with.

### How instances get found

The real differences start at the call site. When you write `greet(42)` in Scala or `greet (42 :: Int)` in Haskell, each compiler has to find the `Pretty[Int]` to use, and the lookup rules differ.

In Scala 3, the compiler searches, in order: arguments you passed explicitly (`greet(42)(using somePretty)` always works); givens in the current local scope; givens imported with `import SomeObject.given`; givens defined in the companion object of the type (`object Pretty` for `Pretty[Int]`, then `object Int`, though you can't actually define givens on built-in `Int`); and package-level givens visible from the current location. Specificity rules break ties when more than one candidate fits. The model Scala 3 settled on is documented, stable, and mostly predictable. It's also a list of five different ways the answer can be supplied, and they interact.

In Haskell, instance lookup is one rule: at any point in the program, an `instance Pretty Int` either exists or it doesn't, and if it exists, it's reachable through the import graph. There is no "instance in the companion object" or "instance brought in by an import alias". When you `import` a module, you get its type class declarations and all instances defined in it. When you `import` a module that defines a type, you get the type and all instances defined alongside it. The only question the compiler asks is "is there one?" Coherence is what keeps that question answerable.

The full module-system comparison (what `package`, `object`, `package object`, and companion objects all do in Scala, and how Haskell's single `module` construct collapses them) is a subject of its own. For now: Scala has five lookup paths because it has five places things can live. Haskell has one because it has one.

### Coherence and its cost

Here's what those rules lead to. Take the Scala class above and create two competing instances in unrelated places:

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

The Scala 3 compiler accepts this program, and it runs and prints `PrettyB(42)`, because the later import shadowed the earlier one in lexical scope. There's no warning. The same expression `summon[Pretty[Int]].pretty(42)` in a module that imported the two givens in the opposite order would print `PrettyA(42)` and still compile. This is the coherence problem. Every "we depend on two libraries that both provide a `Show` instance for `LocalDate`" bug has had this shape.

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

There's no way to make this program compile. A Haskell program has exactly one `Pretty Int` instance, ever. If two libraries define an instance for the same `(class, type)` pair, a program that wants to use both of them will not link. You pick one.

In return, you get what Scala can't promise: a call to `pretty x` always means the same thing, no matter who imported what, in what order. Pass the same `x` and you get the same string back, anywhere in the program. Scala's `summon[Pretty[Int]].pretty(42)` is referentially transparent _given the imports in scope_, which is a different and weaker promise.

The cost is real, though, and it has a name: **orphan instance**. An orphan is an `instance Pretty Foo` defined in a module that owns neither `Pretty` nor `Foo`. Orphans break the coherence guarantee: nothing prevents library A from defining `instance Pretty Int` and library B from defining a different `instance Pretty Int`, both as orphans. If a downstream project imports both, GHC refuses to build. With non-orphan instances, the only place to put `instance Pretty Foo` is the module that defines `Foo` (it travels with the type) or the module that defines `Pretty` (it travels with the class), and the import-graph reachability rule ensures the compiler always sees the same one.

GHC will warn you when you write an orphan, if you ask it to:

```
warning: [GHC-90177] [-Worphans]
    Orphan class instance: instance Pretty Int
    Suggested fix:
      Move the instance declaration to the module of the class or of the type, or
      wrap the type with a newtype and declare the instance on the new type.
```

The suggested fix is the whole discipline in one sentence. Put the instance with the type, put it with the class, or wrap the type in a `newtype` and declare the instance on the wrapper. Then it's no longer an orphan, because the wrapper belongs to your module. In practice, Haskell developers internalize this, and you almost never see orphans in production code outside a few valid cases (compatibility shims between libraries that can't import each other).

Scala 3 made the opposite bet. It accepts that multiple `given`s may be in scope and pushes the resolution into the language's lookup rules: companion objects, imports, package givens, locals. The model is more flexible. It also gives you the silent-winner behavior above, and it makes the programmer keep track of which import path produced which `given`. We'll see how Haskell's `module` plus `instance` does the work of several different Scala constructs. For now, it's the same problem with a different bet, and the bet matters more in shared, long-lived code you didn't write by yourself.

## Higher-kinded types

Both Scala and Haskell had to invent syntax for a particular kind of type: the kind whose values are themselves "containers" or "contexts" parameterized over another type. `List` of what? `Option` of what? `IO` returning what? You can write a function that doesn't care what's inside, but only if the language has a way to abstract over the wrapper.

Scala spells it `F[_]`:

```scala
def sequence[F[_]: Applicative, A](fs: List[F[A]]): F[List[A]]
```

Haskell uses a lowercase type variable in a place where the compiler can tell you mean a one-hole type constructor:

```haskell
sequence :: Applicative f => [f a] -> f [a]
```

These are the same signature. Both `F[_]` and `f` mean "any type that has one hole left in it": `List`, `Maybe` / `Option`, `IO`, `Either e` (with the `e` already filled), and our `Outcome` from earlier. The syntax differs because Scala has to disambiguate: in Scala, lowercase `f` is just a value name. Haskell keeps type variables and value names in separate namespaces, so it gets the "lowercase means variable" convention for free, and the _kind_ of the variable is inferred from where you use it.

`sequence` is the standard example. It takes a list of "context-wrapped" values and turns it into a single context wrapping a list of values. Concretely:

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

The implementation is identical: walk the list, combine the results with the `Applicative` instance, and short-circuit when the context says to. Once you look past the syntax, the signature is identical too. Either language can have this primitive only because both have the feature `F[_]` / `f` represents.

If you've ever wondered why Scala uses `F[_]` with the underscore in the type-parameter position, this is why. The underscore is the visible mark of a feature Haskell never needed special syntax for. In Haskell, `sequence :: Applicative f => [f a] -> f [a]` has an ordinary shape, and the compiler infers the _kind_ `* -> *` from the way `f` is used (`f a`, `f [a]`). If you want to see the inferred kind in GHCi, `:k Maybe` prints `Maybe :: * -> *`. That's the entire ceremony.

Variance (Scala's `+A` and `-A`, plus the question of when a `Functor` instance is even expected to exist for a given `F[_]`) is its own subject. So are `Contravariant` and the type-system roles machinery that Haskell uses to control what you can derive on a parameterized type.

## Functor, Applicative, Monad on a custom type

This is what the post has been building toward. Three type classes, in order of strength: `Functor` is "I can map a function over the wrapped value." `Applicative` is "I can apply a wrapped function to a wrapped value, and I can lift a plain value into the wrapper." `Monad` is "I can chain computations where each step's input depends on the previous step's output, and I get a context-respecting result back."

In both languages these classes are layered (`Monad` requires `Applicative`, which requires `Functor`), and in both, the standard library or Cats supplies instances for the obvious stdlib types and lets you declare your own. The interesting part is what happens on `Outcome`, because its natural `Applicative` and `Monad` fight.

### Functor

In Haskell, deriving `Functor` is one word in the data declaration:

```haskell
data Outcome a
  = Invalid [String]
  | Valid a
  deriving (Show, Eq, Functor)
```

`{-# LANGUAGE DeriveFunctor #-}` makes the compiler write the obvious `fmap`: leave `Invalid` alone, and apply the function to the contents of `Valid`. Some types need non-default behavior, but for `Outcome` the obvious thing is right.

Scala can't derive `Functor`. You write it:

```scala
given Functor[Outcome] with
  def map[A, B](fa: Outcome[A])(f: A => B): Outcome[B] = fa match
    case Outcome.Invalid(rs) => Outcome.Invalid(rs)
    case Outcome.Valid(a)    => Outcome.Valid(f(a))
```

This block, on every parameterized data type you ever ship, is the price of using Cats. Scala 3's `derives` keyword can shorten it with the right derivation library (`kittens`), but Cats's vocabulary doesn't ship the `derived` method out of the box. So you write the `Functor` by hand. Haskell developers stopped doing that in 2012, when `DeriveFunctor` shipped in GHC 7.4.

### Applicative

`Applicative` is where `Outcome` gets interesting. The natural instance accumulates errors. Combine two `Invalid`s and you get their reasons concatenated:

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

This is the satisfying instance. Validate the name, the email, and the password, and if all three fail, you get all three error messages back instead of just the first one. Cats's `Validated`, Haskell's `Validation`, and the validation pattern in every effect library all share this shape and this `Applicative`.

It has one problem, though.

### Monad and the disagreement

You can't write a lawful `Monad` instance for `Outcome` that keeps the accumulating behavior. The Monad laws require `ap` (the `Applicative` operation) to agree with `liftA2 id` implemented via `>>=`. With `Invalid r1 >>= \f -> Invalid r2 >>= \x -> pure (f x)`, the right-hand bind never runs, so `r2` is invisible and you get `Invalid r1`. The Monad-implied `<*>` short-circuits. The standalone accumulating `<*>` does not. They are different functions, and a lawful `Monad` requires them to be the same.

So you pick. The Haskell ecosystem picks for you: there's `Either e` (lawful Monad, short-circuits on failure) and `Validation e` (Applicative-only, accumulating). Cats does the same with `Either[E, A]` (Monad, short-circuit) and `Validated[E, A]` (Applicative-only, accumulating). `Outcome` as written above, with _both_ instances, does what the ecosystem warns against. It's useful as a teaching example, but not something you'd ship.

For the rest of this section, pretend `Outcome` is the short-circuiting variant: `Applicative` is derived from `Monad`, and errors stop at the first failure. That's what the `do`-block and the `for`-comprehension below assume.

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

With those in scope, a pipeline that says "parse two integers, sum them, error out on the first failure" is exactly what both languages built sugar for:

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

Scala's `for { x <- ... }` desugars to `flatMap` / `map` / `withFilter`. Haskell's `do { x <- ... }` desugars to `(>>=)` / `return`. The translations are mechanical. The same `for`-block runs over `Option`, `Either`, `List`, `IO`, `Outcome`, or any type whose `Monad` instance is in scope; the same `do`-block runs over any Haskell `Monad`. The notation has the same shape because the abstraction underneath has the same shape.

Both languages document the laws: `Functor` identity and composition, `Applicative` identity / homomorphism / interchange / composition, `Monad` left-identity / right-identity / associativity. Both rely on the implementer to honor them, both let you write instances that don't, and both ship a way to test that you haven't (`cats-laws` and `quickcheck-classes`, respectively). Where they differ, Haskell's coherence guarantee makes a broken instance more dangerous (it's broken _everywhere_ in your program) and also easier to find, because the single-instance rule means there's exactly one place to fix. And `IO` is a `Monad` in both languages: `do { line <- getLine; putStrLn line }` has the same shape as `for { line <- IO.readLine; _ <- IO.println(line) } yield ()`. That's the doorway to effects, a subject of its own.

## Deriving: from `derives` to `deriving via`

We've used `deriving` half a dozen times without remarking on it. Time to remark.

In Scala 3, the syntax is:

```scala
case class Payment(id: String, amount: BigDecimal)
  derives CanEqual
```

`derives X` is a Scala 3 keyword that tells the compiler "look for `X.derived` and use it to construct an instance." `CanEqual` from `scala.CanEqual` provides one, so `derives CanEqual` works out of the box. In cats-core 2.10, Cats's `Eq`, `Show`, and `Functor` don't, so you bring in `kittens` (the deriving sibling library) or write the `given`s by hand, as we did in the vocabulary section. `Magnolia` and `shapeless` are the older derivation engines; the modern story is `derives` plus `kittens`. The Shapeless-as-machinery era is fading out with Scala 3.

The Haskell equivalent sits in the data declaration itself and is older than most Scala features:

```haskell
{-# LANGUAGE DerivingStrategies #-}

data Payment = Payment { paymentId :: String, amount :: Double }
  deriving stock (Show, Eq)
```

`stock` is one of three strategies you can ask GHC to use, opt-in via the `DerivingStrategies` pragma. `stock` means "the compiler writes the instance based on the type's structure", which is what you get for `Show`, `Eq`, `Ord`, `Functor`, `Foldable`, `Traversable`, and `Generic`. `newtype` means "the wrapper borrows its underlying type's instance," at zero runtime cost, for any class at all:

```haskell
newtype Cents = Cents Int
  deriving stock (Show, Eq)
  deriving newtype (Num, Ord)
```

`Cents 5 + Cents 3` is `Cents 8`. The `Num` instance from `Int` is reused as-is, and the newtype's type discipline stays in place: you can't accidentally pass an `Int` where a `Cents` is wanted. Scala has no built-in equivalent. Scala 3's opaque types are zero-cost wrappers but can't reuse the underlying type's instances, so you re-declare each one in the module where the underlying representation is visible. `kittens` and clever derivation libraries can shorten this for stdlib classes. For user-defined classes, you write the instance again.

The third strategy is `anyclass`, which says "use the class's default-method definitions to derive the instance". It's useful when a class is designed for it, and rarer than `stock` or `newtype` in practice.

Then there's `DerivingVia`, which has no equivalent in Scala. Instead of borrowing an instance from the underlying type, you borrow it from a "stand-in" newtype that already has the instance you want.

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

`Score 1 <> Score 2` is `Score 3`. The `Sum Int` newtype's `Semigroup` instance combines by adding, and the `via (Sum Int)` clause tells the compiler that `Score`'s `Semigroup` should behave the same way. `pretty (Score 7)` is `"[Int(7)]"`. The `Bracketed Int` instance wraps the underlying `Pretty Int` output in brackets, and `via (Bracketed Int)` says that's what `Pretty Score` should mean.

`Bracketed` is the stand-in. It exists only to carry that "wrap in brackets" `Pretty` instance, available to any type that can be coerced to its representation. Cats developers spend years asking for this: a way to say "I want this instance, _but_ derived this way, not that way." Haskell ships it as a one-line declaration.

In Scala, deriving is a language feature that's still maturing through libraries. Each Cats class needs a derivation library to plug into the `derives` keyword, and each new pattern (DerivingVia-style instance reuse, generic JSON encodings, ORM mappings) needs its own library design. Haskell's compiler was built on the assumption that you'd want this. `stock` derives the obvious instances for the obvious classes. `newtype` is one keyword. `DerivingVia` is two. The ecosystem _starts_ from "your types should mostly write themselves" and lets you opt out where you want custom behavior.

There's a deeper layer under all this (`GHC.Generics` is the engine underneath `stock` derivation, and Template Haskell is the metaprogramming back door), but that's a subject of its own.

## Where this is going

At the top I claimed that implicits started life as a way to do Haskell's type-class job in a language that didn't have type classes. We've now seen that play out in six places:

- `Eq`, `Show`, `Ord`: same names and shape. Both languages have the words, and in Scala you write the boilerplate.
- `given` / `using` versus `class` / `instance`: five different lookup paths versus one.
- Coherence: Scala silently picks a winner; Haskell forbids the ambiguity at the cost of policing orphans.
- HKTs: both languages had to invent the syntax, and Haskell needed less of it.
- `Functor` / `Applicative` / `Monad`: same hierarchy, same laws, same `do` / `for` sugar over the same `>>=` / `flatMap`.
- Deriving: Scala adds it through libraries; Haskell ships three first-class strategies plus `DerivingVia`, which has no Scala equivalent at all.

Every cleanup on this list is something Scala 3 is still in the middle of, and something Haskell shipped a long time ago and built the rest of its ecosystem around. The cleanups will land in Scala. The ecosystem will take longer to catch up.

This post deliberately left two things out. The first is the platform. The JVM is a real reason to write Scala, and it has nothing to do with language features. Java interop, the GraalVM AOT story, and the large pool of people who know how to run JVMs in production aren't part of the type-class comparison. Haskell has its own answers, mostly worse on operational tooling and often better for small-binary deployment. The second is developer experience. IntelliJ understands Scala in ways no Haskell IDE currently understands Haskell. HLS has become impressive, but Scala still wins on autocomplete through implicits, and that matters for hour-by-hour productivity. Neither of these changes the conclusions about the abstractions, but both change which language is the right pick for a given team.

---

*Part of the **Haskell for Scala Developers** series:*

1. [Functions and Data](@/blog/2026-05-haskell-for-scala-devs-01-basics.md)
2. **Type Classes and Implicits**
3. [Effects and Concurrency](@/blog/2026-06-haskell-for-scala-devs-03-effects.md)
4. [Objects and Modules](@/blog/2026-07-haskell-for-scala-devs-04-oop.md)
5. [Optics and Deriving](@/blog/2026-08-haskell-for-scala-devs-05-optics.md)
