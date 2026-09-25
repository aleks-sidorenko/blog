+++
title = "Why Did I Build HomeAccounting?"
date = 2026-09-25
description = "Eleven years of tracking household money — one year in Excel, ten in 1C. What both tools got right, why neither survived, and the open-source, self-hostable, no-charge ledger I built out of the wreckage."
path = "blog/2026/09/why-did-i-build-homeaccounting"
[taxonomies]
tags = ["haskell", "event-sourcing", "personal-finance", "self-hosting", "homeaccounting"]
categories = ["programming"]
+++

For eleven years I've been writing down what my household spends. One of those years was Excel. The other ten were 1C.

Neither tool survived. Both of them were right about something, and I didn't understand what until I'd lost them.

They also failed the same way, which took me most of those eleven years to see. Every tool I tried was fundamentally a form to fill in. They competed on what happened *after* the data was in — the reports, the charts, the budgets — and they all quietly agreed that getting it in was my job, in my evenings, forever. That's the bill that eventually goes unpaid. So the thing I actually set out to build wasn't a better ledger. It was one that costs no time at all.

<!-- more -->

## Why track anything at all

Ask yourself what last month cost you. Not roughly — actually. Most people can name their rent and their largest purchase, and then start guessing.

I don't think that's a discipline problem. It's a record problem. Spending doesn't arrive as a number; it arrives as forty small decisions you've already forgotten. Memory reconstructs it badly, and in a consistent direction: the one expensive thing you agonized over stays vivid, while the deliveries, the subscriptions, the second coffee — the things that actually add up — disappear entirely.

The reason to keep a record isn't to obey a budget. It's to be able to answer a question about your own life with something other than a guess. What does a normal month cost? What changed when the family grew? Did that raise ever reach us, or did it get absorbed before anyone noticed?

And those answers only exist if you were already keeping the record *before* you needed it. Nobody starts tracking the month they decide to buy an apartment and gets a useful answer. The baseline has to be there already — which means the whole thing lives or dies on one property: whether recording is cheap enough that you keep doing it when nothing is at stake.

Cheap in one currency specifically. Not money — time. A tool that asks for fifteen minutes a week is asking for thirteen hours a year, indefinitely, in exchange for answers you mostly won't need until you suddenly do. Nobody sustains that, and the people who do are not being virtuous, they're being unusual. Every abandoned tracking system I've ever heard about was abandoned for this reason, and never for a missing feature.

So the target isn't *less* time. It's zero, or as close to zero as the problem allows. Getting there took eleven years.

## The Excel year

I started where everyone starts. Four columns — date, amount, category, note — and a pivot table.

For about two months it was perfect. A spreadsheet is the most malleable tool ever built: a new category is a new row, a new question is a new formula, and the whole thing is one file that belongs entirely to me. Nothing I've used since has been that easy to bend.

Then the entry tax started compounding. Every transaction had to be typed by me, by hand, at a keyboard, after the fact. So by evening I was reconstructing the day. By the weekend I was reconstructing the week. By autumn I was opening a file whose last row was three weeks old and feeling something adjacent to guilt.

There was a subtler failure too, and it's the one that stayed with me. A spreadsheet stores what you currently believe. When I found a mistake, I overwrote the cell — and the fact that I had once believed something else, and when I stopped believing it, was gone. The file only ever held the present. Every correction quietly destroyed a piece of the history I was supposedly keeping.

By month twelve the schema had drifted: categories invented and abandoned, a sheet per month because one sheet got unwieldy, formulas pointing at ranges that no longer meant what they used to. I wasn't tracking my money. I was maintaining a small, badly designed database by hand.

Excel was right that the data should be mine, in one place, open to any question I felt like asking. It was wrong that I would keep paying, forever, for the privilege of typing it in.

## Ten years on 1C

So I went the other way: real accounting software, the kind actual businesses around me ran on.

I want to be fair to it, because it lasted ten years, and that isn't an accident. 1C gave me exactly what Excel couldn't: structure that held. A category system that didn't drift, because I hadn't invented it on a Tuesday. Transactions that balanced. Reports someone had already thought about. Data that survived a decade, several computers, and my own inconsistency. Excel failed in one year; 1C lasted ten. That gap is the entire argument for using a real system instead of a file.

But it was built for a business, and I don't run one. Double-entry ceremony, a chart of accounts, reporting shaped around a tax authority I don't answer to — permanent overhead levied against questions a household never asks. I paid it for ten years and it never got cheaper.

