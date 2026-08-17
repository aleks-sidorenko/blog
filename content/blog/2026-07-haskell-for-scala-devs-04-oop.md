+++
title = "Haskell for Scala Developers: Part 4 — Objects and Modules"
date = 2026-07-22
description = "For working Scala developers picking up Haskell: the claim that most of Scala's OOP machinery answers questions Haskell never asks — inheritance as a sum type plus a function, the expression problem, mixins as plain functions, five module constructs collapsing into one keyword, encapsulation through export lists and smart constructors, and mutation as an effect rather than a default."
path = "blog/2026/07/haskell-for-scala-devs-04-oop"
[taxonomies]
tags = ["haskell", "scala", "functional-programming", "haskell-for-scala-devs"]
categories = ["programming"]
+++

Here's a thesis worth defending: **most of Scala's object-oriented machinery is answers to questions Haskell never asks.** Inheritance, trait linearization, the five different places a definition can live, `private` and its dozen qualifiers — a large fraction of it exists to manage complexity that a language built on data and functions simply doesn't generate.

That's the spicy half. Here's the fair half. Four of the things OOP was actually solving are real problems: polymorphic dispatch, code reuse, modularity, and controlled mutation with encapsulation. Every language needs answers to those. The argument of this post is not that Haskell ignores them — it's that Haskell answers each with something smaller and more honest than a class hierarchy, and that the smaller answer is usually the better one. Where Scala's version earns its keep, I'll say so; there are two or three places it genuinely does.

One running example the whole way down: a notification service. It's the canonical OOP teaching object — a polymorphic `send`, a hierarchy of channels, mixins that add retry and rate-limiting, and a private counter tracking deliveries. If you've sat through an "intro to OOP" course you've written this exact class. We're going to watch it dissolve into a handful of data types and functions, and I'll argue that what's left is what you actually wanted.

<!-- more -->

## The anchor: a notification service

Here's the object, in idiomatic Scala 3. An abstract base with a polymorphic `send`, and three concrete channels:

```scala
abstract class Notifier:
  def channel: String
  def send(msg: String): Unit =
    println(s"[$channel] $msg")

class EmailNotifier(address: String) extends Notifier:
  def channel = "email"
  override def send(msg: String): Unit =
    println(s"[email -> $address] $msg")

class SmsNotifier(number: String) extends Notifier:
  def channel = "sms"
  override def send(msg: String): Unit =
    println(s"[sms -> $number] $msg")

class PushNotifier(deviceId: String) extends Notifier:
  def channel = "push"
  override def send(msg: String): Unit =
    println(s"[push -> $deviceId] $msg")
```

```scala
val notifiers: List[Notifier] =
  List(EmailNotifier("a@x.io"), SmsNotifier("+100"), PushNotifier("dev-42"))
notifiers.foreach(_.send("deploy finished"))
```

```
[email -> a@x.io] deploy finished
[sms -> +100] deploy finished
[push -> dev-42] deploy finished
```

Nothing wrong with this. It's the code the language wants you to write, and every Scala developer reading this could have typed it from memory. The question is what each piece is *for*, and whether Haskell needs the same pieces to do the same job. It turns out the answer is "no" more often than the OOP instinct expects — starting with the base class itself.

## Inheritance is a sum type plus a function

Strip `Notifier` down to what it actually does. It's two things fused into one construct: a **set of alternatives** (email, sms, push) and an **operation over them** (`send`). OOP welds those together — the alternatives are subclasses, the operation is a method they each override, and dispatch is the virtual-method lookup that picks the right override at runtime.

Haskell pulls them apart. The alternatives become a sum type; the operation becomes a function that pattern-matches. Here's the whole hierarchy above, as data plus one function:

```haskell
data Notifier
  = Email String   -- address
  | Sms String     -- number
  | Push String    -- deviceId

send :: Notifier -> String -> IO ()
send (Email addr) msg = putStrLn ("[email -> " ++ addr ++ "] " ++ msg)
send (Sms num)    msg = putStrLn ("[sms -> "   ++ num  ++ "] " ++ msg)
send (Push dev)   msg = putStrLn ("[push -> "  ++ dev  ++ "] " ++ msg)

main :: IO ()
main = do
  let notifiers = [Email "a@x.io", Sms "+100", Push "dev-42"]
  mapM_ (\n -> send n "deploy finished") notifiers
```

```
[email -> a@x.io] deploy finished
[sms -> +100] deploy finished
[push -> dev-42] deploy finished
```

Same output, and — this is the part worth sitting with — no base class, no `override`, no virtual dispatch, no inheritance at all. The three subclasses became three constructors of one type. The polymorphic method became one function with three equations. What the runtime did implicitly (look at the object, find its `send`), the `case` does explicitly (look at the constructor, pick the branch). The dispatch didn't disappear; it moved from a vtable you can't see into a pattern match you can.

Two things fall out of this immediately, and they're the reason I'd reach for the Haskell version most of the time.

**Exhaustiveness.** Add a fourth channel — `Slack String` — to the type, and GHC will warn you at every function that pattern-matches `Notifier` and forgot the new case. The compiler hands you a to-do list of everything you need to update. In the Scala hierarchy, adding `SlackNotifier` compiles cleanly and silently; nothing tells you that the `msg match` buried in some formatting helper three files away now has an unhandled case, because there's no closed set to check against. (Scala's `sealed trait` recovers this, and I'll come back to that — but the *open* class hierarchy above, the one inheritance actually gives you, does not.)

**The operation is just a value.** `send` is an ordinary top-level function. It isn't trapped inside the type, it doesn't need `this`, and it composes like any other function. Want a second operation — `priority :: Notifier -> Int`? Write it. You don't touch the `Notifier` type and you don't touch any subclass, because there are no subclasses to touch.

### The expression problem, stated honestly

That last point is exactly half of a genuine trade-off, and this is the section's fair half. There are two directions you can extend this design in — **new cases** (a Slack channel) and **new operations** (a `priority` function) — and no single representation makes both free. This is the *expression problem*, and it's the real content underneath the OOP-versus-FP argument.

- The **class hierarchy** makes new *cases* cheap: `class SlackNotifier extends Notifier` adds a channel without editing a single existing class. It makes new *operations* expensive: a new abstract method on `Notifier` forces an edit to every subclass.
- The **sum type** makes new *operations* cheap: a new function over `Notifier` touches nothing that exists. It makes new *cases* expensive: a new constructor forces an edit to every function (though, per above, the compiler tells you exactly where).

Neither wins outright. They optimize for opposite kinds of change. The honest guidance is: if your set of variants is stable and you keep inventing operations over it — which describes most domain modeling, most compilers, most business logic — the sum type is the better bet, and the exhaustiveness checking is a real safety net. If your set of operations is stable and you keep adding variants — plugins, drivers, a UI toolkit's widget zoo — the open hierarchy's axis of extension is the one you want.

And here's the thing: Haskell gives you *that* axis too, when you want it. A typeclass is an open set of cases sharing a fixed operation — exactly the class-hierarchy shape:

```haskell
class Channel a where
  send :: a -> String -> IO ()

newtype Email = Email String
newtype Sms   = Sms String

instance Channel Email where
  send (Email addr) msg = putStrLn ("[email -> " ++ addr ++ "] " ++ msg)

instance Channel Sms where
  send (Sms num) msg = putStrLn ("[sms -> " ++ num ++ "] " ++ msg)
```

Now adding a `Slack` channel is a new `instance` in its own module, touching nothing — the open-extension direction, recovered. The typeclass *is* Haskell's version of the interface-with-implementations pattern, and it's the tool you pick when the class hierarchy's axis is the one you need. What Haskell refuses to do is make that the *default* the way `class` does in Scala. You choose your axis of extension per problem — sum type for stable-variants, typeclass for stable-operations — instead of inheriting one axis for everything because it's the only construct the language hands you.

