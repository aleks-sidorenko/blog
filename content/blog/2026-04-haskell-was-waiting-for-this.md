+++
title = "Haskell Was Waiting for This"
date = 2026-04-22
description = "Strong types, little boilerplate, and a compiler that checks everything an LLM writes. My case for Haskell as your next language."
path = "blog/2026/04/haskell-was-waiting-for-this"
[taxonomies]
tags = ["haskell", "llm", "ai", "functional-programming"]
categories = ["programming"]
+++

Every few months someone announces "the best language for AI." Usually it's Python, sometimes TypeScript, occasionally Rust when the mood is right. My claim is less fashionable: if you ship code an LLM helped you write and you want to be confident it works, Haskell is the best fit in 2026.

It's not the trendiest choice, and it's not the easiest to hire for. I still think it fits best. Here's why.

<!-- more -->

## What changed

For thirty years the pitch for Haskell went something like: "the type system catches bugs, and purity makes code easier to reason about." True, but for most teams the cost of learning it outweighed the benefit. You paid a real tax in onboarding, hiring, and library availability for guarantees that a disciplined team could mostly get by being careful.

LLMs changed that math. The question used to be how hard a language is for a human to write. Now it's how quickly I can trust what was just generated, and by that measure Haskell is absurdly well placed.

## Types are the verification loop

An LLM will confidently produce code that looks right and is wrong. Everyone who has used one knows this. Reading the output more carefully won't save you. A compiler that refuses to continue when something doesn't line up will.

Haskell's type system is the strongest mainstream option for this, and I mean actually strong, not strong in the TypeScript-with-any sense. You cannot silently pass a `UserId` where an `OrderId` is expected. You cannot forget to handle the `Nothing` case. You cannot hit a null. You cannot call a function that does I/O from one that promised it wouldn't. The type checker closes off every shortcut the LLM might take.

In practice this changes how things fail. With Python or JavaScript, a bad suggestion compiles happily and fails at 3 a.m. in production. With Haskell, a bad suggestion doesn't compile, and the compiler points at the exact line. That error message goes straight back into the model's context on the next turn. Fix, retry, converge. The tighter that loop, the more useful the LLM, and Haskell gives you the tightest loop going.

## Expressiveness: more intent, less ceremony

LLMs work within a budget called the context window, and every token you spend on boilerplate is a token not spent on your actual problem.

Haskell is ruthlessly compact. A function signature tells you more than a Java class declaration ever will. `traverse`, `foldr`, `<$>`, and `>>=` compress patterns that in Go or Python would need loops, temporaries, and nested conditionals. Algebraic data types replace class hierarchies, visitor patterns, and defensive null checks with a single declaration that fits on one screen.

The payoff is practical. The LLM sees the entire module instead of just the part that fit. You can paste a whole subsystem into a prompt and still have room for the question, and the diff the model proposes is short enough to review carefully.

Expressive languages always had this advantage. Now we measure it in context tokens.

## Low verbosity works both ways

Low verbosity is the other side of expressiveness, and it helps the model when it writes code and when it reads it.

When *generating*, the model has fewer keystrokes to get wrong. Ten lines of Haskell that correctly round-trip a database record give fewer chances for a hallucinated field name than fifty lines of Java with getters, setters, builders, and equals/hashCode. More surface area means more bugs.

When *reading*, the model spends fewer tokens figuring out what the code does before it can help you change it. Intent sits close to the surface. There is less "plumbing" and more "what." That's the property you want in code that machines will re-read thousands of times over its life.

## Correctness by construction

The parts of Haskell that humans find alien (purity, effect tracking via types, total functions, parametricity) are the parts an LLM finds liberating.

A pure function has no hidden state to guess about. Its behavior depends only on its arguments, so the model doesn't need to know what else happened in the system to reason about it. Compare that with "this method might mutate any of three globals and also hit the network if a feature flag is on."

Effects in the type (`IO`, `STM`, custom effect stacks) mean the model cannot accidentally sneak a database call into a function that claimed to be a pure calculation. Whatever the LLM generates or refactors, the effectful parts stay in the places you allowed them.

