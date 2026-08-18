+++
title = "Haskell for Scala Developers: Part 5 — Optics and Deriving"
date = 2026-08-17
description = "For working Scala developers picking up Haskell: the two things you actually do every Tuesday — reach deep into an immutable record to change one field, and get a type's instances written for you. Lenses, prisms, and traversals as first-class composable values; the deriving story (stock/newtype/anyclass/DerivingVia on GHC.Generics); Template Haskell as the back door; and how all of it compares to Scala 3's Mirror-based derivation and inline/quotes macros."
path = "blog/2026/08/haskell-for-scala-devs-05-optics"
[taxonomies]
tags = ["haskell", "scala", "functional-programming", "haskell-for-scala-devs"]
categories = ["programming"]
+++

This is the least philosophical piece you could write comparing Haskell and Scala, and the one you'll reach for most often. It's about the two things you actually do every Tuesday afternoon. **Reach into a deeply nested immutable value and change one field three levels down. And get a type's boilerplate — JSON, equality, the lenses themselves — written for you instead of by hand.**

Both languages solve both problems, and — this is the through-line — both solve them the same way underneath: by *generating code from the shape of your types*. Scala reaches for a lens library (Monocle) built on macros, and for `derives` clauses backed by `Mirror` and, when that runs out, `inline`/`quotes`. Haskell reaches for the optics ecosystem and for a deriving mechanism sitting on `GHC.Generics`, with Template Haskell as the full-power back door. Two languages, the same two destinations, arriving by different roads.

Two threads run through it: the record-update pain that makes optics worth having, and the deriving story, where Haskell's `DerivingVia` has no Scala equivalent at all.

<!-- more -->

## The anchor: a nested order

One example the whole way down. An order, with a customer, who has an address, and a list of line items. Nesting for the optics half, a collection for the traversal half, a sum type for the prism half, and enough structure that JSON derivation has something to chew on.

Scala 3:

```scala
case class Address(street: String, city: String, country: String)
case class Customer(name: String, email: String, address: Address)
case class LineItem(sku: String, qty: Int, price: BigDecimal)

enum Payment:
  case Card(last4: String)
  case Cash
  case Invoice(terms: String)

case class Order(
  id: String,
  customer: Customer,
  items: List[LineItem],
  payment: Payment,
)
```

Haskell:

```haskell
data Address = Address
  { street  :: Text
  , city    :: Text
  , country :: Text
  } deriving stock (Show, Eq, Generic)

data Customer = Customer
  { name    :: Text
  , email   :: Text
  , address :: Address
  } deriving stock (Show, Eq, Generic)

data LineItem = LineItem
  { sku   :: Text
  , qty   :: Int
  , price :: Double
  } deriving stock (Show, Eq, Generic)

data Payment
  = Card Text      -- last4
  | Cash
  | Invoice Text   -- terms
  deriving stock (Show, Eq, Generic)

data Order = Order
  { orderId  :: Text
  , customer :: Customer
  , items    :: [LineItem]
  , payment  :: Payment
  } deriving stock (Show, Eq, Generic)
```

Nothing here is new — it's ordinary data modeling with one addition: every type has `Generic` in its `deriving` clause. Hold onto that word. It's the single hook that makes both halves of this post work: the optics get generated from it, and so does the JSON. It's the closest thing Haskell has to Scala 3's `Mirror`, and we'll come back to why in the second half.

## The record-update wall

Here's the pain, stated plainly. A customer moved; update the city. In Scala the tool is `copy`, and nesting it is where it stops being pleasant:

```scala
val moved = order.copy(
  customer = order.customer.copy(
    address = order.customer.address.copy(city = "Kyiv")
  )
)
```

Haskell's record-update syntax has the *exact* same problem, and arguably a worse spelling, because you repeat the accessor chain on the way in:

```haskell
moved = order
  { customer = (customer order)
      { address = (address (customer order))
          { city = "Kyiv" } } }
```

Read that twice. To change one leaf you name the whole path twice — once to dig down (`address (customer order)`) and once to build back up (`customer = ... { address = ... }`). Three levels is annoying; five is a code-review casualty. Every immutable-data language hits this wall, and the fix everyone converges on is the same idea: make "a path into a structure" a **first-class value** you can build, name, compose, and reuse. In Scala that value is a Monocle optic. In Haskell it's a lens.

## Lenses: a path you can pass around

