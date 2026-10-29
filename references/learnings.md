# Learnings log

Append-only. Newest entries at the bottom. One entry per distinct failure or measured result. Keep numbers; mark inferences.

Entry template:

```
## L-NNN  <short title>
- Date: YYYY-MM-DD
- System: <product, component, model>
- Symptom: <what was seen>
- Evidence: <numbers from the ledger, logs or code, with where they came from>
- Root cause: <mechanism, file:line if known>
- Fix: <what was or should be changed; one-setting rollback if any>
- Rule: <the generalisation, and which SKILL.md rule it feeds>
- Status: open | fixed <date> | verified <date> | proposed
```

Source for L-001 to L-016: a production agent product (LangGraph supervisor with specialist delegates, Postgres per-call usage ledger), measured on two client installs, "copy A" and "copy B", between 2026-10-26 and 28. Figures come from the ledger; client names and internal paths are omitted.

---

## L-001  Dashboard HTML emitted as tool arguments, truncated at the output ceiling, retried
- Date: 2026-10-26
- System: dashboard specialist, Claude Opus 5.5, LangGraph `create_react_agent`
- Symptom: dashboard builds took 15 to 20 minutes and cost $2 to $5 each; one run spent $3.77 and produced nothing.
- Evidence: 17 calls returned exactly 16,000 output tokens ($7.08, 27% of the day, about 109 s each). Run 27: 7 consecutive capped calls with no tool row between them, cache read growing 33k to 212k. Run 29: 8 capped calls; the delegate itself reported "four attempts... queries: Field required". Real pages 11k to 28k characters plus 3k to 12k of queries JSON; 3 full emissions per dashboard (preview, preview, save). Output was 70% of the specialist's $13.65.
- Root cause: `preview_dashboard(code, queries)` and `save_dashboard_version(..., code, queries, ...)` take the whole HTML as a model-written argument. The configured `max_tokens` 8,192 was floored to 16,000 for thinking (see L-007); thinking shares the cap; thinking plus HTML plus queries did not fit; `queries` came after `code`, so the truncated call failed validation and LangGraph's tool node returned "Please fix your mistakes", and the loop retried from scratch. "At most 3 preview rounds" existed only in prompt text. The install also had its run budget raised to 4.5M tokens and timeout to 1,800 s, so no backstop fired.
- Fix: chart-spec path (model writes a JSON spec, app renders): the same product built a dashboard in 6 calls, 8,434 output tokens, $0.85, 70 s. Preview returns a draft handle; save takes the handle. Abort on `stop_reason == max_tokens`. Cap delegations per run. Sonnet behind an A/B.
- Rule: R3 (no bulk artefacts as tool arguments), R5 (caps in code).
- Status: proposed (backlog 999.2)

## L-002  Conversation cache shipped but not deployed to a client copy for a whole day
- Date: 2026-10-27
- System: copy B, supervisor on Opus 5.5
- Symptom: a day of chat-driven data modelling cost $19.36; supervisor alone $13.09.
- Evidence: 272 supervisor calls sent 2.18M uncached input tokens (about $8.70) against a constant 17,163-token system-only cache read and zero cache writes. The cherry-pick of the cache change was merged and the image rebuilt at 11:59Z the next day; the first run after it showed the healthy signature (2 to 4 uncached tokens per call). On the other copy, cache go-live cut supervisor cost per call from $0.167 to $0.043 (36 calls $6.01 before, 60 calls $2.56 after).
- Root cause: deploy lag between branches; nothing checked the usage fields on the deployed build.
- Fix: a cache probe in the deploy smoke test (second identical request must show `cache_read_input_tokens > 0`); a ledger alert when any loop's uncached share exceeds about 10%.
- Rule: R1 (verify from usage after every deploy), R2.
- Status: fixed 2026-10-28 (deploy); probe and alert proposed

