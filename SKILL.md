---
name: llm-token-economy
description: Token-cost discipline for building and operating LLM agent systems (Claude first, any provider). Use this skill whenever you design, write, review or deploy code that calls a model - a new agent loop, supervisor or specialist, a tool, a background job or scheduler, a memory, reflection or extraction pipeline, a dashboard, report or document generator, a retry or validation loop - and whenever someone says a product is "token hungry", asks why the bill is high, plans a cost optimisation, picks a model or effort level, or sets a token budget. Also use it after any cost incident or usage-ledger analysis to record the learning, so the rules keep improving. It carries the rules, phase checklists, measurement queries, and a living log of real failures with the rule each one produced.
---

# LLM token economy

Last updated: 2026-10-28. Learnings log: `references/learnings.md` (17 entries).

## Why this exists

Agent systems do not get expensive because models write long answers. They get expensive because of structure: a loop that re-sends its whole conversation uncached, a tool that returns 60k characters that every later step re-reads, a specialist that regenerates a whole HTML page inside a tool argument and retries when it does not fit, a pipeline that runs the priciest model after every turn for a fact nobody reads. In one measured product (two client copies, Oct 2026) four such defects were 80% of spend; the per-turn memory and history that everyone suspected were under 5% (`references/learnings.md`).

Three facts drive every rule below:

- **Cost grows with the square of loop length.** Every step re-sends everything before it. Caching reprices that to about 5 to 10% of base input. Nothing else comes close as a lever.
- **The four token kinds have very different prices.** On Claude Opus 5.5: uncached input $4, cache write $5, cache read $0.20, output $20 per million. Output is 100× a cache read. Thinking is billed as output.
- **The unit is cost per completed task, not per token.** A truncated attempt, a failed run, a retry storm or a cheaper model that needs more turns all bill in full and deliver nothing.

Work the levers in this order, from the official guide: free wins first (caching, input hygiene, loop hygiene, output hygiene, batch), then tradeoffs (budgets, effort, model). Never trade quality for cost silently: every tradeoff goes behind a setting and an A/B.

## The rules

### R1. Measure first, from the usage fields, per call

Record every model call in your own ledger with `input_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`, `output_tokens`, model, role (which agent), feature, run id, thread, latency and computed cost. Attribute delegates and background jobs correctly. Without this you argue from code; with it the top three causes fall out of five SQL queries (`references/measurement.md`).

Read the healthy-loop signature on every agent loop: `cache_read` grows step by step, `cache_write` is about one step's delta, `input_tokens` is a handful. Any other shape is a defect. Re-check after every change to prompt assembly and after every deploy: the costliest caching failure is silent and looks like success.

Why: on one install the conversation cache had been shipped, merged and tested, and still did not reach a client copy for a whole day. The ledger showed it in one query (L-002).

### R2. One construction path for every model call, and it caches

Build every agent loop, specialist, playbook, watcher and repair agent through the same factory that places an explicit cache breakpoint on the static prefix and turns on automatic caching for the conversation tail. A plain `create_react_agent(model, tools, prompt=STRING)` anywhere in the codebase is a bug by default. One-shot calls (reflection, classification) get no conversation cache: a write on a tail that is never read is pure surcharge.

Keep `system`, `tools` and `model` byte-identical for the life of a conversation. Dynamic content (date, memory, user state) goes after the cached prefix, as a user message or a mid-conversation system message. Deterministic serialisation everywhere (sort keys, stable tool order). Minimum cacheable prefix on current Claude models is 512 tokens; shorter prompts silently do not cache.

Why: the loops outside the main graph (nightly exploration, watch compiler, triage) ran at 0% cache and cost up to $1.30 per run on Opus (L-003). Cache going live cut supervisor cost per call by 74% (L-002).

### R3. Never make the model emit a bulk artefact as a tool argument

HTML pages, long JSON documents, file contents, full reports: these are output tokens at the dearest rate, they are re-emitted on every preview, save and retry, and on Claude 5 models they share `max_tokens` with thinking. Instead:

- The model writes a compact spec (a chart spec, a document outline, a patch). Fixed app code renders it.
- Preview returns a handle; save takes the handle, not the content again.
- Revisions are patches (replace a range), never a full rewrite.
- `max_tokens` is a backstop, not a tuning knob. Set it high enough that a legitimate answer never hits it, treat `stop_reason: max_tokens` as a failed attempt, surface it, and never retry blindly at the same cap.
- Put required arguments the model writes last (the big one) after the small ones, so a truncated call fails validation early and visibly rather than looping.