Strip a lens down to its essence and it's two functions glued together: a **getter** `s -> a` and a **setter** `s -> a -> s`. That's it. The whole edifice is those two functions bundled so they compose. Here's the `city` lens on `Address`, written by hand so there's no magic:

```haskell
import Control.Lens

cityL :: Lens' Address Text
cityL = lens city (\addr c -> addr { city = c })
--            ^getter  ^setter
```

`Lens' Address Text` reads "a focus on a `Text` living inside an `Address`." Now three operators do the work, and they're the ones you'll see in every lens-using codebase:

```haskell
view cityL addr          -- get:  addr ^. cityL
set  cityL "Kyiv" addr   -- set:  addr & cityL .~ "Kyiv"
over cityL toUpper' addr -- modify: addr & cityL %~ toUpper'
```

`^.` is get, `.~` is set, `%~` is modify-with-a-function, and `&` is just reverse application (`x & f` = `f x`) so the whole thing reads left-to-right like a pipeline. Fine — but a single-level lens buys nothing over `addr { city = ... }`. The entire point is the next line. **Lenses compose with `.`, exactly like functions**, and the composition dives through the nesting:

```haskell
customerL :: Lens' Order Customer
customerL = lens customer (\o c -> o { customer = c })

addressL :: Lens' Customer Address
addressL = lens address (\c a -> c { address = a })

-- reach three levels down and set one field:
moved = order & customerL . addressL . cityL .~ "Kyiv"
```

That last line is the whole section. `customerL . addressL . cityL` is a `Lens' Order Text` — a single value describing the path from an order all the way down to a city — and it's built by gluing three small lenses with the ordinary composition dot. The nested-`copy` pyramid collapses into one readable chain. And because it's a *value*, you can name it (`orderCityL = customerL . addressL . cityL`), pass it to a function, stick it in a list, and reuse it for get, set, and modify alike.

### You don't write those by hand

The obvious objection: I just wrote three `lens` boilerplate definitions to avoid one `copy`. Nobody does that. Lenses are *generated*, and there are two roads — which is a preview of the whole second half of this post.

The Template Haskell road generates them at compile time from underscore-prefixed fields:

```haskell
data Address = Address { _street :: Text, _city :: Text, _country :: Text }
makeLenses ''Address   -- generates streetL-style lenses named `street`, `city`, ...
```

The `GHC.Generics` road generates them with no code generation at all, straight off that `Generic` instance, using the `generic-lens` library and the field's name as a type-level string:

```haskell
{-# LANGUAGE DataKinds, TypeApplications #-}
import Data.Generics.Product (field)

moved = order
  & field @"customer" . field @"address" . field @"city" .~ "Kyiv"
```

No per-field boilerplate, no Template Haskell, no underscores — `field @"city"` conjures the lens from the type's generic structure on demand. This is the direct answer to Haskell's field-accessor namespacing problem: the field name lives at the type level as `@"city"`, so it doesn't matter that three different records all have a `city` and that Haskell's plain accessors would collide. The optic is resolved by type, not by a name in scope.

**How Scala does the same thing.** Monocle, Scala's optics library, generates the optic inline from a path lambda via a macro:

```scala
import monocle.syntax.all.*

val moved = order.focus(_.customer.address.city).replace("Kyiv")
```

`.focus(_.customer.address.city)` is a macro that reads the lambda's field path at compile time and produces exactly the composed lens `customerL . addressL . cityL` would be. Honestly? For the plain-nested-field case, `.focus(...)` is *nicer* than the Haskell operator zoo — it looks like the field access it replaces, and there's no `.~`/`%~`/`^.` vocabulary to learn. This is the fair half of the section, and it's a real point in Scala's favor: Monocle is a genuinely good library, and its Scala-3 macro syntax is more approachable than `lens`'s operators for the 80% case. Haskell's counter is ubiquity and uniformity — every library speaks the same optic vocabulary, `generic-lens` needs no macro at all, and (with the `OverloadedRecordDot` extension) plain reads like `order.customer.address.city` already work in the language, so optics are reserved for the *update* and *traversal* jobs where they actually earn their keep.

That word "traversal" is where lenses stop being a convenience and start being the interesting library.

## Prisms and traversals: one focus, many targets

A lens focuses on exactly one thing that's always there. Two siblings relax each half of that.

A **prism** focuses on something that *might not be there* — a specific branch of a sum type. Our `Payment` is a sum, and `generic-lens` gives a prism per constructor named by, again, a type-level string:

```haskell
import Data.Generics.Sum (_Ctor)

-- get the card's last4, if and only if this payment is a Card:
last4 :: Order -> Maybe Text
last4 o = o ^? field @"payment" . _Ctor @"Card"
```

`^?` is the "maybe get" operator — a prism can miss, so it returns `Maybe`. `_Ctor @"Card"` matches only when the payment is a `Card`, yielding its `Text`; on `Cash` or `Invoice` you get `Nothing`. Compose a prism onto a lens with the same `.` and you get "reach into this branch, if it's this branch." It's pattern-matching turned into a composable value.

A **traversal** focuses on *many* things at once — every element of a collection. This is the payoff line for the whole anchor. Bump the price of every line item by 10%, in one expression:

```haskell
raised :: Order -> Order
raised o = o & field @"items" . traversed . field @"price" %~ (* 1.1)
```

`traversed` walks the list; composed with `field @"price"` it focuses the `price` of *every* item; `%~ (* 1.1)` modifies all of them. No `map`, no rebuilding the `Order`, no naming the list twice. And you can filter mid-path — discount only the expensive items:

```haskell
discounted :: Order -> Order
discounted o = o
  & field @"items" . traversed . filtered ((> 100) . view (field @"price"))
      . field @"price" %~ (* 0.9)
```

`filtered` keeps the traversal aimed only at items whose price is over 100, and the `%~` at the end multiplies just those. Read the path left to right and it's an English sentence: *in the items, for each one, where the price is over 100, multiply the price by 0.9.*

This is the sense in which optics are one of the more interesting libraries in the language. Lens, prism, and traversal are the same idea — a first-class, composable focus — at three different cardinalities (exactly one, zero-or-one, zero-or-many), and they all compose with the same dot. A `Lens . Traversal` is a `Traversal`; a `Lens . Prism` is a `Traversal`; the types work out so you can build a focus that dives through a record, into a list, filtered, and into a branch, as one value.

**The fair half.** Monocle has all three too — `Lens`, `Prism`, `Traversal`, `Optional`, the whole hierarchy — and its `.focus` macro extends to `.each`, `.filterIndex`, and prism-style `.as[Case]` selectors. So this is not a capability Haskell has and Scala lacks; both ecosystems are complete. The difference is the one that runs through the entire series: in Haskell this vocabulary is *the* way you touch nested data, assumed by every library, whereas in Scala it's an excellent add-on library you opt into on top of `copy`, pattern matching, and `map`. Same tools; different center of gravity.

There's a real cost to be honest about, though, and it's the flip side of that ubiquity: `lens` is famous for the wall of operators (`^.`, `.~`, `%~`, `^?`, `^..`, `.=`, `<>~`, and dozens more) and for type errors that mention `Applicative f =>` machinery you didn't write. The modern `optics` library trades the operators for named functions (`view`, `set`, `over`, `%`) and much friendlier errors — it's what I'd start a new codebase on today. But `lens` is what most of the ecosystem is written in, so its operators are the ones you have to be able to read.

## The engine underneath: GHC.Generics

Now the second half, and the reason I made every anchor type `deriving stock (… Generic)`. Where does `field @"city"` get its getter and setter without you writing them? The same place a generic JSON encoder gets its field names, and the same place `stock` deriving gets `Show` and `Eq`: `GHC.Generics` turns any type into a uniform, walkable description of its own structure.

`deriving Generic` gives your type an associated `Rep` — a representation of it as a sum of products, with the constructor and field names carried along at the type level. Library code never sees `Order`; it sees "a product of four fields named `orderId`, `customer`, `items`, `payment`," and writes one generic algorithm over *that* shape that then works for every type. `field @"city"` is a generic function that walks the `Rep` to find the field named `city`. Aeson's generic encoder walks the same `Rep` to emit a JSON object with a key per field. One structural description; many consumers.

The everyday face of it is JSON, and it's a two-word `deriving` clause. Aeson (the `aeson` library) provides *default* `ToJSON`/`FromJSON` methods defined in terms of `Generic`, so you can pull them in with the `anyclass` strategy:

```haskell
{-# LANGUAGE DerivingStrategies, DeriveAnyClass #-}
import Data.Aeson (ToJSON, FromJSON, encode)

data Address = Address
  { street  :: Text
  , city    :: Text
  , country :: Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)
```

```haskell
encode (Address "1 Main St" "Kyiv" "UA")
-- {"city":"Kyiv","country":"UA","street":"1 Main St"}
```

