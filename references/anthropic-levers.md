# Anthropic levers: the facts this skill relies on

Checked against the `claude-api` skill references (`shared/cost-optimization.md`, `shared/prompt-caching.md`, `shared/agent-design.md`) on 2026-10-28. Prices and per-model behaviour change: re-verify against the live docs (platform.claude.com) before quoting, and prefer the `claude-api` skill's `cost-optimize` subcommand for a full workflow.

## Prices that set the ratios (Claude Opus 5.5, per million tokens)

| Token kind | Price | Relative to a cache read |
|---|---|---|
| Cache read | $0.20 | 1× |
| Uncached input | $4 | 20× |
| Cache write, 5-minute TTL | $5 (1.25× input) | 25× |
| Cache write, 1-hour TTL | $8 (2× input) | 40× |
| Output (thinking included) | $20 | 100× |

Sonnet 5.5: $2 / $10, cache read $0.20. Haiku 5.5: $0.10 / $0.50 up to 100k prompt tokens, $0.50 / $2.50 above. Fable 5.1: $10 / $50, cache read $0.25. Batch API: 50% off every token in the request, cache reads and writes included.

## Prompt caching

- Prefix match on exact bytes. Render order is `tools`, then `system`, then `messages`. A change at position N invalidates everything after N.
- Minimum cacheable prefix: 512 tokens on Opus 5.5, Sonnet 5.5, Haiku 5.5, Fable 5/5.1 (1024 on Opus 4.8, Sonnet 5, Sonnet 4.6; 2048 on Opus 4.7; 4096 on Opus 4.6, Opus 4.5, Haiku 4.5). Shorter prefixes silently do not cache.
- Up to 4 breakpoints per request. Top-level `cache_control` (automatic caching) places one breakpoint on the last cacheable block and moves it forward as the loop grows.
- The robust shape for agent loops: one explicit breakpoint on the last block of the static system prefix, plus top-level automatic caching for the growing tail. For one-shot calls with a unique tail, automatic caching is a pure write surcharge; use an explicit breakpoint at the end of the shared portion or none.
- TTL: a read refreshes the timer. Requests less than 5 minutes apart keep the 5-minute entry warm; 5 to 60 minute gaps are the only window where the 1-hour TTL (2× write) pays; longer gaps need a scheduled re-warm (`max_tokens: 0` request) or accept the miss. Longer-TTL entries must precede shorter ones.
- Invalidation hierarchy: tool definitions or model change rebuild everything; a system prompt change rebuilds system and messages; `thinking` or `effort` changes always invalidate the messages cache; message content changes invalidate only messages. Cache-preserving forms exist for system edits (a `role: "system"` message inside `messages` on Opus 5 / 5.5 / 4.8, Fable 5 / 5.1, Sonnet 5.5), tool changes (beta `tool_addition` / `tool_removal` blocks) and per-message effort (beta). A model switch has no escape hatch: spawn a subagent instead.
- Silent invalidators to grep for: `datetime.now`, `uuid4`, request ids in the prefix; `json.dumps` without `sort_keys`; set iteration; conditional system sections; per-user tool sets.
- 20-block lookback: a turn that appends more than 20 positions can push the previous entry out of reach; parallel tool-call runs collapse to one position.
- Concurrency: parallel requests with the same new prefix all miss; fire one, wait for the first streamed token, then the rest.
- Verify from `usage`, not from code: `cache_read_input_tokens` should dominate on a warmed loop; `cache_creation_input_tokens` about one step's delta. Prompt size = input + cache_creation + cache_read. Re-verify after every prompt-assembly change and every deploy. Cache diagnostics (beta) names where two consecutive requests diverged.

## Thinking, effort and max_tokens on current models

