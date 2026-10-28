# Measurement

The ledger is the only ground truth. Code review finds what someone wrote; the ledger finds what runs. Everything below assumes Postgres; adapt names.

## 1. The ledger table

One row per model call, written by the model factory (a LangChain callback attached to the model object, or a thin proxy around the SDK client), never by callers. Queue rows in memory and flush in batches so recording never slows a run.

```sql
CREATE TABLE IF NOT EXISTS llm_usage (
  id                 bigserial PRIMARY KEY,
  ts                 timestamptz NOT NULL DEFAULT now(),
  provider           text NOT NULL,          -- anthropic | openai | ...
  model              text NOT NULL,          -- as billed, date suffix stripped for pricing
  agent              text,                   -- role: supervisor, data, dashboard, triage, reflection, memory_graph ...
  feature            text NOT NULL,          -- chat, dashboard, exploration, watch_compile, embeddings, other
  thread_id          text,
  run_id             bigint,                 -- the task run; null for background work
  trace_id           text,
  input_tokens       integer NOT NULL DEFAULT 0,   -- uncached input only
  output_tokens      integer NOT NULL DEFAULT 0,   -- includes thinking
  cache_read_tokens  integer NOT NULL DEFAULT 0,
  cache_write_tokens integer NOT NULL DEFAULT 0,   -- 5m and 1h writes summed; keep the split if you can
  web_searches       integer NOT NULL DEFAULT 0,
  latency_ms         integer,
  cost_usd           numeric(18,9),           -- computed at write time from a price table
  error              text
);
CREATE INDEX IF NOT EXISTS idx_llm_usage_ts  ON llm_usage (ts);
CREATE INDEX IF NOT EXISTS idx_llm_usage_run ON llm_usage (run_id) WHERE run_id IS NOT NULL;
```

Attribution: a context variable set by the run loop (run id, thread) and by each delegation (agent name, feature). A delegate's calls must carry the delegate's name; a run that used a specialist can be re-labelled with that feature after the fact.

Also keep a `tool_calls` table (run id, agent, tool, args digest, result length, latency). Store the full result length even if you store only a digest of the text: the length is what the cost analysis needs.

Prices: a table keyed by normalised model id with input, output, cache read, cache write (5 m) and cache write (1 h), dated. Haiku 5.5 has a long-context tier above 100k prompt tokens. Refresh from the official pricing page; never from memory.

## 2. The five queries that find the causes

Run in this order. Together they take minutes and usually name the top three causes.

### 2.1 Spend by role, model and feature

```sql
SELECT coalesce(agent,'-') agent, model, feature, count(*) calls,
       round(sum(cost_usd)::numeric,2) usd,
       sum(input_tokens) uncached_in, sum(output_tokens) outp,
       sum(cache_read_tokens) cr, sum(cache_write_tokens) cw,
       round(avg(input_tokens+cache_read_tokens+cache_write_tokens)) avg_prompt,
       max(input_tokens+cache_read_tokens+cache_write_tokens) max_prompt,
       round(avg(output_tokens)) avg_out, max(output_tokens) max_out
FROM llm_usage WHERE ts >= now() - interval '7 days'
GROUP BY 1,2,3 ORDER BY usd DESC;
```

Read: which roles carry the money; whether a role's cost is input, output or writes; whether a background role is on a frontier model.

### 2.2 Cache health per role

```sql
SELECT coalesce(agent,'-') agent, model, count(*) calls,
  round(100.0*sum(cache_read_tokens)/nullif(sum(input_tokens+cache_read_tokens+cache_write_tokens),0),1) cache_read_pct,
  round(100.0*sum(input_tokens)/nullif(sum(input_tokens+cache_read_tokens+cache_write_tokens),0),1) uncached_pct,
  round(100.0*sum(cache_write_tokens)/nullif(sum(input_tokens+cache_read_tokens+cache_write_tokens),0),1) write_pct
FROM llm_usage WHERE provider='anthropic' AND ts >= now() - interval '7 days'
GROUP BY 1,2 ORDER BY calls DESC;
```

Read: any multi-step loop with uncached share above about 10% has a cache defect (L-002, L-003). A one-shot role at 100% uncached is normal.

### 2.3 Run shape