That's the whole thing. No codec to write, no field list to keep in sync with the record, no import beyond the class names — the encoder reads the fields off `Generic`. This is where `DerivingStrategies` earns its place: each `deriving` clause says *how* it's deriving, so there's no ambiguity between "the compiler writes this structurally" (`stock`) and "borrow the class's Generic-based default" (`anyclass`).

## Four strategies, and the one with no Scala equivalent

The four deriving strategies line up as a set, because each answers a different "where does this instance come from" question:

- **`stock`** — the compiler synthesizes it from the type's structure. `Show`, `Eq`, `Ord`, `Functor`, `Foldable`, `Traversable`, `Generic` itself. Built into GHC.
- **`newtype`** — the wrapper borrows its underlying type's instance, at zero runtime cost. A `newtype UserId = UserId Text` gets `Text`'s `Ord` for free.
- **`anyclass`** — use the class's *own* default methods. This is the JSON case above: Aeson's defaults are written over `Generic`, so `anyclass` gets you a working codec with no bespoke code.
- **`via`** — `DerivingVia`: borrow the instance from a *stand-in* newtype that already has the one you want.

The first three have rough Scala analogues (`stock` ≈ the compiler's `case class` freebies, `newtype` ≈ inheriting an `opaque type`'s given, `anyclass` ≈ a `Mirror`-based `derives`). `DerivingVia` is the one that doesn't, and it's worth seeing why it's more than a fourth flavor. It lets you package *a whole derivation policy* as a reusable type and stamp it onto anything.

A tiny, self-contained example — combine a `newtype` by addition instead of by its underlying type's default:

```haskell
{-# LANGUAGE DerivingVia #-}
import Data.Monoid (Sum(..))

newtype Meters = Meters Double
  deriving stock (Show, Eq)
  deriving (Semigroup, Monoid) via (Sum Double)
```

```haskell
Meters 3 <> Meters 4   -- Meters 7.0   (added, because Sum says so)
```

Now the version that shows why "no Scala equivalent" matters. Say your whole API wants `snake_case` JSON keys. Instead of configuring an encoder at every type, you name the policy once as a stand-in and derive *through* it (this uses the `deriving-aeson` package, which exists precisely to make Aeson options `DerivingVia`-able):

```haskell
{-# LANGUAGE DerivingVia, DataKinds #-}
import Deriving.Aeson

data Customer = Customer
  { firstName :: Text
  , lastName  :: Text
  , homeCity  :: Text
  }
  deriving stock (Show, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON '[FieldLabelModifier CamelToSnake] Customer
```

```haskell
-- encode a Customer => {"first_name":...,"last_name":...,"home_city":...}
```

`CustomJSON '[FieldLabelModifier CamelToSnake]` *is* the policy — camelCase fields become snake_case keys — expressed as a type. Any record can adopt it with one `via` line, and you can define your own `type ApiJSON = CustomJSON '[...]` alias so the whole codebase derives `... via ApiJSON`. The strategy became a first-class, named, reusable thing. That's the sense in which the comparison "gets more one-sided": Scala 3 can *configure* a derivation (pass options to a `derives`), but it has no built-in way to name a configuration as a type and stamp it across dozens of unrelated records with a single clause. You reach for a shared macro or a base trait instead.

## Two roads to generated code — and Scala's

Step back and there are two ways to generate code from a type, and Haskell has both — which is the honest frame for comparing to Scala.

**`GHC.Generics` is the type-directed road.** No code is generated as text; a generic function is an ordinary (if intricate) polymorphic function over the `Rep`. It's what everything above rides on. The cost is compile time and occasionally opaque errors when a `Rep` doesn't line up, and it can only see structure the `Rep` exposes.

**Template Haskell is the back door** — actual metaprogramming, where a function runs at compile time and *splices in* new declarations as syntax:

```haskell
{-# LANGUAGE TemplateHaskell #-}
import Data.Aeson.TH (deriveJSON, defaultOptions)

data LineItem = LineItem { _sku :: Text, _qty :: Int, _price :: Double }
deriveJSON defaultOptions ''LineItem   -- generates the ToJSON/FromJSON code
makeLenses ''LineItem                  -- generates lenses `sku`, `qty`, `price`
```