## L-003  Every agent loop outside the main graph ran with no caching at all
- Date: 2026-10-26
- System: the product's playbooks (nightly exploration, daily digest, follow-up reminders), sentinel watch compiler, triage, DB poller, worker repair agents
- Symptom: nightly exploration cost about $1.30 per run on Opus; watch compiles $0.55 for 17 calls.
- Evidence: ledger cache-read share 0% for playbook, watch_compiler and triage agents. Exploration: 44 Opus calls, 886k uncached input tokens, $4.04 over two days. Code: `playbooks.py:176` `create_react_agent(_model(), tools, prompt=PLAYBOOK_SYSTEM)`; `_model()` at `:275` calls `chat_anthropic` without `conversation_cache`; same in `sentinel.py:88`, `triage.py:195`, `db_poller.py:301`, `worker.py:536/672`.
- Root cause: the caching fix was applied in the chat graph's factory (`_mk`) only; other callers had their own model constructors.
- Fix: one factory for all loops; `conversation_cache` and `_cached_prompt` on by default for any multi-step agent; a test that greps for bare `create_react_agent` calls.
- Rule: R2.
- Status: proposed

## L-004  A tool's size cap was not enforced; a 62k-character result tripled run cost
- Date: 2026-10-28
- System: copy B, `get_model` tool (semantic model dump), supervisor on Opus 5.5
- Symptom: runs that read the semantic model cost 3.2× the others.
- Evidence: measured live inside the container: `get_model` returned 62,074 characters against `RESULT_CAP = 20000`. Runs calling it: 14 runs, $0.444 per run; others: 53 runs, $0.138. The call after it wrote 35.8k tokens to cache. Other tools return up to 20,000 characters each (`run_sql`, `search_business_context` about 27k with notes, `use_skill`, `discover_schema`, `read_context_pack`), `get_dashboard` up to 60,000.
- Root cause: `_fit()` only halved a candidate list and dropped descriptions, then returned the document at any size.
- Fix: hard cap with a compact summary and on-demand sections; the stable model summary in the cached system prefix; tool-specific caps (`run_sql` 6k to 8k characters, search hits short).
- Rule: R4.
- Status: proposed

## L-005  Memory-graph extraction on the priciest model after every turn, plus a nightly rebuild nothing reads
- Date: 2026-10-27
- System: memory graph (Graphiti on FalkorDB), OpenAI gpt-5.5 ($5 in / $30 out)
- Symptom: 13 to 16% of daily spend on a background pipeline.
- Evidence: 263 gpt-5.5 calls in one day on copy B ($3.16), about 2,000 input and 60 output tokens each, 6 per chat run (max 18), 0.4% cache hits; $2.64 on the other copy, including 43 calls for dashboard turns because the long dashboard summary reply was ingested as a fact. Nightly `build_communities` at 03:00 rebuilds every community with model summaries; grep found no reader. Settings: `graphiti_llm` auto = OpenAI, main and small model both gpt-5.5; the Anthropic path (Sonnet 5.5) opt-in and untested.
- Root cause: provider default never revisited; no gate on which turns are worth extracting; a library job left on because it was the default.
- Fix: Sonnet 5.5 via the existing path behind an A/B, then Haiku 5.5; skip extraction for dashboard and tool-only turns; batch the day's facts nightly through the Batch API; drop or weekly the community rebuild.
- Rule: R6, R7.
- Status: proposed

## L-006  Token budget counted cache reads at full weight, so it limited step count, not cost; the install raised it 15×
- Date: 2026-10-28
- System: `TokenBudget` callback; copy A's `system_configs`
- Symptom: runs failed on budget after a few steps when contexts were big; the install had `reactive_token_budget` 4,500,000 (default 300,000) and `task_timeout_seconds` 1,800 (default 600), so a $4.87, 19.5-minute dashboard run completed with no backstop.
- Evidence: run 89: four calls, 201,587 tokens counted (reads at full weight). Three user runs failed on 2026-10-27 on copy B.
- Root cause: `_count()` sums `total_tokens`; the budget was tuned by raising it instead of changing what it counts.
- Fix: budget by cost (price table × token kinds) or by uncached-equivalent tokens; restore defaults; separate per-delegation budgets as already done for the Data Agent.
- Rule: R5.
- Status: proposed

## L-007  A thinking floor silently overrode the configured max_tokens
- Date: 2026-10-28
- System: `llmclient.chat_anthropic`, Claude 5 models
- Symptom: the dashboard agent config said `max_tokens` 8,192; every call ran at 16,000; nothing in Setup showed the override.
- Evidence: `llmclient.py:54-55` floors to `THINKING_MAX_TOKENS_FLOOR = 16000`; ledger shows 16,000 as the cap hit.
- Root cause: a correct fix (thinking needs room) applied invisibly; the UI and the config kept showing the old number.
- Fix: show the effective value; make the floor part of the role config; size `max_tokens` as a backstop (tens of thousands with streaming) rather than a knob.
- Rule: R3 (max_tokens as backstop), Build checklist.
- Status: open

