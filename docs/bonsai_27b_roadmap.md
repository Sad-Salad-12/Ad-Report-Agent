# Bonsai 27B roadmap

The Mac app uses LM Studio at `http://127.0.0.1:1234/v1`, loads the indexed
model key `prism-ml/bonsai-27b`, and uses that same identifier through the API.
The deterministic pipeline remains the source of truth for every metric.

## Current role

Bonsai receives a semantic-only projection of the validated report: period and
source metadata, entity names, validation issues, and representative lineage
mappings. It does not receive raw metric values for arithmetic. Its structured
review is schema-validated, and the canonical numeric fingerprint must be
identical before and after the call.

## Highest-value next capabilities

1. **Explain input problems in plain language.** Convert missing-table,
   duplicate-source, period-conflict, and alias errors into a short diagnosis and
   concrete repair steps. Raw diagnostics remain available only in the details
   sheet.
2. **Propose schema adapters.** When a new export is close to a known schema,
   suggest column aliases, units, product mappings, and creative-selection rules.
   The app shows a diff for approval; deterministic replay must pass before a
   mapping can be saved.
3. **Evidence-linked weekly narrative.** Generate a small set of finding codes
   and source fact IDs for the report summary. Deterministic code inserts the
   verified values and renders the final sentence, preventing invented numbers.
4. **Cross-week anomaly triage.** Rank changes that deserve attention using
   precomputed deterministic deltas, seasonality flags, and historical baselines.
   The model explains likely interpretations but cannot alter calculations.
5. **Local creative analysis.** Use the model's vision capability to tag approved
   creative images by format, product emphasis, message angle, and visible CTA.
   Keep OCR and entity redaction local, and link every conclusion to the source
   asset ID.

## Later capabilities

- Conversational questions over report history, implemented as a constrained
  query plan executed by deterministic tools rather than free-form model math.
- Assisted onboarding of a new market or report template by proposing page roles,
  filters, and semantic slot mappings for human approval.
- Drafting localized executive summaries in Chinese and English from verified
  finding codes.

## Safety boundary

The model may propose, classify, explain, and rank. It may not become the source
of truth for spreadsheet parsing, currency and percentage conversion, filtering,
aggregation, historical writes, or PowerPoint coordinates. Every proposal must
carry evidence IDs and pass deterministic validation before it can affect an
output.

On the current 16GB Mac, LM Studio loaded the 8.52GB MLX model with one parallel
request. The runtime reported a 4,864-token active context even though the model
supports a much larger theoretical context, so prompts should remain compact and
retrieval should be selective.
