# Dispatch and Orchestration Playbook

Applies in every session, on any model. Rules 1 and 2 are mechanically enforced
by `guard-agent-briefing.sh` when hooks are installed (tier 2): it blocks the
dispatch and echoes the fix. At tiers 0 and 1 they are conventions you follow by
hand.

Rule numbering is kept sparse on purpose. Gaps in the sequence are intentional,
not missing rules.

## 1. Every dispatch is a briefing, not a sentence

Subagents start with ZERO conversation context. They have not seen the user's
request, prior tool results, or decisions made this session. Write every Agent
prompt as a self-contained briefing with these five parts:

1. **OBJECTIVE**: one verifiable goal.
2. **CONTEXT**: why the task exists, what was already decided or ruled out this
   session, exact file paths, and PASTED snippets or data the agent needs.
   Never write "as discussed" or "the file mentioned above". The agent cannot
   see it.
3. **SCOPE**: what NOT to touch (write boundaries, adjacent workstreams, files
   to leave alone).
4. **OUTPUT CONTRACT**: the agent's final message is the ONLY thing that comes
   back. Specify its exact shape, e.g. "return a markdown table of path:line
   plus a one-line finding, no prose intro". Tell the agent to return raw data,
   not a narrative of its process.
5. **DONE CHECK**: how the agent verifies its own work before returning (run
   the test, curl the endpoint, re-grep the tree).

The guard enforces a minimum of 500 characters for general-purpose dispatches
and 200 for Explore/Plan. A deliberate tiny dispatch carries `[brief-ok]` in the
prompt, which waives the length minimum and nothing else.

## 2. Pick the model per dispatch, never inherit by default

Pass `model` explicitly on every general-purpose dispatch AND on every
Workflow-tool `agent()` call. Unpinned calls inherit the session model, which is
how one script quietly fans a whole fleet out on the priciest tier.

- **haiku**: mechanical work (extraction, reformatting, log scans, checklist
  sweeps).
- **opus**: default executor. Code, standard multi-step tasks, adversarial
  verification, judging other agents' output, architecture decisions.
- **sonnet**: deliberate step-down for bulk or well-fenced work where opus is
  overkill and the output contract is simple. Pin it on purpose, not by habit.
- **Any tier above the ones named here** (a premium, conductor-tier model, where
  the environment offers one): conductor only, never an executor. Because it is the
  most capable and most expensive tier available, an executor that inherits it is
  the largest single cost leak you can create. The guard blocks dispatches pinned
  to this tier, and pin-free Workflow scripts, unless the prompt carries the
  deliberate override marker (which the guard names when it blocks). That override
  should be rare, for example an adversarial judge on a high-stakes call.

The guard injects a pin on EVERY unpinned dispatch, typed specialists included,
because marketplace plugin agents commonly ship `model: "inherit"`, which
resolves to the session model. Injection is sonnet for Explore/Plan and opus for
everything else. An explicit call-time model always wins.

Never set `CLAUDE_CODE_SUBAGENT_MODEL` in settings. It silently overrides every
per-call model pin, including the haiku and sonnet step-downs above, and it does
so invisibly. "Default executor" is this rule, enforced by passing `model`
explicitly on every dispatch, never an environment variable.

## 4. Orchestrator stance and dispatch triggers

In multi-step work the main session conducts: decompose, dispatch, judge,
integrate. Executors write the code and the content.

Delegate a task to a subagent when it hits ANY of these:

- **Cheap to verify**: checking the result costs far less than producing it
  (tests exist, the output is diffable, a wrong answer is obvious on sight).
- **Bulk reading**: answering needs 3 or more files read. The main thread keeps
  only the conclusion, never the raw material.
- **Repetitive**: the third same-shape task is delegation material by default.
- **Low-stakes**: a bad result costs a retry, not a cleanup.

A trigger hit wins over task size. There is no keep-inline size floor. "It is
only five minutes of file moves" is precisely the work that goes out: file moves
and renames, batch edits, reformatting, mechanical sweeps.

Keep work inline ONLY when it is:

- a true one-off: a single file touched with a single edit or command;
- work whose doing is the point (learning, taste-forming, judgment calls);
- a step the user is actively collaborating on turn by turn.

Scale the fan-out to the task: one focused agent for a one-file question, a
fleet only when coverage genuinely needs it.

## 9. Human-reserved categories (never fully delegated)

No agent, automated pipeline, or autonomous run ships these without the human in the loop.
Agents may DRAFT, never send or apply.

- **Client and confidential data boundaries**: anything touching customer data,
  anything covered by an NDA, anything that would move employer or client
  material into a personal tool or account. On a gray area, stop and ask.
- **Outbound communications**: email, chat messages, tickets, comments, posts,
  anything addressed to a customer, a counterparty, or the public. Draft only,
  always.
- **Spend and procurement**: purchase orders, expense or spend approvals, vendor
  payments, license purchases, anything that commits or moves company money.
- **Anything contractual**: statements of work, quotes, commitments on scope or
  date, license or security attestations, and anything a counterparty could
  reasonably read as a promise from the employer.

Review stays exception-based everywhere else, but these four categories are
appointment-based: a human look is the gate, not a sample.
