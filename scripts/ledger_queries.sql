-- llm-token-economy: ledger queries (Postgres). Adapt table and column names.
-- Assumes llm_usage(ts, provider, model, agent, feature, run_id, input_tokens, output_tokens,
--                   cache_read_tokens, cache_write_tokens, latency_ms, cost_usd, error)
-- and tool_calls(task_run_id, agent, tool, args, result_digest, latency_ms, created_at).
-- Run with:  psql -v days=7 -v rid=<run id> -f ledger_queries.sql

\set days 7
\pset format aligned
\pset border 0

\echo === 0. RANGE ===
SELECT min(ts), max(ts), count(*) calls, round(sum(cost_usd)::numeric,2) usd
FROM llm_usage WHERE ts >= now() - (:days || ' days')::interval;

\echo === 1. SPEND BY ROLE / MODEL / FEATURE ===
SELECT coalesce(agent,'-') agent, model, feature, count(*) calls,
       round(sum(cost_usd)::numeric,2) usd,
       sum(input_tokens) uncached_in, sum(output_tokens) outp,
       sum(cache_read_tokens) cr, sum(cache_write_tokens) cw,
       round(avg(input_tokens+cache_read_tokens+cache_write_tokens)) avg_prompt,
       max(input_tokens+cache_read_tokens+cache_write_tokens) max_prompt,
       round(avg(output_tokens)) avg_out, max(output_tokens) max_out
FROM llm_usage WHERE ts >= now() - (:days || ' days')::interval
GROUP BY 1,2,3 ORDER BY usd DESC LIMIT 40;

\echo === 2. CACHE HEALTH BY ROLE ===
SELECT coalesce(agent,'-') agent, model, count(*) calls,
  round(100.0*sum(cache_read_tokens)/nullif(sum(input_tokens+cache_read_tokens+cache_write_tokens),0),1) cache_read_pct,
  round(100.0*sum(input_tokens)/nullif(sum(input_tokens+cache_read_tokens+cache_write_tokens),0),1) uncached_pct,
  round(100.0*sum(cache_write_tokens)/nullif(sum(input_tokens+cache_read_tokens+cache_write_tokens),0),1) write_pct
FROM llm_usage WHERE ts >= now() - (:days || ' days')::interval
GROUP BY 1,2 ORDER BY calls DESC;

\echo === 3a. RUN SHAPE ===
SELECT count(*) runs, round(avg(c),1) avg_calls,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY c) p50,
       percentile_cont(0.9) WITHIN GROUP (ORDER BY c) p90, max(c) max_calls,
       round(avg(usd)::numeric,3) avg_usd, round(max(usd)::numeric,3) max_usd
FROM (SELECT run_id, count(*) c, sum(cost_usd) usd FROM llm_usage
      WHERE run_id IS NOT NULL AND ts >= now() - (:days || ' days')::interval GROUP BY 1) t;

\echo === 3b. DISPATCH-STEP SHARE (output <= 200 tokens) ===
SELECT coalesce(agent,'-') agent, model, count(*) calls,
  sum(CASE WHEN output_tokens<=200 THEN 1 ELSE 0 END) small_calls,
  round(100.0*sum(CASE WHEN output_tokens<=200 THEN 1 ELSE 0 END)/count(*),1) pct_small,
  round(sum(CASE WHEN output_tokens<=200 THEN cost_usd ELSE 0 END)::numeric,2) usd_small,
  round(sum(cost_usd)::numeric,2) usd_all
FROM llm_usage WHERE provider='anthropic' AND ts >= now() - (:days || ' days')::interval
GROUP BY 1,2 ORDER BY usd_all DESC;

\echo === 4. OUTPUT CEILINGS (repeated outputs at a round max_tokens) ===
SELECT coalesce(agent,'-') agent, model, output_tokens, count(*) calls,
       round(sum(cost_usd)::numeric,2) usd, round(avg(latency_ms)/1000) avg_s
