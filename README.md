# Ad Report Agent v0.4.0

A local-first macOS MVP that turns weekly advertising exports into an editable eight-slide PowerPoint report.

The deterministic pipeline owns file recognition, validation, calculations, comparisons, formatting, and slide placement. A locally hosted Bonsai 27B model can explain input errors in plain Chinese or English and rank evidence-linked week-over-week anomalies without changing canonical metrics.

## Included in this public snapshot

- Python source for workbook discovery, validation, transformation, history, diagnostics, and weekly insights
- SwiftUI macOS interface source
- Synthetic, de-identified demo inputs and report examples
- Five anonymized scenario test sets
- Local LM Studio integration for `prism-ml/bonsai-27b`

Production brand mappings, source exports, private sample catalogs, PowerPoint template builders, fixed production creative assets, generated history databases, local build outputs, model weights, and machine-specific files are intentionally excluded.

## Requirements

- macOS 13 or later
- Python 3.11 or later
- LM Studio with `prism-ml/bonsai-27b` for optional AI review

## Validate an anonymized input set

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e .

ad-report-mvp \
  --input-folder demo_anonymized/data \
  --profile demo \
  --json-only \
  --no-history-write
```

To enable local model review, start LM Studio's server at `http://127.0.0.1:1234/v1` and add `--ai-review`.

## macOS app source

The SwiftUI wrapper expects the source checkout and a Python runtime. Set these variables when the app is not located in the project's `dist` directory:

```bash
export AD_REPORT_AGENT_ROOT="/path/to/ad-report-agent-public-release"
export AD_REPORT_PYTHON="/path/to/python3"
```

This is an MVP source snapshot, not a notarized standalone installer.

## Privacy

The included data is synthetic and de-identified. AI review is restricted to a loopback LM Studio endpoint; report data is not sent to a hosted model by this project.
