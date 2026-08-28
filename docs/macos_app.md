# Ad Report Agent for Mac

## Use it

1. Open `dist/Ad Report Agent.app`.
2. Drag in the folder containing this week's exports, or click the folder area to choose it. The app immediately discovers and checks the eight required source types.
3. Choose an output folder.
4. Keep **AI review** on and click **Start local model**. The app starts LM Studio
   on `127.0.0.1:1234` and loads the existing Bonsai 27B MLX model.
5. Click **Generate PPT**. When all four stages finish, use **Open PPT** or
   **Show in Finder**.

The first 27B-model load may take a few minutes. A full local review and
PowerPoint run can also take several minutes on this Mac.

## What Bonsai 27B does

Bonsai 27B is an advisory semantic-review layer. It reviews normalized source-period,
field-mapping, and validation context and writes a separate `*.ai-review.json`
artifact. The app displays its verdict and summary. In 0.4 it also has two bounded,
advisory jobs:

- when input discovery or generation fails, it turns a small structured diagnostic
  into bilingual plain-language guidance and recovery steps;
- when a prior completed week is available, it selects up to three cross-week
  findings backed by immutable fact IDs.

The diagnostic request contains only a category, missing input kinds, duplicate
input kinds, error type, and concise message. It never includes a source path,
candidate filename, model URL, or the full process log. The friendly fallback is
shown immediately; local AI explanation runs asynchronously and never blocks the
interface. Original backend text is available only inside the collapsed technical
details area. The app always keeps the program-confirmed affected input types visible,
even if the model's rewritten explanation is less specific.

Bonsai 27B is not allowed to replace, invent, or recalculate report numbers. The full
canonical report is fingerprinted before and after review; a mismatch or invalid
model response is rejected. Source recognition, calculations, validation,
historical comparison, PowerPoint slots, and chart values remain deterministic.

You can switch AI review off to run the deterministic report pipeline without
LM Studio.

## Outputs

Each successful run writes:

- the editable eight-slide `.pptx`;
- canonical report JSON with lineage;
- deterministic validation JSON;
- local Bonsai 27B review JSON when AI review is enabled;
- local weekly-insights JSON when AI review is enabled and two comparable weeks
  are available.

The generated workspace keeps the existing left-sidebar and PowerPoint-preview
layout. A restrained **This week / 本周关注** list appears in the left sidebar only
when grounded insights are available. Selecting one opens a separate detail sheet;
it does not change the selected PowerPoint slide. With only one completed week the
sidebar shows a single availability note. Insight generation failure never changes
PowerPoint success.

The Mac app reads a dedicated result JSON file, so spaces and Chinese characters
in input/output paths are supported without parsing mixed process logs.

## Privacy

The model endpoint is restricted to loopback HTTP (`127.0.0.1` or `localhost`).
The app never enables CORS or binds LM Studio to the LAN. Report context is sent
only to the local LM Studio process and is not uploaded by this app. LM Studio may
retain prompts in its own local server logs.

## Troubleshooting

- **Model not ready:** open LM Studio manually, then use the refresh button. The
  indexed model key must be `prism-ml/bonsai-27b`, loaded with
  API identifier `prism-ml/bonsai-27b`.
- **AI review rejected:** the deterministic data remains unchanged. Retry the
  model, or switch AI review off for a deterministic-only run.
- **Missing or duplicate table, or mismatched dates:** correct the selected folder and click **Scan Again**. Validation intentionally
  stops before PowerPoint/history output. The first dialog gives deterministic
  recovery steps and may be refined by the ready local model.
- **Weekly insights unavailable:** complete two comparable weekly runs. A failed or
  unavailable insight sidecar does not affect the generated PPT.
- **App moved to another Mac:** this 0.4 internal build is ad-hoc signed and uses
  local project/runtime paths. A distributable build still needs bundled runtimes,
  Developer ID signing, notarization, and Apple Silicon compatibility testing.