```sql
SELECT count(*) runs, round(avg(c),1) avg_calls,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY c) p50,
       percentile_cont(0.9) WITHIN GROUP (ORDER BY c) p90, max(c) max_calls,
       round(avg(usd)::numeric,3) avg_usd, round(max(usd)::numeric,3) max_usd
FROM (SELECT run_id, count(*) c, sum(cost_usd) usd FROM llm_usage
      WHERE run_id IS NOT NULL GROUP BY 1) t;
```

Then the dispatch-step share:

```sql
SELECT agent, count(*) calls,
  sum(CASE WHEN output_tokens<=200 THEN 1 ELSE 0 END) small_calls,
  round(100.0*sum(CASE WHEN output_tokens<=200 THEN cost_usd ELSE 0 END)/nullif(sum(cost_usd),0),1) pct_cost_small
FROM llm_usage WHERE model LIKE 'claude-opus%' GROUP BY 1;
```

Read: average calls per run above about 15, or small calls carrying over a third of cost, means the loop shape is the lever (L-008).

### 2.4 Truncation and ceilings

```sql
SELECT agent, model, output_tokens, count(*) calls, round(sum(cost_usd)::numeric,2) usd, round(avg(latency_ms)/1000) avg_s
FROM llm_usage GROUP BY 1,2,3
HAVING count(*) >= 3 AND output_tokens IN (4096, 8192, 16000, 16384, 32000, 64000)
ORDER BY usd DESC;
```

Read: repeated outputs at exactly a round number are a `max_tokens` ceiling. Each one is a failed attempt that was paid for (L-001). Check `stop_reason` if you store it.

### 2.5 Per-step growth and the top runs

```sql
WITH c AS (
  SELECT run_id, agent, ts, input_tokens+cache_read_tokens+cache_write_tokens p, output_tokens o,
         lag(input_tokens+cache_read_tokens+cache_write_tokens) OVER (PARTITION BY run_id, agent ORDER BY ts) pp
  FROM llm_usage WHERE run_id IS NOT NULL)
SELECT agent, count(*) steps, round(avg(p-pp)) avg_added,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY p-pp) p50_added, max(p-pp) max_added
FROM c WHERE pp IS NOT NULL GROUP BY 1;
```

Then take the three most expensive runs and list their calls and tool calls in time order (see `scripts/ledger_queries.sql`, "run anatomy"). The anatomy shows the mechanism: which tool added 20k tokens, where the retries are, where the context jumped.

## 3. The healthy-loop signature

On a cached agent loop, consecutive calls look like this:

| Call | input_tokens | cache_read | cache_write | Meaning |
|---|---|---|---|---|
| 1 | 2 to 4 | 0 | whole prompt | first write |
| 2 | 2 to 4 | call 1's total | previous output + new tool result | healthy |
| n | 2 to 4 | growing | one step's delta | healthy |

Defects and their signatures:

- `input_tokens` large and `cache_read` constant: the system prefix is cached, the conversation is not (L-002, L-003).
- `cache_write` near the whole conversation on every call: the prefix is rewritten upstream of the breakpoint (dynamic content, re-ordered tools, a history edit), or a model switch.
- `cache_read` 0 on every call of a role: no breakpoint, prompt under the minimum cacheable length, or a different workspace key.
- A single call with a write of tens of thousands of tokens: an oversized tool result just landed (L-004).

## 4. Measuring sizes

- Prompt and tool schemas: import the app's prompt builder in its own environment and print `len()` of each part; serialise each tool with the provider's schema converter and sum. For exact tokens use the provider's count-tokens endpoint with the same model; never `tiktoken` for Claude.
- Tool payloads: call the tools directly inside the running container with representative arguments and print the length of what they return. A cap in a docstring is not evidence.
- System prefix size in production: the constant `cache_read` on the first cached call of a run is the prefix size in tokens.
- Dashboard or document sizes: measure stored artefacts in the database (characters / 4 is a fair first estimate for English; JSON and HTML tokenise worse, about 3 characters per token).

## 5. What to report

Per role: calls, dollars, share, cache ratios, average and max prompt, average and max output. Per run: distribution of calls and cost; the three most expensive run anatomies. Per cause: the mechanism with file:line, the numbers, and the lever with its expected effect and rollback. State what was measured and what was inferred.
