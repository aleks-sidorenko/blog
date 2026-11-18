+++
title = "Why Did I Build HomeAccounting?"
date = 2026-09-25
description = "Eleven years of tracking household money: one in Excel, ten in 1C. What each got right, why neither lasted, and the free, open-source, self-hostable ledger I built after them."
path = "blog/2026/09/why-did-i-build-homeaccounting"
[taxonomies]
tags = ["haskell", "event-sourcing", "personal-finance", "self-hosting", "homeaccounting"]
categories = ["programming"]
+++

For eleven years I've been writing down what my household spends. One of those years was Excel. The other ten were 1C.

Neither tool survived. Both of them were right about something, and I didn't understand what until I'd lost them.

They also failed the same way, which took me most of those eleven years to see. Every tool I tried was basically a form to fill in. They competed on what happened *after* the data was in (the reports, the charts, the budgets), and they all assumed that getting it in was my job, in my evenings, forever. Sooner or later that bill goes unpaid. So what I set out to build was a ledger that costs no time at all.

<!-- more -->

## Why track anything at all

Ask yourself what last month cost you. Exactly, not roughly. Most people can name their rent and their largest purchase, and then start guessing.

I think that's a record problem more than a discipline problem. Spending arrives as forty small decisions, and you've already forgotten most of them. Memory reconstructs it badly, and always in the same direction: the one expensive thing you agonized over stays vivid, while the deliveries, the subscriptions and the second coffee, which are what actually add up, disappear entirely.

The point of a record is to answer questions about your own life with something better than a guess. Obeying a budget is secondary. What does a normal month cost? What changed when the family grew? Did that raise ever reach us, or did it get absorbed before anyone noticed?

Those answers only exist if you were already keeping the record *before* you needed it. Nobody starts tracking the month they decide to buy an apartment and gets a useful answer. The baseline has to be there already, so the whole thing depends on one property: whether recording is cheap enough that you keep doing it when nothing is at stake.

By cheap I mean cheap in time, not money. A tool that asks for fifteen minutes a week is asking for thirteen hours a year, indefinitely, in exchange for answers you mostly won't need until you suddenly do. Almost nobody keeps that up, and the few who do are unusual rather than virtuous. Every abandoned tracking system I've heard about was abandoned for this reason, never for a missing feature.

So the target is zero time, or as close to zero as the problem allows. Getting there took eleven years.

## The Excel year

I started where everyone starts: four columns (date, amount, category, note) and a pivot table.

For about two months it was perfect. A spreadsheet is the most malleable tool ever built: a new category is a new row, a new question is a new formula, and the whole thing is one file that belongs entirely to me. Nothing I've used since has been that easy to bend.

Then the entry tax started compounding. I had to type every transaction myself, by hand, at a keyboard, after the fact. By evening I was reconstructing the day. By the weekend I was reconstructing the week. By autumn I was opening a file whose last row was three weeks old and feeling something close to guilt.

There was a subtler failure too, and it's the one that stayed with me. A spreadsheet stores what you currently believe. When I found a mistake, I overwrote the cell, and with it went the fact that I had once believed something else and when I stopped believing it. The file only ever held the present. Every correction destroyed a piece of the history I was supposedly keeping.

By month twelve the schema had drifted: categories invented and abandoned, a sheet per month because one sheet got unwieldy, formulas pointing at ranges that no longer meant what they used to. I wasn't tracking my money anymore. I was maintaining a small, badly designed database by hand.

Excel was right that the data should be mine, in one place, open to any question I felt like asking. It was wrong to assume I'd keep paying, forever, for the privilege of typing it in.

## Ten years on 1C

So I went the other way: real accounting software, the kind businesses around me ran on.

I want to be fair to it, because lasting ten years is not an accident. 1C gave me what Excel couldn't: structure that held. The category system didn't drift, because I hadn't invented it on a Tuesday. Transactions balanced. Someone had already thought the reports through. The data survived a decade, several computers, and my own inconsistency. Excel failed in one year and 1C lasted ten. That gap is the whole argument for a real system over a file.

But it was built for a business, and I don't run one. Double-entry ceremony, a chart of accounts, and reporting shaped around a tax authority I don't answer to were all permanent overhead, spent on questions a household never asks. I paid it for ten years and it never got cheaper.

It was also a desk: Windows, one machine, one room. Money gets spent in a shop at two in the afternoon and recorded at nine in the evening, if I remember, and the gap between those two moments is where tracking dies. The phone in my pocket knew about the purchase the instant it happened. The software that was supposed to record it was two hours and one room away.

