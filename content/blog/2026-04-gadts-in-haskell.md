+++
title = "GADTs in Haskell"
date = 2026-04-02
description = "Why phantom types fall short and how GADTs carry type evidence into pattern matches — explained with doors and expressions."
path = "blog/2026/04/gadts-in-haskell"
[taxonomies]
tags = ["haskell", "functional-programming", "type-system"]
categories = ["programming"]
+++

If you've spent any time reading Haskell code, you've probably run into GADTs — Generalized Algebraic Data Types. Maybe you've seen the `{-# LANGUAGE GADTs #-}` pragma at the top of a file and moved on. Maybe you've read an explanation or two and thought "okay, but when would I actually need this?"

This post builds up to GADTs step by step. We'll start with a problem, try the obvious fix, watch it fail, and then see how GADTs solve it cleanly. By the end, we'll also look inside to see what GHC is actually doing.

<!-- more -->

## The problem: a door that doesn't know its own state

Let's model something simple — a door. It can be open or closed, and we want functions to open and close it:

```haskell
data DoorState = Open | Closed

data Door = Door DoorState

open :: Door -> Door
open (Door Closed) = Door Open
open d              = d

close :: Door -> Door
close (Door Open) = Door Closed
close d            = d
```

This works, but notice the problem: `open (Door Open)` compiles and runs just fine. We're opening an already-open door and the compiler doesn't complain.

We could change `open` to return `Maybe Door` and fail on invalid transitions, but that just pushes the problem to every caller. The types aren't helping us — they can't distinguish an open door from a closed one.

What if they could?

## First attempt: phantom types

The natural idea is to make the door's state part of its type. With `DataKinds`, we can promote `DoorState` to the type level and use it as a phantom type parameter:

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}

data DoorState = Open | Closed

data Door (s :: DoorState) = Door
```

Now we can write type signatures that enforce valid transitions:

```haskell
open :: Door 'Closed -> Door 'Open
open Door = Door

close :: Door 'Open -> Door 'Closed
close Door = Door
```

This is great — `open` only accepts a closed door, `close` only accepts an open one. Try to open an already-open door and GHC rejects it. We've solved the problem, right?

Not quite. Try writing a function that describes a door's state:

```haskell
describe :: Door s -> String
describe door = ???
```

We're stuck. The type parameter `s` tells GHC whether the door is open or closed, but there's nothing at the value level to inspect. `Door` has a single constructor — it looks the same regardless of `s`. The phantom type carries information at the type level but gives us nothing back when we need to branch on it at runtime.

You could try a typeclass — define `class Describable (s :: DoorState)` with instances for `'Open` and `'Closed`. But now you're threading constraints through every function signature, and the complexity spreads fast.

The real issue is that phantom types are *write-only*. We can put type information in, but we can't get it back out during pattern matching. We need something that carries evidence we can actually use.

## GADTs: constructors that carry proof

This is where GADTs come in. Instead of a single constructor with a phantom parameter, we define separate constructors that each *fix* the type parameter to a specific value:

```haskell
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}

data DoorState = Open | Closed

data Door (s :: DoorState) where
  OpenDoor   :: Door 'Open
  ClosedDoor :: Door 'Closed
```

This looks like a small syntactic change, but the impact is significant. Each constructor is now a *witness* for a specific type. When you pattern match on `OpenDoor`, GHC learns that `s ~ 'Open` in that branch. The constructor *is* the evidence.

Now `describe` just works:

```haskell
describe :: Door s -> String
describe OpenDoor   = "The door is open"
describe ClosedDoor = "The door is closed"
```

No typeclasses, no constraints, no tricks. We pattern match, and the compiler knows what `s` is in each branch.

Type-safe transitions still work exactly as before:

```haskell
open :: Door 'Closed -> Door 'Open
open ClosedDoor = OpenDoor

close :: Door 'Open -> Door 'Closed
close OpenDoor = ClosedDoor
```

And if we try something invalid:

```haskell
open OpenDoor
```

GHC gives us:

```
Couldn't match type ''Open' with ''Closed'
  Expected: Door 'Closed
    Actual: Door 'Open
```

The key idea: with phantom types, the type parameter was just a label — useful for signatures but invisible during pattern matching. With GADTs, the constructors themselves encode type information that the compiler recovers when you match on them. That's the whole trick.

## Scaling up: a type-safe expression language

The door was a toy example. Let's see the same idea applied to a more realistic problem — a small expression language with integers, booleans, addition, comparison, and conditionals.