## L-008  Dispatch steps: most calls in a loop produce almost nothing and still cost the most
- Date: 2026-10-27
- System: the supervisor, Opus 5.5
- Symptom: 23 model calls per user run on average (p90 37, max 64).
- Evidence: 177 of 282 supervisor calls (63%) returned 200 output tokens or fewer and cost $5.25 of $13.50. Each step added about 2.2k tokens (3.8k on the other copy). One modelling question: 9 calls, 11 tool calls, $1.06. Per-turn memory (6k-character cap, about 3k used) and history (12k characters) were under 5k tokens per turn: not the problem.
- Root cause: one tool call per step, each a full read of the context; SQL run statement by statement.
- Fix: batched SQL in skills; several tool calls per step; step caps per task class; Haiku routing for quick lookups (see L-016); low effort for dispatch-heavy specialists.
- Rule: R5.
- Status: proposed

## L-009  Full skill bodies loaded repeatedly within a day
- Date: 2026-10-27
- System: `use_skill` tool returning the whole SKILL.md (6k to 18.5k characters; one skill 33k cut to 20k)
- Evidence: the supervisor loaded a skill 24 times in one day; the dashboard specialist loaded its 18.5k-character skill on every delegation, twice in one run.
- Root cause: skills are data loaded on demand (good) but bodies were written as manuals, with long example pages and forbidden-construct lists.
- Fix: trim bodies to the method; keep examples in assets fetched only when needed; consider folding the contract into the cached specialist prompt.
- Rule: R4.
- Status: open

## L-010  Retry storm with no attempt cap during an API outage
- Date: 2026-10-27
- System: triage loop on Haiku 5.5, 10-second tick
- Evidence: 428 failed calls (HTTP 400 "You have reached your specified API usage limits") in the ledger; the same batch re-sent every tick; no `attempts` column on events.
- Root cause: failures leave events pending; the loop retries indefinitely.
- Fix: per-item attempt counter, exponential backoff, mark failed after 3; a circuit breaker on provider errors.
- Rule: R7.
- Status: open

## L-011  Reflection after every turn, no trivial-turn gate, and config drift between copies
- Date: 2026-10-27
- System: post-turn reflection (Haiku 5.5 by default), 12,000-character transcript, medium effort
- Evidence: cheap today ($0.02) but it triggers the extraction chain in L-005; one client copy still ran it on gpt-4o-mini (100 calls) after the default moved to Haiku.
- Root cause: no relevance gate; per-install stored config not migrated when the default changed.
- Fix: reflect only when tools ran, the run was hard or the user corrected something; a config-drift check against defaults at startup.
- Rule: R7, Operate checklist.
- Status: open

## L-012  The system prefix is 10k to 17k tokens on every call, half of it tool schemas
- Date: 2026-10-28
- System: supervisor prefix: GROUNDING rules 0.7k chars, skills index 3.7k, supervisor prompt 8.2k (M1) to 13k (M2), routing and rules 4.8k, tool schemas about 18.5k characters for 31 to 36 tools
- Evidence: constant cache read of 10,543 (M1) to 17,163 (M2) tokens on every supervisor call; rewritten at $5 per million after each 5-minute idle gap: about $0.93 of reads and $0.67 of rewrites per day on one copy.
- Root cause: every tool exposed on every turn with long docstrings; rules accreted per phase.
- Fix: trim docstrings; fewer tools per turn (or tool search above about 10k schema tokens); 1-hour TTL on the system block when user turns are 5 to 60 minutes apart.
- Rule: R2, R4. Low priority relative to L-001 to L-005.
- Status: open

