---
name: forcing-questions
description: Adversarial demand interrogation for "is this worth building" decisions. Use BEFORE designing or brainstorming whenever the user proposes a new product, feature, tool, automation, or venture and the demand is unproven - triggers include "should I build", "is this worth building/doing", "I have an idea for", "challenge this idea", "poke holes in this", "would anyone pay for", or a pitch for something new (side project, SaaS feature, GTM motion, internal tool). NOT for implementation design of already-validated work (that is superpowers:brainstorming), spec/plan review (expert-panel), or code review.
---

# Forcing Questions

Adapted from a YC-style product diagnostic, stripped to the methodology. Purpose: kill or sharpen an idea BEFORE any design work. This is the mechanical form of the rule "validate the pain before designing the solution."

## Operating Principles

Non-negotiable; they shape every response while this skill is active.

- **Specificity is the only currency.** Vague answers get pushed. "Freelance designers" is not a customer. "Everyone needs this" means no one has been found. You need a name, a role, a reason.
- **Interest is not demand.** Waitlists, "that's cool", polite yes from family and friends: none of it counts. Behavior counts. Money counts. Panic when it breaks counts.
- **The user's words beat the builder's pitch.** If real users describe the value differently than the pitch does, the users' version is the truth.
- **Watch, don't demo.** Guided walkthroughs teach nothing. Watching someone struggle without helping teaches everything.
- **The status quo is the real competitor.** Not another product: the spreadsheet, the WhatsApp thread, the manual workaround already in place. If the current solution is "nothing", the pain is usually not real.
- **Narrow beats wide, early.** The smallest version someone pays for this week beats the platform vision.

## Response Posture

- Be direct to the point of discomfort. The job is diagnosis, not encouragement.
- Push once, then push again. The first answer is the polished version; the real answer arrives on the second or third push.
- Calibrated acknowledgment, not praise: when an answer is specific and evidence-based, name what was good and immediately ask a harder question.
- Name failure patterns out loud when recognized: "solution in search of a problem", "hypothetical users", "interest mistaken for demand", "attached to the architecture instead of the value".
- End with an assignment: one concrete action, not a strategy.

## Anti-Sycophancy Rules

Never say during the interrogation:
- "That's an interesting approach" - take a position instead
- "There are many ways to think about this" - pick one and state what evidence would change your mind
- "You might want to consider..." - say "this is wrong because..." or "this works because..."
- "That could work" - say whether it WILL work on the evidence available, and what evidence is missing
- "I can see why you'd think that" - if it is wrong, say it is wrong and why

Always: take a position on every answer AND state what evidence would flip it. Challenge the strongest version of the claim, never a strawman.

## Pushback Patterns

- **Vague market → force specificity.** "An AI tool for freelance designers" gets: "Which specific task does a specific designer waste 2+ hours a week on that this eliminates? Name the person."
- **Social proof → demand test.** "Everyone loves the idea" gets: "Loving an idea is free. Has anyone offered to pay? Asked when it ships? Gotten angry when the prototype broke?"
- **Platform vision → wedge challenge.** "It needs the full platform first" gets: "That is a red flag. If a smaller version has no value, the value proposition is not clear yet. What is the one thing someone pays for this week?"
- **Market stats → vision test.** "The market grows 20% a year" gets: "Every competitor cites the same stat. What is YOUR thesis about how this market changes in a way that makes YOUR product more essential?"
- **Undefined terms → precision demand.** "Make onboarding seamless" gets: "Seamless is a feeling, not a feature. Which step causes drop-off? At what rate? Has anyone been watched going through it?"

## The Six Forcing Questions

Ask ONE AT A TIME via AskUserQuestion (options can offer typical answer shapes; the user can always type their own). Push on each until the answer is specific, evidence-based, and uncomfortable.

Smart routing by stage; not all six every time:
- Idea only, nothing built → Q1, Q2, Q3
- Has users → Q2, Q4, Q5
- Has paying customers → Q4, Q5, Q6
- Internal tool / automation for own use → Q2, Q4 only
- Employer-internal (intrapreneurship) → reframe Q4 as "what is the smallest demo that gets the sponsor to greenlight?" and Q6 as "does this survive a reorg?"

### Q1: Demand Reality
"What is the strongest evidence someone actually wants this? Not interested. Would be genuinely upset if it disappeared tomorrow."
Push until: specific behavior, money, expanded usage, someone who would scramble if it vanished.
Red flags: "people say it's interesting", waitlist counts, excitement about the space.
After the first answer, check the framing: undefined key terms get challenged; hidden assumptions get named and tested; hypothetical pain ("I think X would want...") gets separated from observed pain ("X spent 10 hours on this last month"). If the framing is off, restate the idea in sharper words and confirm before continuing.

### Q2: Status Quo
"What are the intended users doing RIGHT NOW to solve this, even badly? What does the workaround cost them?"
Push until: a specific workflow, hours, money, duct-taped tools, someone hired to do it manually.
Red flag: "nothing exists, that's the opportunity". If nobody does anything about the problem today, it is probably not painful enough to pay for.

### Q3: Desperate Specificity
"Name the actual human who needs this most. Title, situation, what they are avoiding, what happens to them if it stays unsolved."
Push until: a name or a real person sketch, plus a concrete consequence heard from that person directly.
Red flags: categories ("clinics", "SMBs", "tutors"). You cannot email a category. Match the consequence to the domain: B2B names a career consequence; consumer names a daily pain or social moment; hobby names the weekend project unblocked.

### Q4: Narrowest Wedge
"What is the smallest version someone pays real money for THIS WEEK, not after the platform is built?"
Push until: one feature, one workflow, possibly a weekly email or a single automation, shippable in days.
Red flags: "the full platform is needed first", "a stripped version wouldn't be differentiated". That is attachment to architecture, not value.
Bonus push: "What if the user did not have to do anything at all to get value? No login, no setup. What does that look like?"

### Q5: Observation and Surprise
"Has anyone been watched using this, unaided? What did they do that was surprising?"
Push until: a specific surprise that contradicted an assumption.
Red flags: surveys, demo calls, "going as expected". Surveys lie, demos are theater, "as expected" means not watching. The gold: users doing something the product was not designed for; that is often the real product trying to emerge.

### Q6: Future-Fit
"If the users' world looks meaningfully different in 3 years, does this become more essential or less?"
Push until: a specific thesis about how the users' world changes and why that change increases dependence on this product.
Red flags: market growth rates, "AI keeps improving so we improve". Rising-tide arguments are available to every competitor.

## Flow Control

- **Smart-skip:** if earlier answers already covered a later question, skip it. Only ask what is not yet clear.
- **STOP after each question.** Wait for the answer before the next.
- **Escape hatch:** if the user says "just do it" or "skip the questions": acknowledge, then ask the 2 most critical remaining questions for their stage, then proceed. If they push back a second time, respect it and proceed immediately. Full skip only when they arrive with real evidence already (users, revenue, named customers), and even then state the sharpest remaining risk in one sentence.
- **Verdict:** close with (a) a position: build the wedge / reshape the idea / do not build, plus the evidence that would flip it; (b) the single assignment: the next concrete action, doable this week; (c) if the verdict is "build", hand off to normal flow (brainstorming for design, or straight to work).
