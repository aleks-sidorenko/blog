+++
title = "Haskell for Scala Developers: Part 1 — Functions and Data"
date = 2026-05-05
description = "For working Scala developers picking up Haskell: functions, data, pattern matching, options, and newtypes, and what falls away once the language doesn't have to share the JVM."
path = "blog/2026/05/haskell-for-scala-devs-01-basics"
[taxonomies]
tags = ["haskell", "scala", "functional-programming", "haskell-for-scala-devs"]
categories = ["programming"]
+++

The usual way to write this kind of post is a feature-by-feature comparison table, with checkmarks and a sentence per row. I'm skipping that. Instead I'll take the parts of Scala you already write idiomatically (case classes, sealed traits, `Option`, `Either`, the occasional `extends AnyVal` for a typed id) and show what happens when the language stops apologizing for them.

Most of what made me love Scala is _exactly_ what Haskell gives you, minus the JVM cost, the OOP escape hatches, and the long-running argument inside the Scala community about what good Scala even looks like. If you want the longer version of why I'm writing this at all, it's in [The Rise and Fall of Scala](@/blog/2026-01-the-rise-and-fall-of-scala.md).

This part is the easy one: functions, data, pattern matching, options, and newtypes, all things you already type twenty times a week. The translation is mostly mechanical. What's interesting is the handful of frictions that disappear when the language stops compromising on them.

<!-- more -->

If you've never written a line of Haskell at all, [Getting Started with Haskell](@/blog/2026-02-getting-started-with-haskell.md) is a friendlier starting point than this post. Read that first, then come back.

## The anchor: a tiny payment model

Most of the post is built on one example, so I'll introduce it early: a payment with an id, an amount, a currency, and a status (pending, settled, or failed with a reason). It has two operations: settle it, and apply a percentage discount.

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

(I've used `Double` for the amount to keep the snippet small. Real money wants a fixed-precision type (`Data.Fixed` or one of the `Decimal` packages), but that's not a Scala-versus-Haskell story, just a "don't represent money as a float" story.)

Three observations before we move on.

First, the shapes line up. Scala's `enum` becomes Haskell's `data`. `case class` becomes a `data` declaration with named fields. The methods become plain top-level functions, because that's where they were going to end up after you stopped anyone from putting them inside the class.

Second, Haskell's syntax is lighter. No `case` keyword for branches. No parens around constructor patterns. No `copy(field = ...)`; the same idea is written `p { field = ... }`. The `deriving` line gives you `Show` and `Eq` for free, the same way `case class` does in Scala. You just have to ask for them explicitly, which makes it easier to see what you're getting.

Third, and most important: _neither version uses inheritance, mutable state, or null_. The Scala you'd actually write for this domain is already 90% Haskell. You don't see it because the other 10% gives you vocabulary that Haskell never needed to invent.

We'll keep coming back to this `Payment` type. Everything below is either a smaller example for a specific point or a piece of this model with one extra thing added.

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

That's the only form. There are no methods, so there's no method-versus-value tension. A function is a value, and by convention the type signature sits on its own line above the implementation.

Now the type. Scala's `(Int, Int) => Int` is Haskell's `Int -> Int -> Int`, but they are not the same shape. Scala's reads as "a function of two `Int`s returning an `Int`." Haskell's reads as "a function of one `Int` returning a function from `Int` to `Int`." Haskell's type _is_ curried by default: every function of more than one argument is, mechanically, a chain of single-argument functions. There's nothing to turn on.

That sounds small, but it means partial application is the default. In Scala, you do something like:

```scala
val plusTen: Int => Int = add(10, _)
val addOne  = addV.curried(1)   // .curried gives you the chain version
```

It works, but you have two slightly different mechanisms (the underscore form and `.curried`), and which one is available and how it reads depends on whether you started from `def` or `val`.

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

Two more parts of the toolkit show up in the first hour of reading any real Haskell codebase. The first is _operator sections_: partially applying an operator by leaving one side blank:

```haskell
addOne     = (+ 1)        -- :: Int -> Int
half       = (/ 2)        -- :: Double -> Double
isPositive = (> 0)        -- :: Int -> Bool
firstFive  = take 5       -- partial application, normal function
```

Scala has no direct equivalent; you'd write a lambda `_ + 1`. The Haskell version is shorter and reads as "the function from x to x + 1," which is closer to how mathematicians wrote it long before any of us showed up. The second is `flip`, which swaps the order of a function's first two arguments:

