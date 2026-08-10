# Dispatch and Orchestration Playbook

Applies in every session. These are conventions you follow by hand; nothing here
is enforced by a hook.

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

A one-line dispatch that skips these parts is the most common cause of a subagent
returning the wrong thing. Give a general-purpose agent enough context to stand
on its own; an Explore or Plan agent can take less, but still needs the objective
and the output contract.

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