And I could never make it mine. Changing the interface (the fields I actually use, in the order I use them) meant fighting a platform with firm opinions about how such things are done, and the UX under those opinions was poor to begin with. That's ten years of small daily friction I had no way to file down.

Then came February 2022. Keeping Russian software at the center of my household's records stopped being a trade-off worth weighing, and that ended it. Everything above is why I didn't look for a replacement of the same shape.

## What eleven years taught me

There are three conclusions I'd now defend.

**Capture is the whole problem, and its unit is time.** Every tool I used was good at reporting and bad at getting data in. Reporting is the easy half, the half a computer should have been doing unsupervised all along. Judge a personal finance tool by one number: the minutes per month it takes from you. Everything else is a feature list. If that number isn't near zero, you will stop, and a tool you've stopped using has no reports worth reading.

**A household needs history, not a balance.** My bank already answers "what do I have right now". The questions worth building for are *what happened*, *when*, and *what did I think at the time*, and all three need a record that accumulates instead of one that gets overwritten.

**It has to run where you are.** A tool that lives on one desktop captures only the part of your life that happens in that chair.

And one more, from the way the 1C decade ended: you should be able to *keep* the thing. Ten years of your own records shouldn't be hostage to one vendor's decisions, or, as it turned out, to one country's. If you can't read the source, you're renting the tool, however permanent the lease feels.

## What I built

