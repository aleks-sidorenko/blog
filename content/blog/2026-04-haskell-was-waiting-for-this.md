+++
title = "Haskell Was Waiting for This"
date = 2026-04-22
description = "Strong types, high expressiveness, low verbosity, and compiler-enforced correctness — Haskell might be the language that LLMs were waiting for. Here's the case for picking it as your next language."
path = "blog/2026/04/haskell-was-waiting-for-this"
[taxonomies]
tags = ["haskell", "llm", "ai", "functional-programming"]
categories = ["programming"]
+++

Every few months someone announces "the best language for AI." Usually it's Python, sometimes TypeScript, occasionally Rust when the mood is right. I want to make a less fashionable claim: if you care about shipping code that an LLM helped you write, and you want to be confident it actually works, Haskell is quietly the best fit in 2026.

Not the trendiest. Not the easiest to hire for. The best fit. Let me explain.

<!-- more -->

## What changed

For thirty years the pitch for Haskell went something like: "the type system catches bugs, and purity makes code easier to reason about." True, but for most teams the cost of learning it outweighed the benefit. You paid a real tax in onboarding, hiring, and library availability to get guarantees that a disciplined team could mostly get by being careful.

LLMs flipped that economics. The question is no longer "how hard is this language for a human to write?" It's "how quickly can I trust what was just generated?" And that's a completely different axis — one where Haskell happens to be absurdly well-positioned.

## Types are the verification loop

An LLM will confidently produce code that looks right and is wrong. Everyone who has used one knows this. The defense is not "read it more carefully." It's a compiler that refuses to proceed when something doesn't line up.

Haskell's type system is the strongest mainstream option for this. Not "strong" in the TypeScript-with-any sense — actually strong. You cannot silently pass a `UserId` where an `OrderId` is expected. You cannot forget to handle the `Nothing` case. You cannot fall into a null. You cannot call a function that does I/O from one that promised it wouldn't. Every shortcut the LLM might take, the type checker closes off.

The practical effect is that the failure mode shifts. With Python or JavaScript, a bad suggestion compiles happily and fails at 3 a.m. in production. With Haskell, a bad suggestion doesn't compile, and the compiler points at the exact line. That error message goes straight back into the model's context on the next turn. Fix, retry, converge.

The tighter the feedback loop, the more useful the LLM. Haskell gives you the tightest loop going.

## Expressiveness: more intent, less ceremony

LLMs have a budget. It's called the context window, and every token you spend on boilerplate is a token not spent on your actual problem.

Haskell is ruthlessly compact. A function signature tells you more than a Java class declaration ever will. `traverse`, `foldr`, `<$>`, and `>>=` compress patterns that in Go or Python would need loops, temporaries, and nested conditionals. Algebraic data types replace hierarchies of classes, visitor patterns, and defensive null checks with a single declaration that fits on one screen.

This compactness is not about looking clever. It means the LLM sees the entire module, not just the part that fit. It means you can paste a whole subsystem into a prompt and still have room for the question. It means the diff the model proposes is short enough to review carefully.

Expressive languages always had this advantage. The difference is that now we're measuring it in context tokens, and every token matters.

## Low verbosity works both ways

The flip side of expressiveness is low verbosity, and the LLM benefits from both directions.

When *generating*, the model has fewer keystrokes to get wrong. Ten lines of Haskell that correctly round-trip a database record is fewer chances for a hallucinated field name than fifty lines of Java with getters, setters, builders, and equals/hashCode. Surface area and bugs scale together.

When *reading*, the model spends fewer tokens figuring out what the code does before it can help you change it. Intent sits close to the surface. There is less "plumbing" and more "what." This is exactly the property you want in code that's going to be re-read by machines thousands of times over its life.

## Correctness by construction

The part of Haskell that humans find alien — purity, effect tracking via types, total functions, parametricity — is the part an LLM finds liberating.

A pure function has no hidden state to guess about. Its behavior is determined entirely by its arguments. The model doesn't need to know "what else happened in the system" to reason about it. That is a dramatically smaller mental model than "this method might mutate any of three globals and also hit the network if a feature flag is on."

Effects in the type — `IO`, `STM`, custom effect stacks — mean the model cannot accidentally sneak a database call into a function that claimed to be a pure calculation. The type forbids it. Whatever the LLM generates, whatever it refactors, the effectful parts stay corralled in the places you allowed them.