Scala can express both too; `sealed trait` plus pattern matching is the sum type, and it's genuinely good. The difference is one of gravity. In Scala the path of least resistance is the open hierarchy — it's what `class extends` gives you and what tutorials teach first. In Haskell the path of least resistance is the closed sum type, and you reach for the open one deliberately. My claim is only that the closed one is the right default more often than OOP's gravity suggests, and that the language pulling you toward it is a feature.

## Mixins are just functions

The second thing the hierarchy was doing is code reuse across channels. Say every notifier should retry on failure, and some should be rate-limited. In Scala the idiomatic tool is the stackable trait — `abstract override` with `super`, mixed in at the class definition or at the `new` site:

```scala
trait Retrying extends Notifier:
  abstract override def send(msg: String): Unit =
    var attempt = 0
    var done = false
    while !done && attempt < 3 do
      attempt += 1
      try { super.send(msg); done = true }
      catch case _: Exception => println(s"[retry $attempt] $channel")

trait RateLimited extends Notifier:
  abstract override def send(msg: String): Unit =
    println(s"[rate-limit check] $channel")
    super.send(msg)

val notifier = new EmailNotifier("a@x.io") with RateLimited with Retrying
notifier.send("hello")
```

```
[rate-limit check] email
[retry 1] email       // (illustrative: if the first attempt threw)
[email -> a@x.io] hello
```

This is real power, and it's also the place OOP complexity concentrates. The behavior of that `send` depends on **linearization** — the order Scala flattens `EmailNotifier with RateLimited with Retrying` into a single chain of `super` calls. Get the order wrong and rate-limiting wraps retrying instead of the other way around. Change a mixin three levels up and the linearization shifts under you. The diamond problem — two traits inheriting a common base, mixed into one class — is a whole topic with its own rules. All of that machinery exists to answer one question: *in what order do these bits of behavior wrap each other?*

Haskell asks the question directly and answers it with function composition. A "mixin" is a function that takes a notifier and returns a decorated one. The notifier, recall, is data — so let me switch to the representation that makes decoration natural, an object as a record of functions:

```haskell
data Notifier = Notifier
  { channel :: String
  , send    :: String -> IO ()
  }

email :: String -> Notifier
email addr = Notifier
  { channel = "email"
  , send    = \msg -> putStrLn ("[email -> " ++ addr ++ "] " ++ msg)
  }
```

That record is an object: a bundle of behavior (`send`) closed over its private state (`addr`). No keyword introduced it — it's the same `data` declaration we've been using all along. Now the mixins are functions `Notifier -> Notifier`:

```haskell
retrying :: Notifier -> Notifier
retrying n = n { send = \msg -> go 1 msg }
  where
    go attempt msg =
      send n msg `catch` \(_ :: SomeException) -> do
        putStrLn ("[retry " ++ show attempt ++ "] " ++ channel n)
        if attempt < 3 then go (attempt + 1) msg else pure ()

rateLimited :: Notifier -> Notifier
rateLimited n = n { send = \msg -> do
    putStrLn ("[rate-limit check] " ++ channel n)
    send n msg }
```

And you stack them by composing, left to right exactly as written:

```haskell
main :: IO ()
main = do
  let notifier = (rateLimited . retrying) (email "a@x.io")
  send notifier "hello"
```

```
[rate-limit check] email
[email -> a@x.io] hello
```

`rateLimited . retrying` is the linearization, and it's *right there in the source* — `rateLimited` wraps `retrying` wraps the base, because that's the order the composition reads. There's no flattening algorithm to reason about, no `super` chain assembled behind your back, no diamond, no `abstract override`. Want to swap the order? Swap the two names. The thing Scala's trait system spends real conceptual weight computing for you is, in Haskell, just the order you wrote your function composition in — which is to say, it's not a feature, because it never became a problem.

