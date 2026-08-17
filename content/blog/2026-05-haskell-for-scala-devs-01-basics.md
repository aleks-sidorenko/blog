+++
title = "Haskell for Scala Developers: Part 1 — Functions and Data"
date = 2026-05-05
description = "For working Scala developers picking up Haskell: functions, data, pattern matching, options, and newtypes — the parts you already write, and what falls away when you don't have to share a language with the JVM."
path = "blog/2026/05/haskell-for-scala-devs-01-basics"
[taxonomies]
tags = ["haskell", "scala", "functional-programming", "haskell-for-scala-devs"]
categories = ["programming"]
+++

There's a popular way to write this kind of post — a feature-by-feature comparison table, with checkmarks and a sentence per row. I'm not going to do that. What I want to do instead is take the parts of Scala that you already write idiomatically — case classes, sealed traits, `Option`, `Either`, the occasional `extends AnyVal` for a typed id — and show you what happens when the language stops apologizing for them.

That's the main thread here. Most of what made me love Scala is _exactly_ what Haskell gives you, minus the JVM cost, minus the OOP escape hatches, and minus the long-running argument inside the Scala community about what good Scala even looks like. If you want the longer version of why I'm writing this at all, it's in [The Rise and Fall of Scala](@/blog/2026-01-the-rise-and-fall-of-scala.md).

This one is the easy one. Functions, data, pattern matching, options, newtypes — all the things you already type twenty times a week. The translation is mostly mechanical. The interesting part is the small set of frictions that disappear when the language stops compromising on them.

<!-- more -->

If you've never written a line of Haskell at all, [Getting Started with Haskell](@/blog/2026-02-getting-started-with-haskell.md) is a friendlier starting point than this post — read that first, then come back.

## The anchor: a tiny payment model

Most of the post is built on one example, so let's introduce it early. A payment with an id, an amount, a currency, and a status — pending, settled, or failed with a reason. Two operations: settle it, and apply a percentage discount.

Here it is in Scala 3:

```scala
enum Currency:
  case USD, EUR, UAH

enum Status:
  case Pending
  case Settled
  case Failed(reason: String)

case class Payment(
  id: String,
  amount: BigDecimal,
  currency: Currency,
  status: Status,
)

def settle(p: Payment): Payment =
  p.status match
    case Status.Pending     => p.copy(status = Status.Settled)
    case Status.Settled     => p
    case Status.Failed(_)   => p

def applyDiscount(p: Payment, percent: BigDecimal): Payment =
  p.copy(amount = p.amount * (1 - percent / 100))
```

And in Haskell:

```haskell
data Currency = USD | EUR | UAH deriving (Show, Eq)

data Status
  = Pending
  | Settled
  | Failed String
  deriving (Show, Eq)

data Payment = Payment
  { paymentId :: String
  , amount    :: Double
  , currency  :: Currency
  , status    :: Status
  } deriving (Show, Eq)

settle :: Payment -> Payment
settle p = case status p of
  Pending  -> p { status = Settled }
  Settled  -> p
  Failed _ -> p

applyDiscount :: Payment -> Double -> Payment
applyDiscount p percent =
  p { amount = amount p * (1 - percent / 100) }
```

(I've used `Double` for the amount to keep the snippet small. Real money wants a fixed-precision type — `Data.Fixed` or one of the `Decimal` packages — but that's not a Scala-versus-Haskell story, just a "don't represent money as a float" story.)

Three observations before we move on.

First, the shapes line up. Scala's `enum` becomes Haskell's `data`. `case class` becomes a `data` declaration with named fields. The methods become plain top-level functions, because that's where they were going to end up after you stopped anyone from putting them inside the class.

Second, Haskell is the lighter syntax. No `case` keyword for branches. No parens around constructor patterns. No `copy(field = ...)`; the same idea is written `p { field = ... }`. The `deriving` line gives you `Show` and `Eq` for free, the same way `case class` does in Scala — you just have to ask for it explicitly, which makes it easier to reason about what you're getting.