```haskell
applyDiscount :: Payment -> Double -> Payment
-- flip applyDiscount :: Double -> Payment -> Payment
process :: Payment -> Payment
process = settle . flip applyDiscount 10
```

`flip` exists because argument order matters for composition. When you can't change a function's signature, you can change how you call it. Scala's standard library has nothing like it (you'd write a lambda), but the need rarely comes up there, because `andThen`/`compose` are method chains rather than dataflow primitives.

Once you absorb that every function is curried and composition is a tiny operator, a lot of Scala patterns flatten out. The `applyDiscount(_, 10) andThen settle` pipeline you might write at the top of a method becomes, in Haskell:

```haskell
process :: Payment -> Payment
process = settle . applyDiscount 10  -- wait, argument order
```

This shows a real ergonomic difference. `applyDiscount` in our anchor takes the payment first and the percent second, which is convenient for `p.copy`-style code. In Haskell you tend to put "the thing being transformed" _last_ so functions compose neatly. It's a small but constant style adjustment: in Haskell, composition decides argument order more than the readability of a single call site does. If we redefine it:

```haskell
applyDiscount :: Double -> Payment -> Payment
applyDiscount percent p = p { amount = amount p * (1 - percent / 100) }
```

then `settle . applyDiscount 10` reads correctly, and you can keep stacking transformations. Scala can do this too; the language just doesn't nudge you there.

In Haskell, currying, partial application, and composition aren't features. They're the shape of the language. In Scala they are features that mostly work. The gap between "mostly works" and "is the default" sounds like a footnote, but it ends up being one of the bigger ergonomic surprises.

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

Both are common. `where` reads top-down at the use site (you state the result, then explain its parts); `let` reads bottom-up (you build pieces, then combine them). Real Haskell code mixes them freely. It's a small style choice that takes a few weeks of reading to feel natural and then becomes invisible. The Scala equivalent is a `def` with a `private def` helper next to it, or a `val` bound at the top of the method body. The moves are the same; only the syntax differs.

## Data: case classes, sealed traits, ADTs

Data modeling is where the comparison is most flattering to Scala. Case classes and sealed traits are excellent. Mechanically, they're what every modern functional language calls _algebraic data types_: products and sums. Case classes are the products; sealed traits and Scala 3 enums are the sums.

Here's a small product in Scala, a record:

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

A few small differences are worth understanding first.

**Field accessors are top-level functions.** When you declare `User { userId :: String, name :: String, age :: Int }`, Haskell creates three top-level functions: `userId :: User -> String`, `name :: User -> String`, `age :: User -> Int`. They live in the module's namespace. Try to declare another type with a `name` field in the same module and you'll get a duplicate-binding error. Scala developers find this jarring at first: your case class fields become plain functions you apply to a value, not methods you call dot-style. The community has three answers: prefix conventions (`userId`, `userName`, `userAge`, very common in real codebases), the `DuplicateRecordFields` extension (allows the conflict but requires disambiguation at use sites), and the more recent `OverloadedRecordDot` extension (lets you write `user.name` after all). This pain also produced optics, one of the more interesting libraries in the language, but that story gets its own post.

**`deriving` is opt-in.** The `deriving (Show, Eq)` line gives you free instances for printing and equality, the same way `case class` gives them by default in Scala. The difference is that Haskell makes you ask, and I prefer that. You can see what you're getting: you don't have to remember whether `Show` is "a printable form" or "a JSON encoding", you just look at the line.

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

It's almost line for line. The Scala version has named arguments per case; the Haskell version uses positional fields. (Haskell can do named fields per constructor too, though it's less idiomatic for small sum types.) Each case in Scala becomes a constructor in Haskell, with the same arity.

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

The forms are interchangeable. Multiple equations are the more common Haskell style: each line says "when called with this shape, return this," which reads close to a mathematical definition.

Both languages warn on non-exhaustive matches, both can be configured to make that an error, and both will catch you if you add a fourth constructor and forget to update a `match`. The mechanism is the same, and the diagnostics are similarly useful.

A small idiom you'll see in real Haskell is combining patterns at use sites. To settle a list of payments:

```haskell
settleAll :: [Payment] -> [Payment]
settleAll = map settle
```

That's it: `map` over a list, `settle` on each one. The Scala equivalent has the same shape (`payments.map(settle)`), but notice how much shorter the Haskell _function definition_ gets when you write it point-free: no `payments` argument, no `=>`, no parens. The function _is_ the composition. Sometimes you'll write `settleAll payments = map settle payments` instead, and that's fine too. Point-free is a style, not a rule.

