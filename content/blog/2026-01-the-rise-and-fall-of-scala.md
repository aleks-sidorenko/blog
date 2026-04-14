+++
title = "The Rise and Fall of Scala"
date = 2026-02-15
description = "After almost a decade of writing Scala, I reflect on why the best language I've ever used is losing the battle — and where I'm heading next."
path = "blog/2026/02/the-rise-and-fall-of-scala"
[taxonomies]
tags = ["scala", "haskell", "functional-programming", "jvm"]
categories = ["programming"]
+++

I have been writing Scala for almost ten years. It is, without a doubt, the best programming language I have ever worked with. Expressive type system, pattern matching, immutability by default, a concise syntax that gets out of your way — Scala at its best is a joy.

And yet, I am learning Haskell. Not because I fell out of love with Scala, but because I can see where things are going.

<!-- more -->

## A language that had it all

When I first picked up Scala around 2016, it felt like the future. You got the entire JVM ecosystem — battle-tested libraries, mature tooling, seamless Java interop — wrapped in a language that actually respected you as a developer. Case classes, for-comprehensions, higher-kinded types, implicits that felt like magic when they worked. Coming from Java, it was like taking off a straitjacket.

For years, Scala was the best-kept secret on the JVM. Spark made it relevant in data engineering. Akka gave it a foothold in distributed systems. Play and http4s offered compelling web stacks. Companies like Twitter, LinkedIn, and Netflix adopted it at scale.

It wasn't just a better Java. It was a genuinely different way of thinking about software.

## Death by a thousand cuts

So what happened? No single catastrophe. Just a slow accumulation of problems, each one survivable on its own, together forming a trend that's hard to ignore.

### Java woke up

This is probably the biggest factor, and it has nothing to do with Scala itself.

Java 8 gave us lambdas and streams. Boring, sure, but suddenly the gap between Java and "Scala as a better Java" got a lot narrower. Then came records, sealed classes, pattern matching, virtual threads. Java 21 is not the Java I fled from in 2016. It's still verbose, still ceremony-heavy, but for teams that were using Scala as "Java with less boilerplate" — the reason to stay evaporated.

### Kotlin ate the "better Java" market

For everyone who wanted a modern JVM language without the complexity budget of Scala, Kotlin showed up at exactly the right time. Google's backing, first-class Android support, a gentle learning curve, and a pragmatic philosophy. Kotlin didn't try to be everything. It just tried to be a better Java, and it succeeded.

Scala could never compete on simplicity. That was never the point. But it meant the pipeline of developers who might have discovered Scala's deeper features — the ones that make the language truly special — dried up.

### A community at war with itself

Here's where it gets painful. Scala's hybrid nature — part object-oriented, part functional — was always its selling point and its curse.

In practice, the community split into two camps. One writes Scala like a better Java with some functional seasoning. The other goes full functional programming — tagless final, effect systems, type-level programming. ZIO versus Cats Effect. Typelevel versus the rest. Each camp has its own idioms, its own libraries, its own idea of what "good Scala" looks like.

This isn't just a stylistic disagreement. Try hiring for a Scala team. A developer fluent in ZIO might struggle with a Cats Effect codebase and vice versa. The ecosystem effectively forked without actually forking.

And then there's the drama. Scala's online community has a reputation, and not a good one. Twitter threads turning toxic, maintainers burning out in public, heated arguments about language direction. Every few months, some new controversy erupts. It's exhausting. It drives people away — not from the language itself, but from the ecosystem around it.

### The Scala 3 chasm

Scala 3 is a better language than Scala 2. I genuinely believe that. Contextual abstractions are cleaner than implicits. The new syntax is more approachable. Union and intersection types are elegant.

But the migration has been rough. Libraries stuck on Scala 2 for years. Binary compatibility headaches. Companies that invested heavily in Scala 2 codebases looked at the migration cost and said, "Why not just move to Kotlin? Or back to Java?" The transition that was supposed to be Scala's renaissance instead became another reason to leave.

### The corporate exodus

One by one, the big names started pulling back. Twitter (now X) rewrote services in Java. LinkedIn shifted toward Kotlin. New startups that five years ago would have defaulted to Scala now reach for Go or Kotlin or even TypeScript.

### The job market collapse

Eight years ago, Scala jobs were everywhere. Fintech, ad tech, data platforms, startups trying to attract strong engineers — everyone was hiring. I never had trouble finding interesting Scala work. Today, the landscape is unrecognizable. Listings have dried up. The ones that remain often want a very specific flavor of Scala, narrowing the pool even further. The job market is shrinking, which makes it harder to hire Scala developers, which makes companies less likely to choose Scala, which shrinks the job market further. A classic death spiral.

## The language deserved better

I want to be clear: none of this is because Scala is a bad language. The opposite. Scala is probably the most feature-rich language in existence. Implicits, macros, higher-kinded types, path-dependent types, structural types, union types, intersection types, opaque types, inline/compiletime metaprogramming, enums that are actually ADTs, extension methods, context functions, match types — the list goes on. No other language I know of packs this much into a single type system.

And that's precisely the problem. All those features interact with each other in subtle ways. The learning curve isn't a curve — it's a cliff with false summits. Every team ends up using a different subset of the language, which is part of why the community fragmented in the first place.

But languages don't succeed on technical merit alone. They succeed on ecosystem health, community cohesion, corporate backing, and momentum. Scala had all of these once. Now they're eroding.

## So why Haskell?

If Scala's decline taught me anything, it's that I value the functional programming paradigm more than any particular language. The ideas that drew me to Scala — algebraic data types, referential transparency, composition, type-driven design — they all come from Haskell. Scala borrowed them. Haskell originated them.

Haskell doesn't have Scala's identity crisis. There's no "better Java" camp. There's no debate about whether you should use effect systems — that's just how you write Haskell. The community is smaller but more focused. The language knows what it is.

And here's the thing that surprised me most: Haskell is simpler. Not easier — simpler. Scala gives you ten ways to solve a problem and leaves you to argue about which one is idiomatic. Haskell gives you fewer, more orthogonal building blocks, and you compose them. Type classes instead of implicits, traits, and extension methods all at once. Algebraic data types without the OOP escape hatch. Purity enforced by the type system, not by convention. The result is a language that is both smaller and more expressive — you say more with less.

After years of navigating Scala's feature maze, there's something deeply refreshing about a language where the answer to "how should I do this?" is usually just one thing.

Is Haskell's ecosystem smaller? Yes. Is the job market thinner? Absolutely — and I have no illusions about this. The Haskell job market isn't declining like Scala's. It was never large to begin with. Scala went from plenty of opportunities to few. Haskell has been consistently few, before and now. In a way, that's easier to accept. A small but stable niche is less disorienting than watching a thriving market evaporate around you. I'm not switching to Haskell for career optimization. Will I be as productive on day one? Not even close. But I'd rather invest in a language that's honest about what it is than keep watching one I love try to be everything to everyone.

This blog will document that journey. If you're a fellow Scala developer feeling the same pull, maybe some of what I find will be useful to you too.