Why: a dashboard specialist emitted 15k to 33k characters of HTML plus queries per call; the configured 8,192 cap was silently floored to 16,000 for thinking; 17 calls hit exactly 16,000 output tokens, cost $7.08, 27% of the worst day, and produced nothing. The same product's chart-spec path built a dashboard for $0.85 (L-001, L-007).

### R4. Bound every tool result in code, and keep stable reference data out of the loop

A tool result stays in the conversation for the rest of the run. A 20k-character result is about 7k tokens written to cache once and read on every later step; in a 23-step run it is the dominant growth term. So:

- Every tool has a hard cap enforced in code, sized to what the model needs to decide (a few thousand characters for rows and search hits), with a note saying it was cut and how to get more.
- Return a summary plus a handle for anything large (a CSV in the workspace, a draft id, a section name to fetch next).
- Measure real payloads by calling the tools directly; a cap in a docstring or a helper that only trims optional fields is not a cap.
- Stable reference material the model needs every run (a semantic model, a schema summary, a style guide) belongs in the cached system prefix or a cheap on-demand section tool, not in a 60k-character per-run dump.
- Skills: load the method, not the manual. Trim SKILL.md bodies; the index is enough until the model chooses one.

Why: `get_model` returned 62,074 characters because its 20,000 cap was never enforced; runs that called it cost 3.2× the others (L-004). A full SKILL.md was loaded 24 times in a day (L-009).

### R5. Fewer, larger steps; caps and budgets that mean something

Most calls in a long loop are dispatch steps: the model reads everything and emits a 100-token tool call. In the measured product 63% of supervisor calls returned under 200 tokens and still cost 39% of the spend (L-008). So:

- Design tools and skills so one step does a lot: batched SQL, several tool calls per turn (execute them in parallel and return all results in one message), server-side or programmatic composition where intermediates do not matter.
- Delegate self-contained bulky work to a subagent that returns one line, on the cheapest adequate model.
- Cap steps per task class (quick lookup vs investigation) and cap retries and delegations per run in code, not in prompt text. "At most 3 rounds" in a prompt enforces nothing (L-001).
- Budgets: a budget that counts cache reads at full weight limits step count, not cost. A four-call run counted 201k of a 300k budget (L-006). Budget by cost or by uncached-equivalent tokens, keep the defaults, and never raise a budget to 15× to make a broken flow pass.
- A validation or grounding re-ask should be a small targeted call, not a second full run (L-013).

### R6. The cheapest adequate model per role, decided by A/B, frontier-at-low-effort first

Model choice is the last lever, but defaults matter from day one:

- Every role has its own model and effort setting with a one-line rollback. Background pipelines (extraction, summaries, reminders, digests) never inherit the main agent's frontier model by default.
- Before stepping down a tier, test the current model at lower effort: on current Claude models lower effort often matches a prior tier at high effort, and one model keeps one cache namespace.
- Thinking is on by default on Claude 5 models and billed as output; effort is the control (Opus 5.5 and Haiku 5.5 default `medium`, Sonnet 5.5 `high`). Set it per route and pin it; changing it mid-conversation invalidates the messages cache.
- Decide with a blind A/B on the traffic the role handles, hard cases included, repeated runs. "Close enough" is not parity.
- Price the tail: the bill is decided by the hardest tenth of tasks.

Why: memory-graph extraction ran on OpenAI gpt-5.5 ($5 / $30) for about 250 two-thousand-token calls a day, 13 to 16% of spend, while the configured Anthropic path on Sonnet 5.5 was opt-in and untested (L-005). Haiku 5.5 matched Opus on quick lookups 6 of 6 and lost on heavy questions (L-016).

### R7. Background work is gated, debounced, capped and batched

Anything that fires on an event or a timer multiplies with volume while nobody watches:

- Gate on content: no reflection or extraction for trivial turns, acknowledgements, progress pings or the system's own summaries.
- Debounce event loops to a window instead of a per-event call with a 10k-character prompt.
- Attempt caps and backoff on every retry path; a persistent 400 must not re-bill the same prompt every 10 seconds (L-010).
- Batch API (50% off every token, cache included) for nightly and backfill work nobody is waiting for.
- Delete jobs nothing reads. A nightly rebuild whose output no view or prompt consumes is pure spend (L-005).
- Use deterministic code where the decision is rule-based (a reminder count, a digest) instead of an agent run.

## Phase checklists

### Design (before writing code)