If you want to filter only the failures and extract the reasons:

```haskell
failureReasons :: [Payment] -> [String]
failureReasons payments =
  [ reason | p <- payments, Failed reason <- [status p] ]
```

That's a _list comprehension_, and it looks almost identical to Scala's `for ... yield`. The pattern `Failed reason <- [status p]` matches only when the wrapped value is a `Failed`, ignoring the others. Pattern matching works anywhere it's useful, not only inside `case` blocks.

The interesting part is what doesn't carry over from Scala's data story, because Haskell never needed it. There's no `extends AnyRef` and no `override def equals`. Nobody on your team can subclass `Payment` and override `applyDiscount` to silently catch exceptions. Data is data, operations are functions, and there's no OOP escape hatch.

If you've spent real time in Scala, you know what I mean. The escape hatch is rare in good Scala code, but "rare" is not "structurally absent," and rare-but-possible is a cost you pay in code review forever. In Haskell that conversation doesn't come up. Haskell gets away with a smaller toolkit here because its features have no second job to do.

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

The shapes are identical. `Some` becomes `Just`, `None` becomes `Nothing`, `Left` and `Right` keep their names. `Either` is right-biased in both languages: `Right` is success, `Left` is failure. (Scala 2.11 and earlier had an unbiased `Either`. On a fresh codebase that doesn't matter, but older Scala docs can confuse you on it.)

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

If the `>>=` chain feels heavy, Haskell has syntactic sugar for it: `do` notation, roughly the equivalent of Scala's `for`-comprehensions:

```haskell
n :: Maybe Int
n = do
  x <- Just 10
  let y = x + 1
  if y > 0 then Just (y * 2) else Nothing
```

It's the same expression, just easier to read, and the `do` block desugars to the `>>=` chain you'd write by hand. Two notes for Scala developers. First, `do` works for _anything_ that's a monad (`Maybe`, `Either`, lists, `IO`, parsers), exactly like `for` works over anything with `flatMap`/`map` in Scala. Second, Scala's `for`-comprehension is a bit more powerful in one direction (it desugars to `withFilter` for `if` guards on `Option`/`Either`-style) and weaker in another (it can't desugar `let` bindings as nicely as `do`). Those differences are footnotes; the idea is the same.

There are a few real differences, though.

There's no direct `Try[A]` in Haskell. The Scala instinct of "wrap a thing that might throw" doesn't translate one-to-one because exceptions are an effect, and Haskell tracks effects in the type. The closest equivalent is `IO (Either SomeException a)` plus the `MonadThrow`/`MonadCatch` machinery, which matters for effectful code rather than plain data modeling.

What you will see right away is `Either` with a domain-specific error type. Where Scala devs reach for `Either[Throwable, A]` (or stack errors onto a sealed trait), Haskell makes data types cheap enough that a custom error type is the default:

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

The shape matches the Scala version. The cultural difference is that "make a small ADT for the error" is the _first_ thing you reach for in Haskell, not the third. Sealed traits make this perfectly possible in Scala; the question is whether your codebase actually does it. In Haskell it almost always does, because declaring a new type costs so little.

There is no `null` in Haskell, anywhere. The bottom value `undefined` exists for the same reason `???` does in Scala (placeholder during development), but you can't store one in a typed reference and pretend you didn't. The "is this nullable?" review comment, which shows up over and over in a long Scala career, never gets written.

So the gap is mostly naming and syntax, and the one philosophical difference is null itself. Once you write optional types as a domain choice rather than a defensive habit, you see that Haskell isn't doing anything cleverer than Scala here. It has just been doing the same thing without the legacy.

## Newtypes are free, opaque types are almost

Here's a pattern you write all the time:

```scala
case class PaymentId(value: String)
case class UserId(value: String)
```

Both wrap a string, but the type system keeps them apart: you can't pass a `UserId` where a `PaymentId` is expected. That's worth it. The cost is a wrapper object on the heap, which the JVM may or may not optimize away. You can add `extends AnyVal`, but it comes with caveats and edge cases that would need their own footnote-of-a-footnote, and it still doesn't guarantee zero cost in every situation.

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

`PaymentId` is a `String` at runtime. The compiler treats it as a distinct type _outside_ the `Ids` module, and as a `String` _inside_ it. You get the type discipline at no runtime cost, which is genuinely good. It's also a little awkward: instances (think `Show`, `Encoder`, `Ordering`) need to be defined inside the wrapper module or worked around through `given` instances elsewhere. Deriving on opaque types is messy.

Haskell's `newtype` is the same idea, but it has been there since 1990 and the surrounding language assumes you'll use it:

```haskell
newtype PaymentId = PaymentId { unPaymentId :: String }
  deriving (Show, Eq, Ord)

newtype UserId = UserId { unUserId :: String }
  deriving (Show, Eq, Ord)
```

Three lines, with zero runtime cost guaranteed. `Show`, `Eq`, and `Ord` derive automatically, and not just because the type is "kind of a string." It's because of `GeneralizedNewtypeDeriving`, which says: if `String` had this instance, `PaymentId` (which _is_ a `String` at runtime) gets the same one. Need a JSON encoder? Derive `ToJSON`. Need `Hashable`? Derive `Hashable`. The pattern is built so deeply into the language that it's almost free to use.

Another convention worth knowing is the _smart constructor_. You declare the newtype but export only a function that builds it, not the constructor itself. That gives you a value-level invariant the type system can rely on:

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

Outside this module, no one can build a `Money` with a negative value. Scala devs use a `private constructor` plus a companion-object `apply` for the same thing, with slightly more ceremony. The difference is that in Haskell the _language's module system_ enforces the boundary, while in Scala it's the OOP visibility rules layered on top.

If you want more control over deriving (say, your `Score` newtype should combine via addition rather than via the underlying `Int`'s default), there's `DerivingVia`:

```haskell
{-# LANGUAGE DerivingVia #-}
import Data.Monoid (Sum(..))

newtype Score = Score Int
  deriving (Eq, Ord, Show)
  deriving Semigroup via (Sum Int)
  deriving Monoid    via (Sum Int)
```

`Sum Int` is a stdlib newtype around `Int` whose `Semigroup` instance is "combine by adding." The `via (Sum Int)` clause says "treat my `Score` as a `Sum Int` for these instances, but keep its own identity for everything else." Now `Score 1 <> Score 2` is `Score 3` (addition), and `mempty :: Score` is `Score 0`.

The same pattern works for anything: JSON encodings, ORM mappings, default printer formats. You pick a stand-in and inherit its instance. Scala developers spend years asking for this, the ability to say "I want this instance, _but_ derived this way, not that way." Haskell ships it as a one-line declaration. It does for type class instances what `newtype` did for nominal typing: it makes a heavyweight thing light enough to use casually.

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

That's the same guarantee Scala 3's opaque types give you, but with no module tricks, with full derivation, and with the rest of the ecosystem already designed around it. You'll see `newtype` everywhere in Haskell, not only for ids but anywhere two values with the same runtime representation should be kept apart by the type system: `newtype Sum a = Sum a` for monoidal addition, `newtype Product a = Product a` for the multiplicative version, `newtype Compose f g a = Compose (f (g a))`. A new type costs so little that the language uses it as a _modelling_ tool, not a workaround.

This section is the whole post in miniature. Opaque types are the right idea, but Scala hasn't been built around them long enough for the rest of the toolkit to assume they exist. In Haskell, libraries, class instances, and generic code already assume you'll wrap your `String`s when you need to, so doing the right thing costs nothing. That comparison gets even more one-sided once you reach deriving and `DerivingVia`.

## Where this is going

I started with the claim that Scala's case classes and sealed traits are already Haskell's ADTs in disguise, and that what changes is what drops away when the language commits. We've now seen this in five small places. Functions are curried by default; partial application is just syntax. Records and sums are the same shapes you write in Scala, minus the OOP attachments. `Option` and `Either` carry over almost verbatim, minus `null`. `newtype` is what `opaque type` will be in another decade of ecosystem work.

This is the part of the comparison most flattering to Scala, because Scala has been getting these things right for a long time and Haskell's lead here is honestly small. If your hands are already trained on case classes and sealed traits, picking up the Haskell forms is more about noticing where the friction was than learning a new toolkit.

Every snippet above was checked against a compiler before it appeared here.

If you read this far and your only thought is _"yeah, none of that is news,"_ good. That's why the series starts here.

---

*Part of the **Haskell for Scala Developers** series:*

1. **Functions and Data**
2. [Type Classes and Implicits](@/blog/2026-05-haskell-for-scala-devs-02-typeclasses.md)
3. [Effects and Concurrency](@/blog/2026-06-haskell-for-scala-devs-03-effects.md)
4. [Objects and Modules](@/blog/2026-07-haskell-for-scala-devs-04-oop.md)
5. [Optics and Deriving](@/blog/2026-08-haskell-for-scala-devs-05-optics.md)