The honest counterweight: Scala's stackable traits *do* buy you something the decorator functions don't quite — a mixin can be applied at the type level so that `EmailNotifier with Retrying` is a distinct type the compiler tracks, and you can constrain code to "any Notifier that is Retrying." In Haskell that's a different tool again (a typeclass constraint, or a phantom type), not the decorator. But for the overwhelmingly common case — "wrap this behavior around that one, in this order" — the function is the whole answer, and it's an answer you can read off the page.

There's a second flavor of reuse, too: behavior shared across *types* rather than wrapped around one value — a `Formattable` that every channel implements. That's the typeclass with default methods: Scala's `trait` with concrete methods that classes inherit is Haskell's `class` with default method implementations that instances inherit. Same mechanism, and the one piece of the `trait` that survives the translation intact.

## Five constructs, one keyword

Scala has a remarkable number of places a definition can live, and each has its own lookup rules. There's the `package`. There's the `object` (a singleton — Scala's answer to statics and to modules-as-values). There's the `package object` (things scoped to a whole package). There's the **companion object** (an `object` with the same name as a class, which gets to see the class's privates and is where you put factory methods and `given`s). And there's the class or trait body itself. Five constructs, five sets of visibility and resolution rules, and a running background question every Scala developer carries: *where should this definition go, and how will callers find it?*

```scala
package notify

object Notifier:                       // companion — factories, statics
  def default: Notifier = EmailNotifier("ops@x.io")

case class EmailNotifier(address: String) extends Notifier: ...

package object util:                    // package-wide helpers
  def truncate(s: String): String = s.take(140)
```

Haskell has one construct: the `module`. A file is a module. It has a name, an export list, and a set of imports. That's the entire system.

```haskell
module Notify
  ( Notifier(..)      -- the type and (here) its constructors
  , defaultNotifier   -- the "companion" factory is just a function
  , truncate          -- the "package helper" is just a function
  ) where

data Notifier = Email String | Sms String | Push String

defaultNotifier :: Notifier
defaultNotifier = Email "ops@x.io"

truncate :: String -> String
truncate = take 140
```

Everything the five Scala constructs were doing collapses into "top-level definitions in a module, some exported." The companion object's factory methods? Top-level functions. The companion's privileged access to the class internals? Automatic — anything in the module can see anything else in the module, so a smart constructor sitting next to its type sees the constructor without ceremony. The `package object`'s shared helpers? Top-level functions, exported. Statics on a class? There's no class and no instance-versus-static distinction to make; there are only values and functions, and a "static method" is a function that doesn't take the type as an argument.

Scala has five lookup paths because it has five places things can live, and the compiler has to search all of them (locals, imports, companions, package objects, givens) to resolve a name or an implicit. Haskell has essentially one lookup path for names — what a module imports, explicitly — because there's one place things live. The `instance` mechanism is the one piece that resolves globally rather than by import, and it's deliberately the *only* thing that does. Everything else you find by importing the module it's in.

Is anything lost? A little. Scala's `object` is genuinely a value — you can pass a module around, store it in a field, swap it at runtime for a test double. Haskell modules are compile-time only; you can't pass a module as an argument. When you want that "module as a first-class, swappable thing" — dependency injection, in a word — you reach for a record of functions (the `Notifier` record above is exactly this shape) or the `ReaderT`/effect-handler machinery you'd reach for with effects. So Scala folds two ideas — namespacing and runtime-swappable components — into the single word `object`, and Haskell splits them: `module` for namespacing, records/effects for swappable components. I think the split is clarifying, but it's a real difference, not a strict win, and it's the one place the module comparison isn't lopsided.

## Encapsulation without `private`

Encapsulation is the survivor everyone worries about first. If there's no class, where does `private` go? How do you stop callers from constructing an invalid value or poking at internals?

