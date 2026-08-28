# Synthetic demo data package

This package contains no production brand, product, campaign, audience, creative, keyword, market, date, metric, author, URL, object ID, source hash, or original file-name metadata. All business values are synthetic and reproducible with fixed seed 20250106.

## Generic entity map

| Source category | Shareable label |
|---|---|
| Brand | BRAND A |
| Market | MARKET A |
| Country / region | REGION A |
| Products | PRODUCT ALPHA, PRODUCT BETA, PRODUCT GAMMA |
| Campaigns | CAMPAIGN-001 through CAMPAIGN-006 |
| Audiences | AUDIENCE-001 through AUDIENCE-003 |
| Creatives | CREATIVE-001 through CREATIVE-024 |
| Keywords | KEYWORD-00001 through KEYWORD-01000 |

The original-to-generic lookup is intentionally not included because that lookup would itself be sensitive.

## Synthetic reporting periods

- Current: 2025-01-06 through 2025-01-12
- Previous: 2024-12-30 through 2025-01-05

## Data consistency

- Current overall: spend 3020, purchase value 6308, purchases 39, adds to cart 192.
- Product, daily, campaign, traffic, audience, SOP, and keyword tables use the same synthetic canonical values.
- Derived metrics (ROAS, CPA, cost per add to cart, CTR, CPM, CPC, average order value, and rates) are recalculated from synthetic base metrics.
- The SOP workbook replaces all original embedded chart images with fresh native charts built from anonymized values.
- Synthetic sample sizes (24 creatives and 1,000 keywords) deliberately differ from the source and are not source-volume metadata.