FROM llm_usage WHERE ts >= now() - (:days || ' days')::interval
GROUP BY 1,2,3
HAVING count(*) >= 3 AND output_tokens IN (1024, 2048, 4096, 8192, 16000, 16384, 21000, 32000, 64000)
ORDER BY usd DESC;

\echo === 5a. PER-STEP GROWTH ===
WITH c AS (
  SELECT run_id, agent, ts, input_tokens+cache_read_tokens+cache_write_tokens p, output_tokens o,
         lag(input_tokens+cache_read_tokens+cache_write_tokens) OVER (PARTITION BY run_id, agent ORDER BY ts) pp,
         lag(output_tokens) OVER (PARTITION BY run_id, agent ORDER BY ts) po
  FROM llm_usage WHERE provider='anthropic' AND run_id IS NOT NULL
    AND ts >= now() - (:days || ' days')::interval)
SELECT agent, count(*) steps, round(avg(p-pp)) avg_added,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY p-pp) p50_added, max(p-pp) max_added,
       round(avg(p-pp-po)) avg_added_minus_prev_output
FROM c WHERE pp IS NOT NULL GROUP BY 1 ORDER BY 2 DESC;

\echo === 5b. TOP RUNS ===
SELECT run_id, string_agg(DISTINCT coalesce(agent,'-'), ',') agents,
       string_agg(DISTINCT feature, ',') feat, count(*) calls,
       round(sum(cost_usd)::numeric,3) usd, sum(input_tokens) uncached_in,
       sum(cache_read_tokens) cr, sum(cache_write_tokens) cw, sum(output_tokens) outp,
       max(input_tokens+cache_read_tokens+cache_write_tokens) max_prompt
FROM llm_usage WHERE run_id IS NOT NULL AND ts >= now() - (:days || ' days')::interval
GROUP BY 1 ORDER BY usd DESC LIMIT 15;

\echo === 6. TOOL RESULT SIZES (digest length; keep full length if you store it) ===
SELECT tool, coalesce(agent,'-') agent, count(*) n,
       round(avg(length(result_digest))) avg_chars, max(length(result_digest)) max_chars
FROM tool_calls WHERE created_at >= now() - (:days || ' days')::interval
GROUP BY 1,2 ORDER BY n DESC LIMIT 30;

\echo === 7. ERRORS AND RETRY STORMS ===
SELECT coalesce(agent,'-') agent, model, left(error,90) err, count(*) n,
       min(ts) first_seen, max(ts) last_seen
FROM llm_usage WHERE error IS NOT NULL AND ts >= now() - (:days || ' days')::interval
GROUP BY 1,2,3 ORDER BY n DESC LIMIT 10;

\echo === 8. BACKGROUND (no run id) ===
SELECT feature, coalesce(agent,'-') agent, model, count(*) calls,
       round(sum(cost_usd)::numeric,2) usd,
       count(DISTINCT date_trunc('hour', ts)) active_hours
FROM llm_usage WHERE run_id IS NULL AND ts >= now() - (:days || ' days')::interval
GROUP BY 1,2,3 ORDER BY usd DESC;

-- RUN ANATOMY: set -v rid=<run id> and run these two.
\echo === 9a. CALLS IN RUN :rid ===
SELECT to_char(ts,'HH24:MI:SS') t, coalesce(agent,'-') agent, left(model,18) model,
       input_tokens inp, cache_read_tokens cr, cache_write_tokens cw, output_tokens outp,
       round(cost_usd::numeric,3) usd, latency_ms ms
FROM llm_usage WHERE run_id = :rid AND provider='anthropic' ORDER BY ts;

\echo === 9b. TOOL CALLS IN RUN :rid ===
SELECT to_char(created_at,'HH24:MI:SS') t, coalesce(agent,'-') agent, tool,
       length(result_digest) res_chars,
       left(regexp_replace(coalesce(args::text,''),'\s+',' ','g'),110) args
FROM tool_calls WHERE task_run_id = :rid ORDER BY id;