- Claude 5 family: thinking on by default and billed as output; `thinking: {type: "disabled"}` is a 400 on Opus 5.5 (use low effort), Sonnet 5.5 accepts `{type: "between_tools"}` at effort high or below; `budget_tokens` is removed. Effort levels `low` to `max`; default `medium` on Opus 5.5 and Haiku 5.5, `high` on Sonnet 5.5. Set effort explicitly per route and keep it fixed within a conversation.
- Forced `tool_choice` (`any`, `tool`) returns 400 on Opus 5.5, Sonnet 5.5, Fable 5.1; Haiku 5.5 accepts it. Use `auto` plus an instruction, `strict: true`, or structured outputs.
- `max_tokens` is a backstop the model never sees. Hitting it returns `stop_reason: max_tokens` with the output cut mid-thought; treat it as a failed attempt, do not retry at the same cap. For agentic work set it high (the guide's starting point is 64,000 with streaming); for classification a few hundred. Thinking shares it.
- Effort curves measured by Anthropic: research and knowledge work nearly flat (`medium` matched `high`, `low` gave up a few points for a third to a half off); long-horizon coding a real tradeoff. Sweep per workload and per model; re-sweep after a migration. Re-run failures at higher effort when a checker exists.
- Task budgets (beta): the model sees the budget and paces itself; set from the loop's p90 usage. Distinct from `max_tokens`.

## Input hygiene

- Large reference documents behind a tool or skill, unless most calls need most of the document (a document in the cached prefix is cheap).
- Tool recaps in the system prompt: delete; schemas already render.
- Many or heavy tool schemas: tool search with `defer_loading` pays above about 10k schema tokens.
- Narrow accessors over data dumps; list tools with `limit`, `fields`, `date_range`.
- Files API plus code execution for tables and PDFs; programmatic tool calling when intermediates do not matter (reported 24% fewer input tokens on agentic search).
- Images: cost scales with pixel area; downscale to what the task needs.
- Token counting as an ingestion gate for unbounded user input; `count_tokens`, not `tiktoken`.
- Prompts written for an older model make a newer one over-work; audit them on migration.

## Loop hygiene

- Context editing (clearing old tool results) is a context-window tool, not a savings lever: every clear rewrites the cached conversation. Keep triggers high and clears rare and large. Measured in one product: it cost more than it saved (L-015).
- Compaction pays only in sessions long enough to need it (about a third off a long run in the docs' measurement, nothing on a short one).
- Client-side pruning of earlier turns invalidates later thinking blocks on models with preserved thinking; keep `messages` append-only and size tool results before they enter.
- Subagents absorb bulky intermediates and return one line, on a cheaper model if adequate; they start a fresh cache prefix.
- Parallel tool calls: execute concurrently and return all `tool_result` blocks in one user message.

## Output hygiene

- Specify the output shape with an example to shorten visible text; use effort, not `max_tokens`, to shorten reasoning.
- Stop sequences as content-aware early exits.
- Structured outputs (`output_config.format`) when the call only exists to get JSON back.

## Batch

- 50% off, results within 24 hours, single-shot requests (no mid-batch tool loop). The second-largest free lever after caching for nightly work, backfills and evals.

## Model selection

- Last lever. Check for an upgrade at lower effort before a step-down. Price candidates per completed task on your own traffic, including the frontier model at low effort. Price the tail. Step down one tier at a time against an eval, re-sweeping effort from the new model's default. Switch between conversations, never inside one.
- Two-model shapes that measured well: an advisor (cheap executor consults a frontier model on hard decisions; fragile consult rate) and an orchestrator with cheap workers when there is bulk to hand off. A single dependent chain that fits one context is cheaper on one model at lower effort.

## Measurement and process

- Baseline before changing anything; one lever per diff; measure on a warm cache from the second request on; decide on repeated trials, not one-case swings; keep or revert.
- When no eval exists: free wins are measured on cost only and said so; tradeoffs stay proposals until an eval covers them. The minimal eval is 20 to 30 frozen real requests, a cheap judgment per output, and a runner that records `usage`.