Parametric polymorphism gives you the famous "free theorems": a function of type `[a] -> [a]` can only rearrange or drop elements; it can't invent new ones or inspect them. That shrinks the space of things the implementation could possibly be doing, which is what you need when you're about to trust code you didn't write.

## The other things nobody mentions

A few more reasons I think Haskell lands well in an LLM-heavy workflow:

**Hoogle.** You can search the entire ecosystem *by type signature*. `(a -> b) -> [a] -> [b]` returns `map`. That's a gift to any code-generating system. LLMs are already good at phrasing "find me a function of this shape," and Haskell is the only mainstream language where that query is a first-class citizen.

**Type-driven development.** You write the signature, the LLM fills in the body, and GHC tells it whether the body is internally consistent. This works in other languages too, but nowhere does the type do as much of the work. Often, once the signature is right, there is only one reasonable implementation, and the compiler will tell you so.

**Refactoring is safe.** LLM-driven refactors are where things usually go sideways in dynamic languages: a rename misses a call site, or a shape change silently breaks a test that wasn't run. In Haskell, the compiler refuses to build until every call site is updated. You can accept a large, aggressive refactor from a model because nothing that isn't internally consistent will ship.

**Small, orthogonal building blocks.** Haskell gives you fewer ways to do the same thing. That helps when the writer is an LLM with a habit of inventing new patterns. Fewer dialects means the model drifts less.

**No hidden runtime magic.** No annotations that silently spin up proxies, no reflection-based frameworks, no monkey-patching. What you see is what runs. LLMs reason better about code without action at a distance, and so do the humans reviewing LLM output.

## The tooling problem just got solved

For years, the honest answer to "why not Haskell?" was tooling. Cabal versus Stack. GHC upgrades that broke your lockfile. Cryptic build errors that needed insider knowledge to decode. An LSP that worked great once you got it working. Every Haskell convert has the same war story about spending a weekend fighting the environment before writing a single line of real code.

It was a serious weakness, and it kept a lot of otherwise curious people out.

LLMs fixed it, almost completely. Paste a Cabal error and the model will tell you which package is conflicting and how to pin it. Describe the project you want and it will produce a working `flake.nix` or `stack.yaml` on the first try. A linker error that would have cost you an afternoon of Google spelunking in 2020 gets fixed in ten seconds in 2026. GHC's notoriously dense error messages? The model reads them better than most humans.

This matters because Haskell's ecosystem problems were never about the language. They were about the *long tail* of rare, undocumented, "I guess you had to be there" friction, which is exactly what disappears when your assistant has effectively read every Haskell mailing list, Stack Overflow answer, and GitHub issue ever posted. The weakness that cost Haskell a decade of adoption isn't a weakness anymore.

## What you give up

There is a cost, though.

The library ecosystem is smaller. The pool of developers who can maintain Haskell is smaller. If your problem is "glue together seven SaaS APIs by Friday," Python still wins: its LLM corpus is vast and the libraries exist for everything. Haskell shines when correctness, refactorability, and long-term maintainability matter more than time to first prototype.

Also, the LLMs themselves are still better at Python than at Haskell, simply because there's more Python on the internet. The gap is real, but it's closing fast, and it matters less than you'd think. A model that writes average Haskell with GHC checking every step is more useful than a model that writes great Python that silently misbehaves at runtime.

## Pick it

If you're choosing a new language to invest in for the next few years, and you expect to pair-program with an LLM for most of that time, pick Haskell. It isn't the path of least resistance today, but it's the language with the tightest feedback loop between you, the model, and the compiler. Strong types, expressiveness, low verbosity, and correctness pay off again every time a model touches your code.

Scala taught me to value the paradigm. The LLM era is teaching me to value the guardrails. Haskell has both, and it has them by default.

If you're new to it, the [previous post](@/blog/2026-02-getting-started-with-haskell.md) is a decent starting point. Pair it with your favorite model and see what I mean.