## L-013  A grounding re-ask re-runs the whole turn
- Date: 2026-10-28
- System: worker grounding guard: a reply with two or more figures and no data tool call re-runs the supervisor once with a fresh 300k budget
- Evidence: code path confirmed; fire rate not measured (none in one day's log).
- Fix: a small targeted re-ask (user message plus draft reply, `run_sql` only), or mark unverified without a second run.
- Rule: R5.
- Status: open

## L-014  Heavy SQL inside the supervisor loop (before the Data Agent delegation)
- Date: 2026-10-26
- System: supervisor on Opus 5.5 running 25 SQL statements itself in one run
- Evidence: run 14: 19 calls, context 11k to 115k tokens, 1.12M uncached input, $5.30 for one question (also pre-cache, see L-002).
- Fix: quick 012 moved heavy SQL to a Data Agent on Sonnet 5.5 with its own budget; a Q1 question then cost $0.185 vs $0.258.
- Rule: R5 (subagent for bulky self-contained steps), R6.
- Status: fixed 2026-10-25

## L-015  Measured: conversation cache saves 43 to 47% on long loops and about 9% on short ones; server-side context editing cost more than it saved
- Date: 2026-10-26
- System: quick 018 A/B on a synthetic fleet dataset, Opus 5.5 supervisor, Sonnet 5.5 Data Agent
- Evidence: same trajectory priced with system-only caching vs conversation cache: $0.813 to $0.462 (43%), $0.634 to $0.333 (47%), short loop $0.202 to $0.184 (9%). Server-side `clear_tool_uses` with a 20k trigger re-wrote 14,224 tokens at $5 per million to save 0.05× reads on about 10k tokens per later call: left out. Matches the official guidance that context editing is a window tool, not a savings lever.
- Rule: R2, R5.
- Status: verified 2026-10-26

## L-016  Haiku 5.5 A/B: equal on quick lookups, worse on heavy investigations
- Date: 2026-10-26
- System: quick 022, blind review by an independent critic
- Evidence: 6 of 6 quick lookups blind-equal to Opus 5.5 (90% confidence); heavy questions worse (80%). Reflection, the memory model and document extraction moved to Haiku 5.5 at parity; supervisor, Data Agent, research and graph extraction stayed. Routing quick lookups to Haiku (about 25× cheaper) is backlog 999.1.
- Rule: R6 (decide per role by A/B; route by task class, not globally).
- Status: verified 2026-10-26; routing proposed

## L-017  Measured after the fixes: per-call cost down 41% at equal prompt size; the graph extraction pipeline becomes the top lever
- Date: 2026-10-28
- System: copy B (M2 build), supervisor and specialists on Claude Opus 5.5; graph extraction on gpt-5.5.
- Symptom: this checks what the free wins delivered on the deployed build. The fixes were the conversation cache on every loop (R2), tool-result caps (R4), dashboard caps and handles (R3, R5), cost-weighted budgets and triage backoff (R5, R7), and the community rebuild turned off (R7).
- Evidence (ledger, copy B; before = 10-27, 277 supervisor calls; after = 10-28 post-deploy, 38 calls):
  - Supervisor Opus cost per call fell from $0.0474 to $0.0281 (−41%). The average prompt size was the same (25.1k vs 25.4k tokens), and the uncached share fell from 31.7% to 0.0%.
  - The same question, asked before and after: run 89 cost $0.486 and run 108 cost $0.219 (−55%), including the run's graph extraction. Run 108 made 7 calls against 4 and read 4× more data rows. Its cache write fell from 64.6k to 20.6k tokens; most of the difference is `get_model` returning about 11k characters instead of 62k.
  - Nightly exploration: $0.449 for 13 calls with 307 uncached tokens, about $0.035 per call. The uncached copy A runs cost about $0.092 per call ($4.04 over 44 calls). Different data, so this is indicative.
  - Speed: the average supervisor call took 5.8 s before and 5.0 s after. Milliseconds per output token fell from 18.9 to 14.0 (−26%). The median call was slower (3.0 s → 4.9 s) because these calls wrote more output. User-visible time for the same question was about 20 s both times, with 7 calls instead of 4.
  - After the fixes, gpt-5.5 graph extraction was about $0.095 per chat run (72 calls, $0.86 over 9 runs), roughly a quarter of the run's cost.
- Root cause: (positive result) the per-call cost is now set by prompt size and output alone, not by re-sending the conversation.
- Fix: none needed. Next levers by size: the extraction pipeline (Sonnet 5.5 or Flex behind an A/B, batch the backfill), then the output and thinking of dispatch steps (effort per route).
- Rule: R1 (compare per call at equal prompt size, because per-run averages mix different task types: dashboard revision runs made the post-fix run average look flat). Once the main loop is cheap, the background pipeline becomes the top line item (R6, R7).
- Status: verified 2026-10-28 (small after-sample: 9 user runs, 38 supervisor calls).