Third — and this is the one worth pausing on — _neither version uses inheritance, mutable state, or null_. The Scala you'd actually write for this domain is already 90% Haskell. You just don't see it because the other 10% gives you vocabulary that Haskell never needed to invent.

We'll keep coming back to this `Payment` type. Everything below is either a smaller example to illustrate a specific point or a piece of the model with one extra thing happening to it.

## Functions: currying, partial application, composition

In Scala you have two ways to spell a function value. There's `def`, which is a method (or top-level function in Scala 3), and there's `val` of a function type:

```scala
def add(a: Int, b: Int): Int = a + b
val addV: (Int, Int) => Int = (a, b) => a + b
```

Both work fine. The `val` form gives you a value you can pass around without an `_` underscore eta-expansion. In Haskell that distinction does not exist:

```haskell
add :: Int -> Int -> Int
add a b = a + b
```

That's the only form. There is no method-versus-value tension because there are no methods. A function is a value, full stop, and the type signature lives on its own line above the implementation by convention.

Now, the type. Scala's `(Int, Int) => Int` is Haskell's `Int -> Int -> Int`. They are not the same shape. Scala's reads as "a function of two `Int`s returning an `Int`." Haskell's reads as "a function of one `Int` returning a function from `Int` to `Int`." Haskell's type _is_ curried by default. Every function of more than one argument is, mechanically, a chain of single-argument functions. There's nothing to turn on.

This sounds like a small thing. It's not. It means partial application is the default. In Scala, you do something like:

```scala
val plusTen: Int => Int = add(10, _)
val addOne  = addV.curried(1)   // .curried gives you the chain version
```

You can do it. You have two slightly different mechanisms for it (the underscore form and `.curried`). And whether they're available and how they read depends on whether you started from `def` or `val`.

In Haskell:

```haskell
plusTen :: Int -> Int
plusTen = add 10

addOne :: Int -> Int
addOne = add 1
```

You apply some of the arguments and get back a function. There is no decision to make.

The same difference shows up in composition. Scala has `andThen` and `compose` defined on `Function1`:

```scala
val double: Int => Int = _ * 2
val square: Int => Int = x => x * x

val doubleThenSquare = double andThen square  // (x*2)^2
val squareThenDouble = double compose square  // (x^2)*2
```

`andThen` is left-to-right, `compose` is right-to-left. They live on the function value itself. If you want to compose a `def`-style function, you eta-expand it first.

In Haskell, the operator `.` is right-to-left composition, like math. There's also `(>>>)` for left-to-right when that reads better:

```haskell
import Control.Category ((>>>))

doubleThenSquare = square . double      -- right-to-left, math style
doubleThenSquareLR = double >>> square  -- left-to-right, pipeline style
```

There is no eta-expansion step. Functions compose with each other directly because they all have the same shape: one argument in, one thing out.

Two more bits of the function toolkit are worth knowing because you'll hit them in the first hour of reading any real Haskell codebase. The first is _operator sections_ — partially-applying an operator by leaving one side blank:

```haskell
addOne     = (+ 1)        -- :: Int -> Int
half       = (/ 2)        -- :: Double -> Double
isPositive = (> 0)        -- :: Int -> Bool
firstFive  = take 5       -- partial application, normal function
```

Scala has no direct equivalent — you'd write a lambda `_ + 1`. The Haskell version is shorter and reads as "the function from x to x + 1," which is closer to how mathematicians wrote it long before any of us showed up. The second tool is `flip`, which swaps the order of a function's first two arguments:

```haskell
applyDiscount :: Payment -> Double -> Payment
-- flip applyDiscount :: Double -> Payment -> Payment
process :: Payment -> Payment
process = settle . flip applyDiscount 10
```

