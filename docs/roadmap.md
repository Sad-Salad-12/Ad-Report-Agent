# Post-MVP optimization roadmap

## Phase 1 — Prove repeatability across 10–20 historical weeks

- Keep the 10 collected market-week references integrity-clean, then expand toward 20.
- Add adapters for the nine historical source variants before counting them as replay passes.
- Promote reviewed canonical JSON/deck pairs to approved goldens and replay them on each change.
- Compare canonical JSON and rendered slide images against reviewed goldens.
- Classify differences as source drift, mapping drift, business-rule changes, or visual regressions.
- Promote aliases/rules only after repeated evidence or explicit owner confirmation.

Success measure: at least 90% of reviewed weeks generate without manual data edits, and every remaining stop has a specific actionable error.

## Phase 2 — Controlled schema adaptation

- Add a local LM Studio adapter only for unknown headers and ambiguous product labels.
- Give the model the known schema, candidate columns, and a few reviewed mappings.
- Require structured output containing candidate mapping, confidence, and rationale.
- Never allow model output to change calculations or enter production automatically; a reviewer accepts a mapping before it becomes config.

Success measure: new export variants can be onboarded by reviewing a suggested mapping rather than changing code.

## Phase 3 — Template families

- Version semantic manifests independently from data schemas.
- Add FR and UK configs, currencies, labels, and product sets.
- Build a template compatibility checker and slide-level regression previews.
- Support optional page types without weakening required-slot checks.

Success measure: one canonical dataset can render into multiple approved designs without changing transformation code.

## Phase 4 — Operations and integrations

- Pull exports from Meta/Google or a controlled shared folder.
- Add approved creative-asset lookup only when weekly image updates become valuable.
- Add a lightweight job page showing input status, validation errors, output link, and history.
- Record generation duration, failure reason, manual edits, and approval status.

Success measure: scheduled weekly generation with clear exception ownership and an auditable approval trail.

## Model strategy

The local 4B multimodal model is sufficient for constrained label matching and explaining validation errors. A stronger hosted model is useful only when the scope expands to unseen spreadsheet layouts, free-form narrative generation, or difficult visual interpretation. Keep a deterministic fallback and a human review gate even then.
