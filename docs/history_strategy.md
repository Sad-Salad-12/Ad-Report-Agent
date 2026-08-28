# Previous-period data strategy

The comparison row is treated as state, not as a value for an AI model to infer.

## Source priority

1. Find the most recent successfully generated report for the same market whose start date is before the current period.
2. On a brand-new installation, load a reviewed seed record.
3. If neither exists and comparison is required, stop with a clear validation error.

The MVP seed is the explicit 2025-07-14 to 2025-07-20 row already visible in the supplied reviewed deck.

## Write rule

The current period is committed to SQLite only after:

- every required source is recognized;
- fail-closed data validation passes;
- the PowerPoint is successfully created.

Re-running the same period is idempotent: the market and period identify a unique record, so a successful corrected rerun replaces the previous entry for that period.

## Why no model guess is allowed

Previous-period metrics are exact audit data. A language model cannot reconstruct missing spend, revenue, or conversion counts reliably. Missing history must therefore be repaired by importing an approved historical report/export or by supplying an explicitly reviewed seed.