Here's the plain ADT version:

```haskell
data Expr
  = I Int
  | B Bool
  | Add Expr Expr
  | LessThan Expr Expr
  | Cond Expr Expr Expr
```

We can represent `1 + 3` as `Add (I 1) (I 3)`. But nothing stops us from writing `Add (I 1) (B True)` — adding an integer to a boolean. The compiler won't complain.

This makes the evaluator painful. We need a separate type to represent values, and every operation has to handle possible type mismatches at runtime:

```haskell
data Value = VI Int | VB Bool

eval :: Expr -> Maybe Value
eval (I i) = pure $ VI i
eval (B b) = pure $ VB b
eval (Add x y) = do
  VI x' <- eval x
  VI y' <- eval y
  pure $ VI $ x' + y'
eval (LessThan x y) = do
  VI x' <- eval x
  VI y' <- eval y
  pure $ VB $ x' < y'
eval (Cond c t f) = do
  VB c' <- eval c
  if c' then eval t else eval f
```

Every pattern match might fail. Every result is wrapped in `Maybe`. We're doing at runtime what the type system should handle at compile time.

Now the GADT version:

```haskell
data Expr a where
  I        :: Int -> Expr Int
  B        :: Bool -> Expr Bool
  Add      :: Expr Int -> Expr Int -> Expr Int
  LessThan :: Expr Int -> Expr Int -> Expr Bool
  Cond     :: Expr Bool -> Expr a -> Expr a -> Expr a
```

Each constructor declares exactly what type of expression it produces. `I` produces `Expr Int`. `B` produces `Expr Bool`. `LessThan` takes two `Expr Int`s and produces an `Expr Bool` — the input and output types don't have to match, and that's perfectly fine.

The evaluator becomes very simple:

```haskell
eval :: Expr a -> a
eval (I i)          = i
eval (B b)          = b
eval (Add x y)      = eval x + eval y
eval (LessThan x y) = eval x < eval y
eval (Cond c t f)
  | eval c    = eval t
  | otherwise = eval f
```

No `Maybe`. No `Value` wrapper. No runtime type checks. When we match on `I i`, GHC knows `a ~ Int`, so returning `i` (an `Int`) is fine. When we match on `LessThan x y`, GHC knows `a ~ Bool`, so returning the result of `<` works.

And `Add (I 1) (B True)` is now a compile error:

```
Couldn't match type 'Bool' with 'Int'
  Expected: Expr Int
    Actual: Expr Bool
  In the second argument of 'Add', namely '(B True)'
```

Same pattern as the door, bigger payoff.

## Inside the compiler: what GHC actually does

This might feel like compiler magic, but the mechanism is surprisingly simple.

When you define a GADT constructor like `OpenDoor :: Door 'Open`, GHC internally attaches a **type equality proof** to that constructor. Think of it as an invisible extra field: a promise that `s` equals `'Open`. In GHC's intermediate language (Core), you can actually see this — each GADT constructor carries a coercion parameter (written `~#`) that the compiler uses for type-safe casts.

When you pattern match on `OpenDoor`, GHC "opens" that proof. Inside the match branch, it now knows `s ~ 'Open` and can use that fact to type-check the rest of the expression. That's why returning a `String` that assumes the door is open works — the proof is right there.

You can see this yourself by compiling with `-ddump-simpl` to dump GHC's Core output. You'll see that each GADT constructor takes an extra coercion argument, and pattern matches extract it to justify the type refinements.

Here's the important nuance: these coercions exist at compile time, in Core, where GHC uses them to verify type safety. At runtime, the only evidence is the constructor tag itself — the same thing any ADT has. The difference is purely in what the type checker can *conclude* from that tag. A regular ADT constructor tells GHC "this is an `OpenDoor`." A GADT constructor tells GHC "this is an `OpenDoor`, *and therefore `s` is `'Open`*."

It's not runtime magic — it's the compiler being smarter about what it already knows.

## Wrapping up

The main idea behind GADTs is simple: constructors can carry type evidence that the compiler recovers when you pattern match. Phantom types let you *label* things at the type level, but GADTs let you *use* those labels in your code.

If you're not familiar with the basics we built on here — algebraic data types, pattern matching, type signatures — my earlier post on [getting started with Haskell](@/blog/2026-02-getting-started-with-haskell.md) covers all of that.

Next time you find yourself writing runtime checks for something the types should already know, that's your signal.