`deriveJSON ''LineItem` runs at compile time and writes the instance source for you; `makeLenses` writes the lens definitions (that's why the fields are underscore-prefixed — `makeLenses` strips the `_` and names the lens after what's left, which is also why the earlier hand-written examples used plain field names but this one doesn't). This is strictly more powerful than `GHC.Generics` — it can generate anything you could type — but it's heavier (a compile-time staging restriction means spliced types must be defined *above* the splice), slower, and the generated code is invisible. The Haskell community's taste is to prefer `Generic` and reach for TH only when generics can't express the thing — which is exactly the trade Scala developers will find familiar, because it's the `Mirror`-versus-macro trade in the other language.

**Scala's road is macros, with `Mirror` as the sanctioned front porch.** Scala 3's everyday derivation uses `derives` backed by a `Mirror` — the compiler-provided description of a `case class`/`enum` that is, essentially, Scala's `GHC.Generics`:

```scala
import scala.deriving.Mirror
import scala.compiletime.constValueTuple

trait Labelled[A]:
  def labels: List[String]

object Labelled:
  inline def derived[A](using m: Mirror.ProductOf[A]): Labelled[A] =
    new Labelled[A]:
      def labels =
        constValueTuple[m.MirroredElemLabels].productIterator.map(_.toString).toList

// one keyword wires it up; the field names come from the Mirror:
case class Address(street: String, city: String, country: String) derives Labelled
// summon[Labelled[Address]].labels  ==  List("street", "city", "country")
```

A `Mirror.ProductOf[Address]` carries the field names and types at the type level — that's the `MirroredElemLabels` the `derived` method reads — and `derived` folds over them with `inline` + `scala.compiletime` operations. That fold is the direct counterpart to a generic function walking a `Rep`; a real JSON library's `derived` is this same shape with more cases. When `Mirror` isn't enough, Scala drops to full macros: `inline def` plus `quotes`/`splices` (`'{ ... }` and `${ ... }`), which run arbitrary code at compile time and construct typed AST — Scala's Template Haskell.

Here's the honest scorecard, because this section is the fair half of the whole post. On *raw power*, Scala 3 macros and Template Haskell are a draw, and if anything Scala's edge out: `quotes`/`splices` are a more principled, better-typed metaprogramming system than TH's stringly-influenced `Q` monad, and `inline` gives you Turing-complete compile-time computation that `GHC.Generics` alone can't match. Where Haskell pulls ahead is not power but *the shape of the common case*. The everyday jobs — "give me JSON," "give me lenses," "combine via addition," "encode with snake_case keys" — are one `deriving` line each, backed by a `stock`/`anyclass`/`via` strategy that's part of the language grammar, not a library's macro you import. Scala reaches the same place, but through a `derives` keyword whose meaning is supplied entirely by each library's derivation code, and through `Mirror` folds that every library re-implements. Haskell standardized the plumbing; Scala standardized the socket and lets libraries bring the plumbing. On a Tuesday, the standardized plumbing is less to think about — which is the whole claim.

## Where this is going

The thesis was that both languages generate code from the shape of your types, to do the two things you do constantly: reach into nested immutable data, and stop writing boilerplate. We saw the record-update wall, and lenses knocking it down — getter-plus-setter fused into a composable value, then prisms for maybe-there branches and traversals for many-at-once, all composing with a single dot, all generated off `Generic` or Template Haskell rather than written by hand. Then the deriving story: `GHC.Generics` as the engine, four strategies where Scala has roughly three, `DerivingVia` as the one that packages a derivation policy into a reusable type with no Scala counterpart, and Template Haskell as the full-power back door.

And the fair half held up. Monocle's `.focus` macro is a nicer surface than `lens`'s operators for the common case; `lens` itself is genuinely intimidating and `optics` is the friendlier modern choice. Scala 3's `quotes`/`splices` are a more principled metaprogramming system than Template Haskell, and `inline` is strictly more powerful than `GHC.Generics`. Haskell's win here isn't capability — both ecosystems are complete — it's that the common case is a keyword instead of a library's macro.

---

*Part of the **Haskell for Scala Developers** series:*

1. [Functions and Data](@/blog/2026-05-haskell-for-scala-devs-01-basics.md)
2. [Type Classes and Implicits](@/blog/2026-05-haskell-for-scala-devs-02-typeclasses.md)
3. [Effects and Concurrency](@/blog/2026-06-haskell-for-scala-devs-03-effects.md)
4. [Objects and Modules](@/blog/2026-07-haskell-for-scala-devs-04-oop.md)
5. **Optics and Deriving**