Scala attaches visibility to members: `private`, `protected`, `private[this]`, `private[packagename]`, and — the modern, best answer — `opaque type`. The unit of protection is the member, and there's a qualifier for nearly every scope you might mean.

Haskell attaches visibility to the module's **export list**, and gets most of the same outcomes with one mechanism. The trick that does the heavy lifting is exporting a *type* without exporting its *constructor*:

```haskell
module Email
  ( Email        -- export the type, but NOT the constructor
  , mkEmail      -- the only way in
  , emailAddress -- a read accessor
  ) where

newtype Email = Email String

mkEmail :: String -> Maybe Email
mkEmail s
  | '@' `elem` s = Just (Email s)
  | otherwise    = Nothing

emailAddress :: Email -> String
emailAddress (Email s) = s
```

Note the export list: `Email`, not `Email(..)`. The type name is public; the `Email` data constructor is private to this module. Outside the module, the *only* way to obtain an `Email` is `mkEmail`, which enforces the invariant (there's an `@` in there). Nobody can write `Email "not an address"` from another module — the constructor isn't in scope. This is the **smart constructor** pattern, and it's how Haskell says "this value is always valid by construction," the thing OOP tries to get with a private field plus a validating constructor plus disciplined getters.

Everything encapsulation wanted, you get from "which names does this module export":

- **A private field** → a constructor you don't export. Internals are unreachable because the only door (the constructor) is locked.
- **A public read-only accessor** → export a function, not the field. `emailAddress` reads; there's no setter because the value is immutable, so the entire category of "accidental mutation of an object's innards" doesn't arise.
- **A validated constructor** → a smart constructor returning `Maybe` (or `Either` with a reason). Invalid states are unrepresentable outside the module.
- **A package-private helper** → a function the module simply doesn't export.

The honest counterweight, and it's a fair one: Scala's per-member visibility is *finer-grained* than the module boundary. `private[this]` means "not even other instances of this class" — a distinction Haskell's module-level control can't make, because Haskell has no instances to distinguish. And `opaque type` is genuinely excellent and gives you the newtype-with-hidden-representation story right in the language. So this isn't Haskell having something Scala lacks; it's Haskell reaching the same destination — invariants enforced, internals hidden — with one concept (the export list) where Scala offers a graduated menu. For the 95% case, "don't export the constructor" is all you ever need, and it's less to hold in your head than the qualifier menu. For the last 5%, Scala's granularity occasionally does something the module can't.

## Mutation is an effect, not a default

Here's the last survivor, and the one that reframes the whole series. The notification service should count how many messages it has delivered. In Scala the reflex is a private mutable field:

```scala
class DeliveryLog:
  private var count = 0
  def record(): Unit = count += 1
  def total: Int = count
```

Look at the signature of `total`: `Int`. It promises you an integer and says nothing about the fact that calling it observes mutable state that other threads might be changing. `record()` returns `Unit` and quietly mutates. This is the OOP default — objects *are* bundles of mutable state, and the mutation is invisible in the types. It's so normal that the Scala version above doesn't even register as doing anything unusual.

Haskell will not let you hide it. There is no ambient mutable field; mutation is an effect, and effects show up in the type. An `IORef` — a mutable reference cell — is the direct translation:

```haskell
data DeliveryLog = DeliveryLog (IORef Int)

newLog :: IO DeliveryLog
newLog = DeliveryLog <$> newIORef 0

record :: DeliveryLog -> IO ()
record (DeliveryLog ref) = modifyIORef' ref (+ 1)

total :: DeliveryLog -> IO Int
total (DeliveryLog ref) = readIORef ref
```

Every signature tells the truth. `newLog :: IO DeliveryLog` — allocating a mutable cell is an effect. `record :: DeliveryLog -> IO ()` — recording mutates, so it's `IO`. And the one that matters most: `total :: DeliveryLog -> IO Int`, **not** `DeliveryLog -> Int`. Reading mutable state is an effect, because the answer depends on *when* you ask, and the type is forced to admit it. You cannot write a `DeliveryLog -> Int` that reads the live count — the type system won't have it. The invisible thing in the Scala version is unmissable here, and that's the entire point: you can look at a function's type and know whether it touches mutable state, every time, with no exceptions.

That's also why concurrency is so much less fraught in Haskell. The reason `Ref`/`IORef`/`STM` are the whole story is that mutation has *nowhere to hide* — it was already corralled into `IO`, already explicit, already something the type system was tracking. There's no separate "make this class thread-safe" project, because there's no ambient mutable state that was quietly unsafe to begin with.

And often you don't even want a mutable cell — you want the *appearance* of mutable state with none of the reality. If the counter is threaded through a computation rather than shared across threads, the `State` monad gives you `get`/`put`/`modify` that read and write like mutable variables but compile down to pure value-passing:

```haskell
import Control.Monad.State

deliver :: String -> State Int ()
deliver _msg = modify (+ 1)   -- looks like mutation; is pure

runBatch :: [String] -> Int
runBatch msgs = execState (mapM_ deliver msgs) 0
```

```haskell
runBatch ["a", "b", "c"]   -- => 3
```

`modify (+ 1)` reads exactly like `count += 1`, and `runBatch` returns a plain `Int` with no `IO` in sight — because nothing was ever mutated. `State` is a pure value-threading pattern wearing mutable-variable syntax, and its type (`State Int`, not `IO`) tells you precisely that: state is involved, the outside world is not. When you *do* need genuine in-place mutation for performance in a pure algorithm, `ST` gives you that with a type that still guarantees the mutation can't escape. Three tools — `State` for pure threading, `ST` for local mutation, `IORef`/`STM` for shared mutable state — and the *type* tells the reader which one you reached for and therefore what kind of thing is going on. In the Scala class, all three of those look identical from the outside: a method returning `Int`.

This is the deep version of the whole post's thesis. OOP's central idea is the object: state and behavior bundled together, with the state mutable by default and the mutation hidden behind methods. Haskell's bet is that this bundling is the source of a huge fraction of the complexity we spend classes managing — thread-safety, defensive copying, temporal coupling, "is it safe to call this twice." Take the mutation out of the default, force it into the types when it's genuinely needed, and most of that management work evaporates along with the machinery built to do it.

## Where this is going

The thesis at the top was that most of Scala's OOP machinery answers questions Haskell never asks, and that the four real problems underneath — dispatch, reuse, modularity, encapsulation-with-mutation — have smaller answers. We've now seen each one. Inheritance split back into a sum type and a function (with the typeclass waiting when you want the open axis, and the expression problem naming the trade honestly). Stackable mixins became function composition, with the linearization written plainly in the source instead of computed by a flattening rule. Five module constructs collapsed into one `module` plus an export list. Encapsulation came from not exporting a constructor, and mutation stopped being a default and became an effect you can see in every type.

The fair half held up too. Sum types make new operations cheap and new cases costly, which is the wrong trade for genuinely plugin-shaped problems — and that's exactly when you reach for the typeclass. Scala's `object`-as-value gives you runtime-swappable modules that Haskell splits into records and effects. Per-member visibility is finer-grained than the module boundary. None of those is a knockout for either side; they're the honest seams where the two designs made different, defensible calls.

---

*Part of the **Haskell for Scala Developers** series:*

1. [Functions and Data](@/blog/2026-05-haskell-for-scala-devs-01-basics.md)
2. [Type Classes and Implicits](@/blog/2026-05-haskell-for-scala-devs-02-typeclasses.md)
3. [Effects and Concurrency](@/blog/2026-06-haskell-for-scala-devs-03-effects.md)
4. **Objects and Modules**
5. [Optics and Deriving](@/blog/2026-08-haskell-for-scala-devs-05-optics.md)
