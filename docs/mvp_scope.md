# Working MVP scope

## Goal

Generate the simplified eight-slide weekly advertising report directly from a folder of exports, with deterministic data processing and a fixed PowerPoint design.

## Runtime inputs

1. One selected folder containing exactly one complete set of the eight known weekly report exports; ZIP remains a compatibility input.
2. `config/it_weekly_v1.json`.
3. The versioned PowerPoint slot manifest and fixed visual assets.
4. The prior-period history database. The first seed comes from the explicit 7.14-7.20 comparison row in the provided deck.

Creative screenshots are fixed assets in MVP 0.3. Their metrics are refreshed each run, but the images are not fetched or replaced.

## Required output

- An eight-slide `.pptx` with editable text, tables, and native charts.
- A normalized report JSON with source lineage.
- A validation JSON that fails closed on missing required data.
- A history entry for the current period after a successful run.

## Non-goals for 0.3

- Arbitrary workbooks or arbitrary slide templates.
- Meta/Google API downloads.
- Weekly creative image replacement.
- A self-contained, notarized installer for other Macs.
- Free-form model-generated calculations.

## Acceptance gates

- All displayed numbers trace to a source field or a named deterministic formula.
- Output period, filename, and history period agree.
- All required products and pinned creative metric rows exist.
- The generated deck opens without repair and all eight slides render.
- No unresolved semantic slot token remains in the final deck.