`flip` exists precisely because argument order matters for composition. When you can't change the function's signature, you can change the way you call it. Scala has nothing like this in the standard library — you'd write a lambda — but the need also rarely comes up, because `andThen`/`compose` are method chains rather than dataflow primitives.

Once you absorb that every function is curried and composition is a tiny operator, a lot of Scala patterns flatten out. The `applyDiscount(_, 10) andThen settle` pipeline you might write at the top of a method becomes, in Haskell:

```haskell
process :: Payment -> Payment
process = settle . applyDiscount 10  -- wait, argument order
```

Actually this reveals a real ergonomic difference. `applyDiscount` in our anchor takes the payment first and the percent second — convenient for `p.copy`-style code. In Haskell, you tend to put "the thing being transformed" _last_, so functions compose neatly. That's a tiny but constant style adjustment: argument order in Haskell is decided more by composition than by readability of a single call site. If we redefined:

```haskell
applyDiscount :: Double -> Payment -> Payment
applyDiscount percent p = p { amount = amount p * (1 - percent / 100) }
```

then `settle . applyDiscount 10` reads correctly, and you can just keep stacking transformations. Scala can do this — it's just not where the language nudges you.

The takeaway is small but real. Currying, partial application, and composition aren't features in Haskell. They're the shape of the language. In Scala they are features that mostly work. The gap between "mostly works" and "is the default" sounds like a footnote and ends up being one of the bigger ergonomic surprises.

### A side note on bindings

One thing that surprises Scala developers reading Haskell for the first time: local bindings are usually written _after_ the expression that uses them, in a `where` clause:

```haskell
total :: [Payment] -> Double
total payments = sum amounts
  where
    amounts = map amount payments
```

The Scala instinct is to write the `let amounts = ...` first and `sum amounts` after. Haskell lets you do that too:

```haskell
total :: [Payment] -> Double
total payments =
  let amounts = map amount payments
  in sum amounts
```

Both are common. `where` reads top-down at the use site (you state the result, then explain its parts); `let` reads bottom-up (you build pieces, then combine them). Working Haskell freely mixes them. This is one of those small style choices that takes a few weeks of reading to feel natural and then becomes invisible. The Scala equivalent is basically `def` with a `private def` helper next to it, or a `val` bound at the top of the method body — the moves are the same, only the syntax is different.

## Data: case classes, sealed traits, ADTs

If there's a Scala feature where the comparison is most flattering to Scala, it's data modeling. Case classes and sealed traits are excellent. They're also, mechanically, what every modern functional language calls _algebraic data types_ — products and sums. Scala's case classes are the products. Sealed traits and Scala 3 enums are the sums.

Here's a small product in Scala — a record:

```scala
case class User(id: String, name: String, age: Int)
```

In Haskell, it's `data` with named fields:

```haskell
data User = User
  { userId :: String
  , name   :: String
  , age    :: Int
  } deriving (Show, Eq)
```

A few small differences worth understanding before we go further.

**Field accessors are top-level functions.** When you declare `User { userId :: String, name :: String, age :: Int }`, Haskell creates three top-level functions: `userId :: User -> String`, `name :: User -> String`, `age :: User -> Int`. They live in the module's namespace. Try to declare another type with a `name` field in the same module and you'll get a duplicate-binding error. Scala developers find this jarring at first — your case class fields are _not_ methods you call dot-style; they're plain functions you apply to a value. The community has built three responses: prefix conventions (`userId`, `userName`, `userAge` — very common in real codebases), the `DuplicateRecordFields` extension (allows the conflict but requires disambiguation at use sites), and the more recent `OverloadedRecordDot` extension (lets you write `user.name` after all). The pain here has produced one of the more interesting libraries in the language — the optics story is one of its own.

**`deriving` is opt-in.** The `deriving (Show, Eq)` line gives you free instances for printing and equality, the same way `case class` gives them by default in Scala. The difference is that Haskell asks you to ask. I prefer that. It makes the cost of "what am I getting?" visible — you don't have to remember whether `Show` is "a printable form" or "a JSON encoding"; you just look at the line.