Parametric polymorphism gives you the famous "free theorems": a function of type `[a] -> [a]` can only rearrange or drop elements; it can't invent new ones or inspect them. That shrinks the space of things the implementation could possibly be doing, which is exactly what you need when you're about to trust code you didn't write.

## The other things nobody mentions

A few more reasons I think Haskell lands well in an LLM-heavy workflow:

**Hoogle.** You can search the entire ecosystem *by type signature*. `(a -> b) -> [a] -> [b]` returns `map`. This is a gift to any code-generating system — "find me a function of this shape" is a query LLMs are already good at phrasing, and Haskell is the only mainstream language where that query is a first-class citizen.

**Type-driven development.** You write the signature, the LLM fills in the body, and GHC tells it whether the body is internally consistent. This workflow works in other languages too, but nowhere does the type do as much of the work. Often, once the signature is right, there is only one reasonable implementation — and the compiler will tell you so.

**Refactoring is safe.** LLM-driven refactors are where things usually go sideways in dynamic languages: a rename misses a call site, a shape change silently breaks a test that wasn't run. In Haskell, the compiler refuses to build until every call site is updated. You can accept a large, aggressive refactor from a model because you know nothing will ship that isn't internally consistent.

**Small, orthogonal building blocks.** Haskell gives you fewer ways to do the same thing. That's a feature when the writer is an LLM with a habit of inventing novel patterns. Fewer dialects means the model drifts less.

**No hidden runtime magic.** No annotations that silently spin up proxies, no reflection-based frameworks, no monkey-patching. What you see is what runs. LLMs reason better about code without action-at-a-distance, and humans reviewing LLM output do too.

## The tooling problem just got solved

For years, the honest answer to "why not Haskell?" was tooling. Cabal versus Stack. GHC upgrades that broke your lockfile. Cryptic build errors that required tribal knowledge to decode. An LSP that worked great — once you got it working. Every Haskell convert has the same war story about spending a weekend fighting the environment before writing a single line of real code.

This was a genuine, language-defining weakness, and it kept a lot of otherwise-curious people out.

LLMs fixed it. Not partially — essentially entirely. Paste a Cabal error and the model will tell you what package is conflicting and how to pin it. Describe the project you want and it will produce a working `flake.nix` or `stack.yaml` on the first try. Hit a linker error that would have cost you an afternoon of Google spelunking in 2020, and in 2026 you get the fix in ten seconds. GHC's notoriously dense error messages? The model reads them better than most humans.

The reason this matters so much is that Haskell's ecosystem problems were never about the language — they were about the *long tail* of rare, undocumented, "I guess you had to be there" friction. Exactly the kind of friction that evaporates when you have an assistant that has effectively read every Haskell mailing list, Stack Overflow answer, and GitHub issue ever posted. The weakness that cost Haskell a decade of adoption is simply not a weakness anymore.

## What you give up

I'd be dishonest if I pretended there was no cost.

The library ecosystem is smaller. The pool of developers who can maintain Haskell is smaller. If your problem is "glue together seven SaaS APIs by Friday," Python still wins — its LLM corpus is vast and the libraries exist for everything. Haskell shines when correctness, refactorability, and long-term maintainability matter more than time-to-first-prototype.

Also: the LLMs themselves are still better at Python than at Haskell, simply because there's more Python on the internet. This gap is real, but it's closing fast, and it matters less than you think. A model that writes average Haskell under the gaze of GHC is more useful than a model that writes great Python that silently misbehaves at runtime.

## Pick it

If you're choosing a new language to lean into for the next few years, and you expect to be pair-programming with an LLM for most of that time — pick Haskell. Not because it's the path of least resistance today, but because it's the language where the feedback loop between you, the model, and the compiler is the tightest. Every advantage you get from strong types, expressiveness, low verbosity, and correctness compounds every single time a model touches your code.

Scala taught me to value the paradigm. The LLM era is teaching me to value the guardrails. Haskell has both, and it has them by default.

If you're new to it, the [previous post](@/blog/2026-02-getting-started-with-haskell.md) is a decent on-ramp. Pair it with your favorite model and see what I mean.
