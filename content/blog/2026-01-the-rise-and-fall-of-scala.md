+++
title = "The Rise and Fall of Scala"
date = 2026-01-15
description = "After almost a decade of writing Scala, I look at why the best language I've ever used is losing ground, and where I'm going next."
path = "blog/2026/01/the-rise-and-fall-of-scala"
[taxonomies]
tags = ["scala", "haskell", "functional-programming", "jvm"]
categories = ["programming"]
+++

I have been writing Scala for almost ten years. It is, without a doubt, the best programming language I have ever worked with. It has an expressive type system, pattern matching, immutability by default, and a concise syntax that gets out of your way. At its best, Scala is a joy.

And yet I am learning Haskell. I still love Scala, but I can see where things are going.

<!-- more -->

## A language that had it all

When I first picked up Scala around 2016, it felt like the future. You got the entire JVM ecosystem (battle-tested libraries, mature tooling, smooth Java interop) wrapped in a language that actually respected you as a developer. Case classes, for-comprehensions, higher-kinded types, implicits that felt like magic when they worked. Coming from Java, it was like taking off a straitjacket.

For years, Scala was the best-kept secret on the JVM. Spark made it relevant in data engineering. Akka gave it a foothold in distributed systems. Play and http4s offered compelling web stacks. Companies like Twitter, LinkedIn, and Netflix adopted it at scale.

And it was more than a better Java. It made you think about software differently.

## Death by a thousand cuts

So what happened? There was no single disaster, just a slow buildup of problems. Each one was survivable on its own, but together they form a trend that's hard to ignore.

### Java woke up

This is probably the biggest factor, and it has nothing to do with Scala itself.

Java 8 gave us lambdas and streams. Boring, sure, but suddenly the gap between Java and "Scala as a better Java" got a lot narrower. Then came records, sealed classes, pattern matching, virtual threads. Java 21 is not the Java I fled from in 2016. It's still verbose and full of ceremony, but teams that used Scala as "Java with less boilerplate" lost their reason to stay.

### Kotlin ate the "better Java" market

For everyone who wanted a modern JVM language without Scala's complexity, Kotlin showed up at exactly the right time. It had Google's backing, built-in Android support, a gentle learning curve, and a practical philosophy. Kotlin didn't try to be everything. It just tried to be a better Java, and it succeeded.

Scala could never compete on simplicity, and that was never the point. But it meant the stream of developers who might have discovered Scala's deeper features, the ones that make the language special, dried up.

### A community at war with itself

This part is painful. Scala's hybrid nature (part object-oriented, part functional) was always both its selling point and its curse.

In practice, the community split into two camps. One writes Scala like a better Java with a bit of functional flavor. The other goes full functional programming: tagless final, effect systems, type-level programming. ZIO versus Cats Effect. Typelevel versus the rest. Each camp has its own idioms, its own libraries, and its own idea of what "good Scala" looks like.

The split goes deeper than style. Try hiring for a Scala team. A developer fluent in ZIO might struggle with a Cats Effect codebase and vice versa. The ecosystem effectively forked without actually forking.

Then there's the drama. Scala's online community has a bad reputation: Twitter threads turning toxic, maintainers burning out in public, heated arguments about the direction of the language. Some new controversy breaks out every few months. It's exhausting, and it drives people away from the ecosystem even when they still like the language.

### The Scala 3 chasm

I genuinely believe Scala 3 is a better language than Scala 2. Contextual abstractions are cleaner than implicits. The new syntax is more approachable. Union and intersection types are elegant.

But the migration has been rough. Libraries stuck on Scala 2 for years. Binary compatibility headaches. Companies that invested heavily in Scala 2 codebases looked at the migration cost and said, "Why not just move to Kotlin? Or back to Java?" The transition that was supposed to be Scala's rebirth became another reason to leave.

### The corporate exodus

One by one, the big names started backing away. Twitter (now X) rewrote services in Java. LinkedIn shifted toward Kotlin. New startups that five years ago would have defaulted to Scala now reach for Go or Kotlin or even TypeScript.

### The job market collapse

Eight years ago, Scala jobs were everywhere. Fintech, ad tech, data platforms, startups trying to attract good engineers: everyone was hiring. I never had trouble finding interesting Scala work. Today it looks nothing like that. Listings have dried up, and the ones that remain often want a very specific flavor of Scala, which narrows the pool even further. The shrinking job market makes it harder to hire Scala developers, which makes companies less likely to choose Scala, which shrinks the job market further. A classic death spiral.

## The language deserved better

None of this happened because Scala is a bad language. Quite the opposite. Scala is probably the most feature-rich language in existence: implicits, macros, higher-kinded types, path-dependent types, structural types, union types, intersection types, opaque types, inline/compiletime metaprogramming, enums that are actually ADTs, extension methods, context functions, match types, and the list goes on. No other language I know of packs this much into a single type system.

And that's precisely the problem. All those features interact with each other in subtle ways. The learning curve is less a curve than a cliff with false summits. Every team ends up using a different subset of the language, which is part of why the community fragmented in the first place.

But languages don't succeed on technical merit alone. They need a healthy ecosystem, a cohesive community, corporate backing, and momentum. Scala had all of these once. Now they're eroding.

## So why Haskell?

If Scala's decline taught me anything, it's that I value the functional programming paradigm more than any particular language. The ideas that drew me to Scala (algebraic data types, referential transparency, composition, type-driven design) all come from Haskell. Scala borrowed them. Haskell originated them.

Haskell doesn't have Scala's identity crisis. There's no "better Java" camp. Nobody debates whether you should use effect systems, because that's just how you write Haskell. The community is smaller but more focused, and the language knows what it is.

What surprised me most is that Haskell is simpler. Not easier, but simpler. Scala gives you ten ways to solve a problem and leaves you to argue about which one is idiomatic. Haskell gives you fewer, more orthogonal building blocks, and you compose them. Type classes instead of implicits, traits, and extension methods all at once. Algebraic data types without the OOP escape hatch. Purity enforced by the type system, not by convention. The result is a language that is both smaller and more expressive.

After years of navigating Scala's feature maze, it's refreshing to use a language where "how should I do this?" usually has one answer.

Is Haskell's ecosystem smaller? Yes. Is the job market thinner? Absolutely, and I have no illusions about this. But the Haskell job market isn't declining like Scala's, because it was never large to begin with. Scala went from plenty of opportunities to few. Haskell has always had few. In a way, that's easier to accept: a small but stable niche is less confusing than watching a thriving market disappear around you.

I'm not switching to Haskell for career optimization. Will I be as productive on day one? Not even close. But I'd rather invest in a language that's honest about what it is than keep watching one I love try to be everything to everyone.

This blog will document that journey. If you're a fellow Scala developer feeling the same pull toward Haskell, maybe some of what I find will be useful to you too.