It was also a desk. Windows, one machine, one room. Money gets spent in a shop at two in the afternoon and recorded at nine in the evening, if I remember — and the gap between those two moments is precisely where tracking goes to die. The phone in my pocket knew about the purchase the instant it happened. The software responsible for recording it was two hours and one room away.

And I could never make it mine. Changing the interface — the fields I actually use, in the order I actually use them — meant fighting a platform with firm opinions about how such things are done, and the UX underneath those opinions was poor to begin with. Ten years of small daily friction I had no way to file down.

Then February 2022. Keeping Russian software at the center of my household's records stopped being a trade-off worth weighing. That ended it. Everything above is why I didn't go looking for a replacement in the same shape.

## What eleven years taught me

Three conclusions I'd now defend.

**Capture is the whole problem, and its unit is time.** Every tool I used was good at reporting and bad at getting data in — and reporting is the easy half, the half a computer should have been doing unsupervised all along. Judge a personal finance tool by exactly one number: the minutes per month it takes from you. Everything else is a feature list. If that number isn't near zero, you will stop, and a tool you've stopped using has no reports worth reading.

**A household needs history, not a balance.** What do I have right now is the one question my bank already answers. The questions worth building for are *what happened*, *when*, and *what did I think at the time* — and all three need a record that accumulates rather than one that gets overwritten.

**It has to run where you are.** Not where your desk is. A tool that lives on one desktop captures only the fraction of your life that happens in that chair.

And one more, from the way the 1C decade ended: you should be able to *keep* the thing. Ten years of your own records shouldn't be hostage to one vendor's decisions — or, as it turned out, to one country's. A tool whose source you can't read is a tool you are renting, however permanent the lease feels.

## What I built