Update syntax is the same idea, slightly different spelling:

```scala
val u = User("u-1", "Ada", 30)
val older = u.copy(age = 31)
```

```haskell
let u = User "u-1" "Ada" 30
    older = u { age = 31 }
```

The pattern is identical: take an existing record, produce a new record with one field changed. Scala spells it as a method called `copy`; Haskell spells it as record-update syntax with braces.

Now sums. Scala 3 has `enum` (and Scala 2 has sealed trait hierarchies, which work the same way underneath):

```scala
enum Shape:
  case Circle(radius: Double)
  case Rect(width: Double, height: Double)
  case Triangle(a: Double, b: Double, c: Double)
```

Haskell:

```haskell
data Shape
  = Circle Double
  | Rect Double Double
  | Triangle Double Double Double
  deriving (Show, Eq)
```

Almost line for line. The Scala version has named arguments per case; the Haskell version uses positional fields. (Haskell can do named fields per constructor too, though it's less idiomatic for small sum types.) Each case in Scala becomes a constructor in Haskell, with the same arity.

Pattern matching is the core of working with this stuff. Scala uses `match`/`case`:

```scala
def area(s: Shape): Double = s match
  case Shape.Circle(r)         => math.Pi * r * r
  case Shape.Rect(w, h)        => w * h
  case Shape.Triangle(a, b, c) =>
    val p = (a + b + c) / 2
    math.sqrt(p * (p - a) * (p - b) * (p - c))
```

Haskell uses `case ... of` (or, more commonly, multiple equations of the function on its constructor pattern):

```haskell
area :: Shape -> Double
area (Circle r)         = pi * r * r
area (Rect w h)         = w * h
area (Triangle a b c)   =
  let p = (a + b + c) / 2
  in sqrt (p * (p - a) * (p - b) * (p - c))
```

The forms are interchangeable. Multiple equations is the more common Haskell style — each line is "when called with this shape, return this." It reads close to a mathematical definition.

Both languages warn on non-exhaustive matches. Both can be configured to error. Both will catch you if you add a fourth constructor and forget to update a `match`. The mechanism is the same; the diagnostics are similarly useful.

A small idiom you'll see in real Haskell — combining patterns at use sites. Settle a list of payments:

```haskell
settleAll :: [Payment] -> [Payment]
settleAll = map settle
```

That's it. `map` over a list, `settle` on each one. The Scala equivalent is the same shape (`payments.map(settle)`), but it's worth noting how much shorter the Haskell _function definition_ gets when you write it point-free: no `payments` argument, no `=>`, no parens. The function _is_ the composition. Once or twice you'll write `settleAll payments = map settle payments` instead, and that's also fine — point-free is a style, not a rule.

If you want to filter only the failures and extract the reasons:

```haskell
failureReasons :: [Payment] -> [String]
failureReasons payments =
  [ reason | p <- payments, Failed reason <- [status p] ]
```

That's a _list comprehension_ — Haskell has them, and they look almost identical to Scala's `for ... yield`. The pattern `Failed reason <- [status p]` matches only when the wrapped value is a `Failed`, ignoring the others. Pattern matching shows up everywhere it's useful, not just inside `case` blocks.

Where the comparison gets interesting is the parts of Scala's data story that don't carry over because Haskell never needed them. There is no `extends AnyRef`. There is no `override def equals`. There is no path where someone on your team subclasses `Payment` and quietly overrides `applyDiscount` to silently catch exceptions. The data is the data; the operations are functions. The OOP escape hatch isn't there.

If you've spent any real time in Scala, you know what I'm talking about. The escape hatch is rare in good Scala code. But "rare" is not "structurally absent," and rare-but-possible is a cost you pay during code review forever. In Haskell that conversation simply doesn't come up. The reason Haskell can have a smaller toolkit for this stuff isn't that it has fewer features — it's that there's no second job for those features to do.

## Option, Either, and the absence of null

You already know `Option[A]` and `Either[L, R]`. Haskell calls them `Maybe a` and `Either l r`.

Here they are next to each other:

```scala
enum Currency:
  case USD, EUR, UAH

def parseCurrency(s: String): Option[Currency] = s.toUpperCase match
  case "USD" => Some(Currency.USD)
  case "EUR" => Some(Currency.EUR)
  case "UAH" => Some(Currency.UAH)
  case _     => None

def divide(a: Int, b: Int): Either[String, Int] =
  if b == 0 then Left("division by zero")
  else Right(a / b)
```

```haskell
data Currency = USD | EUR | UAH deriving (Show, Eq)

parseCurrency :: String -> Maybe Currency
parseCurrency s = case map toUpper s of
  "USD" -> Just USD
  "EUR" -> Just EUR
  "UAH" -> Just UAH
  _     -> Nothing

divide :: Int -> Int -> Either String Int
divide _ 0 = Left "division by zero"
divide a b = Right (a `div` b)
```

The shapes are identical. `Some` becomes `Just`, `None` becomes `Nothing`, `Left` and `Right` keep their names. `Either` is right-biased in both languages — `Right` is success, `Left` is failure. (Scala 2.11 and earlier had an unbiased `Either`; if you're on a fresh codebase, this isn't a concern, but it is a real thing the older Scala docs will confuse you on.)

`getOrElse` is `fromMaybe`:

```scala
val c: Currency = parseCurrency("usd").getOrElse(Currency.UAH)
```

```haskell
c :: Currency
c = fromMaybe UAH (parseCurrency "usd")
```

`map` and `flatMap` work on both, with the same semantics. In Haskell `flatMap` is spelled `>>=` (or `flip fmap` for the `Functor` direction, but you'll usually use `do` notation or `>>=`):

```scala
val n: Option[Int] =
  Some(10).map(_ + 1).flatMap(x => if x > 0 then Some(x * 2) else None)
// Some(22)
```

```haskell
n :: Maybe Int
n = Just 10
  >>= \x -> Just (x + 1)
  >>= \x -> if x > 0 then Just (x * 2) else Nothing
-- Just 22
```

Once you get used to `>>=` (it's `flatMap`, written infix), the chain reads almost like the Scala one.

If the `>>=` chain feels heavy, Haskell has a syntactic sugar for exactly this — `do` notation, which is the rough equivalent of Scala's `for`-comprehensions:

```haskell
n :: Maybe Int
n = do
  x <- Just 10
  let y = x + 1
  if y > 0 then Just (y * 2) else Nothing
```

Same expression, more readable. The `do` block desugars to the same `>>=` chain you'd write by hand. Two things to note for a Scala developer: first, `do` works for _anything_ that's a monad — `Maybe`, `Either`, lists, `IO`, parsers — exactly like `for` works over anything with `flatMap`/`map` in Scala. Second, Scala's `for`-comprehension is a bit more powerful in one direction (it desugars to `withFilter` for `if` guards on `Option`/`Either`-style) and weaker in another (it can't desugar `let` bindings as nicely as `do`). The differences are footnotes; the idea is the same.

A few real differences worth flagging.

There's no direct `Try[A]` in Haskell. The Scala instinct of "wrap a thing that might throw" doesn't translate one-to-one because exceptions are an effect, and Haskell tracks effects in the type. The honest equivalent is `IO (Either SomeException a)` plus the `MonadThrow`/`MonadCatch` machinery — a concern for effectful code, not for plain data modeling.

A pattern you'll see immediately, though, is using `Either` with a domain-specific error type. Where Scala devs reach for `Either[Throwable, A]` (or stack errors onto a sealed trait), Haskell makes the data type cheap enough that you just do that everywhere:

```haskell
data ParseError
  = EmptyInput
  | UnknownCurrency String
  deriving (Show, Eq)

parseCurrencyStrict :: String -> Either ParseError Currency
parseCurrencyStrict ""  = Left EmptyInput
parseCurrencyStrict s   = case map toUpper s of
  "USD" -> Right USD
  "EUR" -> Right EUR
  "UAH" -> Right UAH
  other -> Left (UnknownCurrency other)
```

Same shape as the Scala version. The cultural difference is that "make a small ADT for the error" is the _first_ thing you reach for in Haskell, not the third. Sealed traits make this perfectly possible in Scala too; the question is whether your codebase actually does it. In Haskell, the answer is almost always yes, because the cost of declaring a new type is so low.

There is no `null` in Haskell. None. Anywhere. The bottom value `undefined` exists for the same reason `???` does in Scala (placeholder during development), but you cannot store one in a typed reference and pretend you didn't. The "is this nullable?" review comment that shows up over and over in a long Scala career simply doesn't get written.

In short: the gap is mostly naming and syntax. The philosophical difference is null itself. Once you stop writing optional types as a defensive habit and start writing them as a domain choice, this is one of those cases where Haskell isn't doing anything cleverer than Scala — it's just been doing the same thing without the legacy.

## Newtypes are free, opaque types are almost

Here's a pattern you write all the time:

```scala
case class PaymentId(value: String)
case class UserId(value: String)
```

Two strings, but the type system keeps them apart. You can't pass a `UserId` where a `PaymentId` is expected. Worth it. The cost is a wrapper object on the heap, which the JVM may or may not optimize away. There's an `extends AnyVal` you can add, with caveats and edge cases that would need their own footnote-of-a-footnote, and which still doesn't fully give you the zero-cost guarantee in every situation.

Scala 3 fixed this with opaque types:

```scala
object Ids:
  opaque type PaymentId = String
  opaque type UserId    = String

  object PaymentId:
    def apply(s: String): PaymentId = s
    extension (p: PaymentId) def value: String = p

  object UserId:
    def apply(s: String): UserId = s
    extension (u: UserId) def value: String = u
```

`PaymentId` is a `String` at runtime. The compiler treats it as a distinct type _outside_ the `Ids` module, and as a `String` _inside_ it. You get the type discipline at no runtime cost. This is genuinely good. It's also a little awkward: instances (think `Show`, `Encoder`, `Ordering`) need to be defined inside the wrapper module or worked around through `given` instances elsewhere. Deriving on opaque types is messy.

Haskell's `newtype` is the same idea, but it has been there since 1990 and the surrounding language assumes you'll use it:

```haskell
newtype PaymentId = PaymentId { unPaymentId :: String }
  deriving (Show, Eq, Ord)

newtype UserId = UserId { unUserId :: String }
  deriving (Show, Eq, Ord)
```

Three lines. Zero runtime cost, guaranteed. `Show`, `Eq`, `Ord` derive automatically — and not just because the type is "kind of a string" — because of `GeneralizedNewtypeDeriving`, which says: if `String` had this instance, `PaymentId` (which _is_ a `String` at runtime) gets the same one. Need a JSON encoder? Derive `ToJSON`. Need `Hashable`? Derive `Hashable`. The pattern was built into the language so deeply that it's almost free to use.

There's also a convention worth knowing: the _smart constructor_ pattern. You declare the newtype, but you only export a function that builds it, not the constructor itself. That gives you a value-level invariant the type system can rely on:

```haskell
module Money (Money, mkMoney, unMoney) where

newtype Money = Money Double  -- Money constructor not exported
  deriving (Show, Eq, Ord)

mkMoney :: Double -> Maybe Money
mkMoney x | x >= 0    = Just (Money x)
          | otherwise = Nothing

unMoney :: Money -> Double
unMoney (Money x) = x
```

Outside this module, no one can build a `Money` with a negative value. Scala devs reach for `private constructor` plus a companion-object `apply` to do the same thing — slightly more ceremony, same shape. The difference is that, in Haskell, the _language's module system_ enforces the boundary; in Scala, it's the OOP visibility rules layered on top of it. Same result, different machinery.

If you want to be more selective with deriving — say, your `Score` newtype should combine via addition rather than via the underlying `Int`'s default — there's `DerivingVia`:

```haskell
{-# LANGUAGE DerivingVia #-}
import Data.Monoid (Sum(..))

newtype Score = Score Int
  deriving (Eq, Ord, Show)
  deriving Semigroup via (Sum Int)
  deriving Monoid    via (Sum Int)
```

`Sum Int` is a stdlib newtype around `Int` whose `Semigroup` instance is "combine by adding." The `via (Sum Int)` clause says "treat my `Score` as a `Sum Int` for these instances, but keep its own identity for everything else." Now `Score 1 <> Score 2` is `Score 3` — addition — and `mempty :: Score` is `Score 0`.

The same pattern scales to anything. JSON encodings, ORM mappings, default printer formats — all become "pick a stand-in and inherit its instance." This is a feature Scala developers spend years asking for: the ability to say "I want this instance, _but_ derived this way, not that way." Haskell ships it as a one-line declaration. It does for type class instances what `newtype` did for nominal typing: makes a heavyweight thing lightweight enough to use casually.

In a `Payment` record, the typed ids slot in directly:

```haskell
data Payment = Payment
  { paymentId :: PaymentId
  , ownerId   :: UserId
  , amount    :: Double
  } deriving (Show, Eq)
```

Now a function with the wrong-order arguments:

```haskell
-- Payment uid pid 0  -- type error, would not compile
```

Same guarantee Scala 3's opaque types give you, with no module tricks, with full derivation, and with the rest of the ecosystem already designed around it. You'll see `newtype` everywhere in Haskell. Not just for ids — for every place where two values that share a runtime representation should be kept apart by the type system. `newtype Sum a = Sum a` for monoidal addition. `newtype Product a = Product a` for the multiplicative version. `newtype Compose f g a = Compose (f (g a))`. The cost of introducing a new type is so low that the language has settled into using it as a _modelling_ tool, not a workaround.

This is the main thread of the whole post in miniature. Scala has the right idea — opaque types are the right idea. The language just hasn't been built around them long enough for the rest of the toolkit to assume they exist. In Haskell, every library, every class instance, every piece of generic code already assumes that you'll wrap your `String`s when you need to. The cost of doing the right thing has been driven to zero. That comparison gets even more one-sided once you reach deriving and `DerivingVia`.

## Where this is going

The thesis at the top was that Scala's case classes and sealed traits are already Haskell's ADTs in disguise — and that what changes is what drops away when the language commits. We've now seen this in five small places. Functions are curried by default; partial application is just syntax. Records and sums are the same shapes you write in Scala, minus the OOP attachments. `Option` and `Either` carry over almost verbatim, minus `null`. `newtype` is what `opaque type` will be in another decade of ecosystem work.

None of this is the headline. It's the place where the comparison is most flattering to Scala — because Scala has been getting these things right for a long time, and Haskell's lead here is honestly small. If you've already trained your hands on case classes and sealed traits, picking up the equivalent Haskell forms is more like noticing where the friction was than learning a new toolkit.

Every snippet above was checked against a compiler before it appeared here.

If you read this far and the only thought is _"yeah, none of that is news,"_ — good. That's the whole point of starting here.

---

*Part of the **Haskell for Scala Developers** series:*

1. **Functions and Data**
2. [Type Classes and Implicits](@/blog/2026-05-haskell-for-scala-devs-02-typeclasses.md)
3. [Effects and Concurrency](@/blog/2026-06-haskell-for-scala-devs-03-effects.md)
4. [Objects and Modules](@/blog/2026-07-haskell-for-scala-devs-04-oop.md)
5. [Optics and Deriving](@/blog/2026-08-haskell-for-scala-devs-05-optics.md)