- [ ] For each model call: who triggers it, how often, what is in the prompt, what comes back, which model and effort, what is the maximum plausible context. Write the number down.
- [ ] One model-construction factory; caching and ledger attribution are properties of the factory, not of callers.
- [ ] No bulk artefact leaves the model as text or a tool argument; specs, handles and patches instead (R3).
- [ ] Every tool result has a numeric cap and a "more" path (R4).
- [ ] Stable reference data placed in the cached prefix or an on-demand section tool.
- [ ] Per-role model and effort settings with rollback; background roles default to the cheapest adequate model.
- [ ] Step, retry and delegation caps per task class; budgets by cost.
- [ ] Which background jobs can run through the Batch API; which can be deterministic code.

### Build (code review)

Grep for these before merging; each is a defect until justified:

- `create_react_agent(` or `messages.create(` outside the factory, or a string prompt without the cache breakpoint.
- `datetime.now`, `uuid4`, request ids, unsorted `json.dumps` or set iteration anywhere that feeds `system` or `tools`.
- A tool returning `json.dumps(obj)` with no cap, or a `[:N]` only on an optional branch.
- `code: str`, `html: str`, `content: str` arguments on save or preview tools.
- `max_tokens` set from a config that another layer silently overrides; a floor applied for thinking that the config page does not show.
- Retries or `recursion_limit` as the only stop for a failing loop; "at most N" in prompt text with no code behind it.
- A budget that sums `total_tokens` (cache reads at full weight).
- A pipeline calling a frontier or non-default-provider model with no setting and no A/B record.
- An event loop with no attempt counter and no debounce.

### Ship (gates before production traffic)

- [ ] Ledger live and attributed; one dashboard or query set per role (`references/measurement.md`).
- [ ] On the deployed build, not the branch: a two-request cache probe shows `cache_read_input_tokens > 0` on the second; every agent loop shows the healthy signature in its first real run.
- [ ] Zero calls with `output_tokens == max_tokens` in the smoke runs.
- [ ] Largest tool payloads measured in characters and under their caps.
- [ ] Per-role model and effort recorded with the A/B evidence or an explicit "default, untested" note.
- [ ] Budgets, step caps and attempt caps at defaults; any override has a written reason.
- [ ] Nightly and event jobs listed with trigger, gate, cap, model and expected daily cost.

### Operate (weekly, or after any spend alert)

- Run the five measurement queries. Rank roles by dollars. Look at the top three runs call by call.
- Look for: uncached share above about 10% on any loop; any `output_tokens == max_tokens`; runs over the p90 step count; a role whose spend grew faster than its traffic; failed runs and what they cost.
- Any new finding goes into the learnings log (protocol below) before it is fixed, so the rule survives the fix.

## References (read on demand)

- `references/learnings.md`: the incident log. Read it when reviewing an architecture or when a symptom looks familiar; search by symptom.
- `references/measurement.md`: ledger schema, attribution, the SQL that finds the causes, how to measure prompt and payload sizes, how to read the healthy-loop signature.
- `references/anthropic-levers.md`: the official facts this skill relies on (caching minimums, TTL economics, invalidation hierarchy, Batch, effort and thinking per model, max_tokens, context editing, forced tool choice), with the date they were checked. Verify prices and model behaviour against the live docs before quoting them; the `claude-api` skill's `cost-optimize` subcommand is the full workflow when one is available.
- `scripts/ledger_queries.sql`: the queries as a runnable file (Postgres; adapt table and column names).

## How this skill keeps learning

The log is the asset. Rules without the incident behind them get argued away; incidents without a rule get repeated.

After any cost incident, usage-ledger analysis, A/B result or production surprise about tokens:

1. Append an entry to `references/learnings.md` using the template at its top: id, date, system, symptom, evidence with numbers, root cause, the fix, the rule it produced, status. Keep it to what was measured; mark inferences as such.
2. If the entry produces a new rule or changes one, edit the rule in this file and cite the entry id in its "Why". If it only adds evidence, cite it under the existing rule.
3. If it produced a reusable query or a measurement trick, add it to `references/measurement.md` or `scripts/`.
4. Update the "Last updated" line and the entry count at the top of this file. Keep this file under 500 lines; move detail to references when it grows.
5. Positive results count too: an A/B that showed a cheaper setting held quality is a learning, with its evidence, and so is a lever that did not pay off.

When the owner asks to "update the token skill", "log this learning" or "remember this cost lesson", do steps 1 to 4 and show the diff. When reviewing a new system, start by scanning the learnings log for symptoms that match, then apply the phase checklist for the phase the project is in.