[HomeAccounting](https://www.homeaccounting.com) is those lessons taken literally.

**Tracking should cost no time.** I built everything else around this requirement, and it's the one I'd hold the project to. A connected bank imports transactions on its own, so for card spending, which is most of what a household does, the minutes-per-month figure really is zero. Nobody types, nobody uploads anything, nobody sits down on Sunday. The ledger fills itself while you're not looking.

**Connecting your bank is the mechanism that makes it automatic.** That's the only reason banks are in this story. You connect an account once, and from then on every card payment, transfer and fee lands in the ledger by itself, already categorized, whether or not you ever open the app. There's no import ritual and no monthly reconciliation session. The automatic import *is* the product, and the rest of this section covers what it can't reach.

The piece that talks to one particular bank is called a provider, and none of them are hardwired. Nothing in the core of the system knows the name of a single bank. A provider is a self-contained module that declares what it can do, and adding one takes that module plus a line in a registry. Monobank and PrivatBank came first for an unglamorous reason: I live in Ukraine and they're my banks. They're the examples, not the design.

Providers come in two shapes, because banks differ in how much they're willing to give you. One is a live connection: fetch the accounts, fetch transactions for a date range, register a webhook so new ones arrive as they happen. That's the zero-time path, and it's what Monobank does today. The other is a statement parser for CSV or XLSX, the file you can download from your bank's web interface, for the many banks that publish no API to anyone. PrivatBank is one of them, for both personal and business accounts, so that's how it works here. It costs you a download a month. That isn't zero, but it decides whether a bank is usable here at all.

Each provider also declares where it operates (worldwide, or a specific set of countries), so you're offered the banks that make sense where you live. That's curation, not a border. The mechanism has no opinion about geography, and a provider for a German, Polish or American bank is exactly as much work as the ones that already exist. Ukraine is simply where the first three landed.

**Manual entry never disappears; it only gets rare.** Cash, a bank nobody has written a provider for yet, the thing your partner paid for. There's an ordinary form for those, but you should rarely need it. The normal path is to write a sentence. Send `coffee 45, taxi 200, groceries 380` to the Telegram bot and three categorized transactions land in the ledger. That takes seconds, standing on the street, instead of minutes at a desk that evening.

That's the LLM part, and it's deliberately not a chatbot. There's no assistant to talk to and no prompt to engineer. The model does one narrow job: it turns the way people actually write about money (shorthand, mixed languages, three purchases in one line, no punctuation) into structured transactions with amounts, categories, and merchants. Prompting is the input method, not a conversation. What matters is that for the first time in eleven years, recording a purchase takes less effort than making it.

**It runs where you are.** There's a web app you can open anywhere, and a Telegram bot for the two-in-the-afternoon moment when you're standing outside the shop. You record the spending where it happens.

**It's open source, and it costs nothing.** Every line is AGPL-3.0: backend, web, and the deployment stack that homeaccounting.com itself runs on. It isn't a source-available licence with a commercial carve-out, or an open core with the useful half sold separately. It's the whole system.

That makes the price simple. Self-host it (one Docker Compose file) and it's free forever, with no account on my side, no licence key, and no permission needed from me. The hosted version is free while it's in beta, and I'd rather say that plainly than promise a "forever" I have no way to underwrite yet.

What I *can* underwrite is the exit, which matters a lot after the decade I just described. There's no paid tier with a feature held hostage, no per-account fee, no export button that hands you a deliberately worse copy of your own data. Those guarantees rest on the licence, not on my good intentions. If the hosted service ever gets worse, or I get bored, or I get hit by a bus, the whole thing is on GitHub and you can be running it yourself the same afternoon, with your history intact. That's the difference between owning a ledger and renting one, and it took me ten years and a war to learn it.

## Why history is the source of truth

Both of my old tools stored *state*. A row was the truth, and editing it made a new truth while silently discarding the old one. After ten years, that leaves you with a ledger full of confident numbers and no idea how they got there.

HomeAccounting stores what happened. Every change is an immutable event, balances and reports are folds over that log, and a correction is a new event instead of an overwrite. Nothing that was true ever gets unwritten.

This design comes straight out of the failures above. Re-categorizing two hundred old transactions doesn't rewrite last March. You can ask what last March looked like *as of last March*, not just as of today. When a bank feed disagrees with your ledger, you get a reconciliation event you can inspect later instead of a mystery edit you made at midnight and forgot.

It's built on [eventium](@/blog/2026-04-eventium-event-sourcing-library-for-haskell.md), the typed event-sourcing and CQRS library for Haskell I've been working on. The design decisions behind it are in [a separate post](@/blog/2026-04-eventium-design-and-internals.md). To be honest about the order: I had the library before I had this application. The fit still isn't retrofitted. A household ledger is a stream of small facts that arrive out of order, get corrected months later, and still have to reconstruct any point in the past on demand. Event sourcing exists to solve exactly that.

## Why Haskell, of all things

The objection is fair, so I'll put it first: Haskell is not popular, and for an open-source project that wants contributors, that's the biggest cost I'm carrying. The pool of people who could casually send a patch is a fraction of what it would be in TypeScript or Go. I knew that going in.

Here's what outweighed it.

**The domain is already functional.** Event sourcing *is* a fold over history. Projections *are* pure functions from an event stream to a view. The rules about money are total functions with no IO anywhere near them. I'm not forcing Haskell onto this problem; the problem already had that shape.

**It's money.** Making illegal states unrepresentable matters more here than in most software. No nulls, no silent coercions, exhaustive matches over every event type the system can produce. If a transaction can quietly turn into a different transaction, I'd rather the compiler refuse it than write a test for it.

**I expect to still be changing this in ten years.** My 1C data lasted a decade, and I'm building for the same horizon, alone, in evenings. Under those constraints the compiler is what makes a large refactor a year from now a Tuesday instead of a rewrite.

**And there's the LLM angle**, which I've [argued at length elsewhere](@/blog/2026-04-haskell-was-waiting-for-this.md): a language whose compiler rejects most of what a model gets wrong is a better partner for AI-assisted work than a popular one that cheerfully accepts it. The same bet shows up twice in this project, once in how transactions get captured and once in how the code gets written.

So I picked the language I'd still want to open in year ten, on a project nobody is paying me to finish. For a personal project that's not a hiring decision. It's a will-I-still-be-here decision.

## Where it actually is

It's early. Honestly early. The bank integrations cover Monobank and PrivatBank because that's where my money lives and that's the audience I can serve properly first. There's one maintainer. Plenty of the app is still a rough first pass.

There's also nothing to buy. This isn't a startup with an open-source phase, and I'm not building an audience to charge later. It's a tool I needed for my own household, released under a licence that guarantees it stays that way for yours.

But the part that killed the last two tools works: recording what you spend now costs almost nothing, and nothing you record gets thrown away.

If you want to look, the [live demo](https://demo.homeaccounting.com) is seeded and needs no signup, the [app](https://homeaccounting.com/app) is free to sign into, the [self-host stack](https://github.com/homeaccounting/docker) is one Docker Compose file, and the source for all of it (backend, web, and deployment) is at [github.com/homeaccounting](https://github.com/homeaccounting). If you've been through your own version of these eleven years, I'd like to hear where your tools broke. The [community links are here](https://www.homeaccounting.com/community).

Eleven years in, the tool finally fits the habit, instead of the other way around.

This post was the *why*. The next one, [*What Is HomeAccounting?*](@/blog/2026-10-what-is-homeaccounting.md), is the *what* and the *how*: the full feature set, how the bank integrations and the Telegram capture work, and what the inside of an event-sourced household ledger looks like.

---

*Part of the **HomeAccounting** series:*

1. **Why Did I Build HomeAccounting?**
2. [What Is HomeAccounting?](@/blog/2026-10-what-is-homeaccounting.md)
