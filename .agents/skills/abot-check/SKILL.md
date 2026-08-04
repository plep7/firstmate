---
name: abot-check
description: >-
  Generate the full daily abot picture in one command: performance, data integrity, bugs, and health.
  Use when the captain invokes /abot-check or asks for an abot status check, health check, or performance check.
  Replaces the ad-hoc daily "how is abot doing" request with one deterministic report.
user-invocable: true
metadata:
  internal: true
---

# abot-check

Generate a complete current picture of the abot paper-trading stack: version and container health, P&L, a same-day trade placement audit, analysis cadence, ops alerts, and database hygiene.
This skill is fully read-only.
It never restarts a container, prunes data, clears a kill switch, or otherwise mutates the target host.
A finding that warrants action is named for the captain's own decision, never acted on here.

## What it does

1. **Gather with one deterministic script.**
   Run `.agents/skills/abot-check/fm-abot-check-snapshot.sh` and read its output.
   It is the single bounded data source for this skill.
   Do not invent a second query, probe the API or database ad hoc, or read a stale report file instead.
   The script's own header and `--help` own its exact fields, env overrides, and output contract (`fm-abot-check.v1`).
   It reaches the target over two independent channels - plain HTTP to the dashboard API, and SSH to the docker host for container health and read-only `psql` - and degrades each independently: an unreachable endpoint or command is recorded under `[sources] unreachable:` and its section's fields read `n/a`, never a crash or a silent gap.
2. **Compose the chat digest from the fresh output.**
   The gather step already computed every count and every section's `needs_attention` verdict; your job is only to translate those labeled facts into captain-facing prose, per `AGENTS.md` section 9 - plain outcomes, no internal jargon, no raw field dumps.
   Every number keeps the scope label the script gave it (`realized_today` vs `realized_all_time`, `orphan_stuck_30d` vs today's trade audit, etc.) so a captain reading the chat can never mistake one window for another.

## Chat-digest contract

Render exactly six sections, in this order, every time - never omit one for being clean, and never add a seventh:

1. **P&L** - `realized_today`, `realized_all_time`, `unrealized`, `total`, `day_change`, each labeled with its exact scope.
2. **Trades** - today's trade-placement audit: how many TRADE/EXIT decisions were checked, how many silent drops were found (a decision with no order ever placed, or an order stuck with no terminal broker outcome), and each drop's ticker and reason.
3. **Analysis** - today's decision count vs. the multi-day baseline, the errored-PASS count, and the stuck-pending count.
4. **Alerts/Bugs** - alert-severity ops events in the lookback window (named, not just counted), recoveries noted separately, plus the event-stream and diagnoses head counts for context.
5. **Data integrity** - the DB hygiene counts: genuinely orphaned trade-lineage rows and inconsistent records (dangling tax lots, intents stuck with no terminal event).
   A decision that was intentionally skipped or shadow-only is not an integrity problem; only report what the script itself flagged.
6. **Verdict** - one closing line: which sections need attention (from `[verdict] sections_needing_attention`) or that everything is clean, plus a one-line note of any unreachable source from `[sources] unreachable`.

Every section ends with an explicit needs-attention line, taken directly from that section's `needs_attention` value in the script output - state it plainly ("needs your attention: ..." or "nothing to flag here") rather than leaving the captain to infer it from the numbers.
When a source was unreachable, say so plainly in that section ("couldn't reach abot's database for this" rather than silently omitting the fields) instead of pretending the section is simply empty or clean.

## Tone and content rules

- Follow `AGENTS.md` section 9: talk in outcomes, address the captain, translate every internal term (no "ssh", "psql", "docker", "endpoint", or field-name jargon in the chat prose - the numbers themselves keep their scope labels, but the surrounding language stays plain).
- Every PR, if one is ever relevant here, is a full `https://...` URL - not expected in ordinary use since this skill never opens one.
- Never restart, prune, redeploy, or otherwise change anything on the target host from inside this skill; a finding that looks like it needs a fix is named for the captain, not acted on.
- This skill does not write any file; the chat digest is the only output.