[HomeAccounting](https://www.homeaccounting.com) is what those lessons look like taken literally.

**Tracking should cost no time.** This is the requirement everything else was built around, and the one I'd hold the project to. A connected bank imports transactions on its own — so for card spending, which is most of what a household does, the minutes-per-month figure is genuinely zero. Nobody types, nobody uploads anything, nobody sits down on Sunday. The ledger fills itself while you're not looking.

**Banks are plugged in, not baked in.** Monobank and PrivatBank came first for an entirely unglamorous reason: I live in Ukraine and they're my banks. That's the only reason. Nothing in the core of the system knows the name of a single bank — a provider is a self-contained module that declares what it can do, and adding one is that module plus a line in a registry.

Providers come in two shapes, because banks differ in how much they're willing to give you. One is a live connection: fetch the accounts, fetch transactions for a date range, register a webhook so new ones arrive as they happen. That's the zero-time path. The other is a statement parser — CSV or XLSX, the file you can download from any bank's web interface — for the many banks that offer no API to anyone. It's the worse path, because downloading a file is a chore, and it is still the difference between a bank being supported and not.

Each provider also declares where it operates — worldwide, or a specific set of countries — so you're offered the banks that make sense where you live. That's curation, not a border. The mechanism has no opinion about geography, and a provider for a German or Polish or American bank is exactly as much work as the ones that already exist. Ukraine is simply where the first three landed.

**Manual entry never disappears — it only gets rare.** Cash, a bank nobody has written a provider for yet, the thing your partner paid for. There's an ordinary form for those, but needing it should be the exception; the normal path is to write a sentence. Send `coffee 45, taxi 200, groceries 380` to the Telegram bot and three categorized transactions land in the ledger — seconds, standing on the street, instead of minutes at a desk that evening.

That's the LLM part, and it's deliberately not a chatbot. There's no assistant to converse with, no prompt to engineer. The model does one narrow job: turn the way a person actually writes about money — shorthand, mixed languages, three purchases in one line, no punctuation — into structured transactions with amounts, categories, and merchants. Prompting as an input method rather than a conversation. What makes it matter isn't that there's a model involved; it's that for the first time in eleven years, recording a purchase costs less effort than making it.

**It runs where you are.** A web app you can open anywhere, and a Telegram bot for the two-in-the-afternoon moment when you're standing outside the shop. The recording happens where the spending happens.

**It's open source, and it costs nothing.** Every line is AGPL-3.0 — backend, web, and the deployment stack that homeaccounting.com itself runs on. Not a source-available licence with a commercial carve-out, and not an open core with the useful half sold separately. The whole system.

Which makes the price simple. Self-host it — one Docker Compose file — and it is free forever, with no account on my side, no licence key, and no permission needed from me. The hosted version is free while it's in beta, and I'd rather say that plainly than promise a "forever" I have no way to underwrite yet.

What I *can* underwrite is the exit, and that's the part that matters after the decade I just described. There's no paid tier with a feature held hostage, no per-account fee, no export button that hands you a deliberately worse copy of your own data. Those aren't promises resting on my good intentions — they rest on the licence. If the hosted service ever gets worse, or I get bored, or I get hit by a bus, the entire thing is on GitHub and you can be running it yourself the same afternoon, with your history intact. That is the whole difference between owning a ledger and renting one, and it took me ten years and a war to learn it.

## Why history is the source of truth

Both of my old tools stored *state*. A row was the truth, and editing it made a new truth while silently discarding the old one. Ten years in, that means a ledger full of confident numbers and no idea how they got there.

HomeAccounting stores what happened. Every change is an immutable event; balances and reports are folds over that log; a correction is a new event rather than an overwrite. Nothing that was true is ever unwritten.

This isn't architecture for its own sake — it falls directly out of the failures above. Re-categorizing two hundred old transactions doesn't rewrite last March. You can ask what last March looked like *as of last March*, not just as of today. A bank feed disagreeing with your ledger becomes a reconciliation event you can inspect later, instead of a mystery edit you made at midnight and forgot.

It's built on [eventium](@/blog/2026-04-eventium-event-sourcing-library-for-haskell.md), the typed event-sourcing and CQRS library for Haskell I've been working on; the design decisions behind it are in [a separate post](@/blog/2026-04-eventium-design-and-internals.md). I'll be honest about the order of events: I had the library before I had this application. But the fit isn't retrofitted. A household ledger is a stream of small facts that arrive out of order, get corrected months later, and must still reconstruct any point in the past on demand. That is the problem event sourcing exists to solve.

## Why Haskell, of all things

The objection is fair, so let me put it first: Haskell is not popular, and for an open-source project asking for contributors that's the single largest cost I'm carrying. The pool of people who could casually send a patch is a fraction of what it would be in TypeScript or Go. I knew that going in.

Here's what outweighed it.

**The domain is already functional.** Event sourcing *is* a fold over history. Projections *are* pure functions from an event stream to a view. The rules about money are total functions with no IO anywhere near them. Haskell isn't imposed on this problem — it's the shape the problem already had.

**It's money.** Making illegal states unrepresentable matters more here than in most software. No nulls, no silent coercions, exhaustive matches over every event type the system can produce. The class of bug where a transaction quietly becomes a different transaction is one I'd rather have the compiler refuse than write a test for.

**I expect to still be changing this in ten years.** My 1C data lasted a decade; I'm building for the same horizon, alone, in evenings. Under those constraints the compiler isn't a formality — it's the reason a large refactor a year from now is a Tuesday rather than a rewrite.

**And there's the LLM angle**, which I've [argued at length elsewhere](@/blog/2026-04-haskell-was-waiting-for-this.md): a language whose compiler rejects most of what a model gets wrong is a better partner for AI-assisted work than a popular one that cheerfully accepts it. The same bet shows up twice in this project — once in how transactions get captured, once in how the code gets written.

So: I picked the language I'd still want to open in year ten, on a project nobody is paying me to finish. For a personal project that's not a hiring decision. It's a will-I-still-be-here decision.

## Where it actually is

Early. Honestly early. The bank integrations cover Monobank and PrivatBank because that's where my money lives and that's the audience I can serve properly first. There's one maintainer. Plenty of the app is still a rough first pass.

There is also nothing to buy. This isn't a startup with an open-source phase, and I'm not building an audience to charge it later — it's a tool I needed for my own household, released under a licence that guarantees it stays that way for yours.

But the part that killed the last two tools is the part that works: recording what you spend now costs almost nothing, and nothing you record gets thrown away.

If you want to look: the [live demo](https://demo.homeaccounting.com) is seeded and needs no signup, the [app](https://homeaccounting.com/app) is free to sign into, the [self-host stack](https://github.com/homeaccounting/docker) is one Docker Compose file, and the source for all of it — backend, web, and deployment — is at [github.com/homeaccounting](https://github.com/homeaccounting). If you've been through your own version of these eleven years, I'd genuinely like to hear where your tools broke — the [community links are here](https://www.homeaccounting.com/community).

Eleven years in, the tool finally fits the habit, instead of the other way around.

This post was the *why*. The next one — *What Is HomeAccounting?* — is the *what* and the *how*: the full feature set, how the bank integrations and the Telegram capture actually work, and what the inside of an event-sourced household ledger looks like.

---

*Part of the **HomeAccounting** series:*

1. **Why Did I Build HomeAccounting?**
2. What Is HomeAccounting? *(coming soon)*
