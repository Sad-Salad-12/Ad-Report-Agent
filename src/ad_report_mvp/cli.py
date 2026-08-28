"""Command-line entry point for the weekly report MVP."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Any
import unicodedata

from ad_report_mvp import HistoryStore, commit_report_history, run_data_pipeline
from ad_report_mvp.lm_studio import (
    DEFAULT_ENDPOINT,
    DEFAULT_MODEL_IDENTIFIER,
    LMStudioConfig,
    canonical_numeric_fingerprint,
    review_report,
)
from ad_report_mvp.models import load_report_config
from ad_report_mvp.profiles import (
    PROFILE_SPECS,
    InputFolderResolutionError,
    ProfileSpec,
    matching_input_profiles,
    resolve_input_bundle,
    resolve_input_folder,
    resolve_input_profile,
)
from ad_report_mvp.weekly_insights import generate_weekly_insights


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG = PROJECT_ROOT / "config" / "it_weekly_v1.json"
DEFAULT_OUTPUT_DIR = PROJECT_ROOT / "outputs"
DEFAULT_TEMPLATE = PROJECT_ROOT / "ppt" / "semantic_template_it_weekly_v1.pptx"
DEFAULT_TEMPLATE_BUILDER = PROJECT_ROOT / "ppt" / "build_template.mjs"
DEFAULT_DECK_BUILDER = PROJECT_ROOT / "ppt" / "build_deck.mjs"
DEMO_DECK_BUILDER = PROJECT_ROOT / "tools" / "build_anonymized_deck.mjs"
BUNDLED_NODE = (
    Path.home()
    / ".cache"
    / "codex-runtimes"
    / "codex-primary-runtime"
    / "dependencies"
    / "node"
    / "bin"
    / "node"
)


class AIReviewExecutionError(RuntimeError):
    """CLI-boundary error that retains the failed AI sidecar path."""

    def __init__(self, message: str, sidecar: Path):
        super().__init__(message)
        self.sidecar = sidecar


@dataclass(frozen=True)
class DeckBuilderSpec:
    script: Path
    working_directory: Path
    requires_template: bool


DECK_BUILDERS = {
    "it-weekly-v1": DeckBuilderSpec(
        script=DEFAULT_DECK_BUILDER,
        working_directory=PROJECT_ROOT / "ppt" / "build",
        requires_template=True,
    ),
    "demo-weekly-v1": DeckBuilderSpec(
        script=DEMO_DECK_BUILDER,
        working_directory=PROJECT_ROOT,
        requires_template=False,
    ),
}


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="ad-report-mvp",
        description=(
            "Turn one weekly advertising export bundle into the fixed eight-slide "
            "PowerPoint report."
        ),
    )
    input_group = parser.add_mutually_exclusive_group(required=True)
    input_group.add_argument("--bundle", type=Path, help="Weekly ZIP bundle")
    input_group.add_argument(
        "--input-folder",
        type=Path,
        help="Folder containing the eight exports; searched recursively and safely",
    )
    parser.add_argument(
        "--profile",
        choices=("auto", "production", "demo"),
        default="auto",
        help="Input/report profile; auto detects exactly one profile from ZIP content",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=None,
        help="Versioned market config override (normally selected by --profile)",
    )
    parser.add_argument(
        "--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR, help="Output directory"
    )
    parser.add_argument(
        "--template",
        type=Path,
        default=None,
        help="Production semantic-slot template override",
    )
    parser.add_argument(
        "--rebuild-template",
        action="store_true",
        help="Rebuild the blank template before generating the report",
    )
    parser.add_argument(
        "--no-history-write",
        action="store_true",
        help="Do not add the successful current period to the local history database",
    )
    parser.add_argument(
        "--json-only",
        action="store_true",
        help="Only normalize and validate data; do not build PowerPoint or write history",
    )
    parser.add_argument(
        "--discover-only",
        action="store_true",
        help=(
            "Inspect --input-folder, auto-detect one profile, and emit JSON without "
            "creating report, PowerPoint, or history files"
        ),
    )
    parser.add_argument(
        "--node",
        type=Path,
        default=None,
        help="Node executable override (normally auto-detected)",
    )
    parser.add_argument(
        "--ai-review",
        action="store_true",
        help=(
            "Run the optional read-only semantic review and cross-week insight "
            "explanation through local LM Studio; the model cannot change metrics"
        ),
    )
    parser.add_argument(
        "--ai-optional",
        action="store_true",
        help=(
            "Continue deterministic generation if the requested AI review fails; "
            "writes an error artifact instead"
        ),
    )
    parser.add_argument(
        "--ai-endpoint",
        "--lm-endpoint",
        dest="ai_endpoint",
        default=None,
        help=f"LM Studio API base URL (default: {DEFAULT_ENDPOINT})",
    )
    parser.add_argument(
        "--ai-model",
        "--lm-model",
        dest="ai_model",
        default=None,
        help=f"LM Studio API model identifier (default: {DEFAULT_MODEL_IDENTIFIER})",
    )
    parser.add_argument(
        "--ai-timeout",
        type=float,
        default=None,
        help="Local AI review HTTP timeout in seconds",
    )
    parser.add_argument(
        "--result-json",
        type=Path,
        default=None,
        help=(
            "Also atomically write the final machine-readable result to this file "
            "(recommended for the macOS app)"
        ),
    )
    parser.add_argument(
        "--preview-dir",
        type=Path,
        default=None,
        help=(
            "Render final PowerPoint slide previews into this directory and return "
            "their absolute paths in the result JSON (recommended for the macOS app)"
        ),
    )
    return parser


def _node_executable(override: Path | None) -> str:
    if override:
        return str(override.expanduser().resolve())
    configured = os.environ.get("AD_REPORT_NODE")
    if configured:
        return configured
    if BUNDLED_NODE.exists():
        return str(BUNDLED_NODE)
    system_node = shutil.which("node")
    if system_node:
        return system_node
    raise RuntimeError("Node.js was not found; set AD_REPORT_NODE or pass --node")


def _write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, default=str) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def _run(command: list[str], *, cwd: Path) -> None:
    completed = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if completed.stdout:
        print(completed.stdout.rstrip(), file=sys.stderr)
    if completed.returncode:
        raise RuntimeError(
            f"Command failed with exit code {completed.returncode}: {' '.join(command)}"
        )


def _history_paths(config_path: Path) -> tuple[Path, Path | None]:
    config_path = config_path.expanduser().resolve()
    config = load_report_config(config_path)
    base = (
        config_path.parent.parent
        if config_path.parent.name == "config"
        else config_path.parent
    )

    def resolve(value: str | None) -> Path | None:
        if not value:
            return None
        candidate = Path(value).expanduser()
        return candidate.resolve() if candidate.is_absolute() else (base / candidate).resolve()

    database = resolve(config.history.database)
    if database is None:
        raise ValueError("Config history.database is required")
    return database, resolve(config.history.seed_file)


def _safe_filename_component(value: object, *, label: str) -> str:
    text = unicodedata.normalize("NFKC", str(value or "")).strip().upper()
    text = re.sub(r"[\\/:\x00-\x1f\x7f]+", "_", text)
    text = re.sub(r"\s+", "_", text)
    text = re.sub(r"[^\w-]+", "_", text, flags=re.UNICODE)
    text = re.sub(r"_+", "_", text).strip("_-")
    if not text:
        raise ValueError(f"{label} cannot be converted to a safe filename component")
    return text[:80]


def _period_file_stem(report: Any) -> str:
    market = _safe_filename_component(report.market, label="report market")
    start = str(report.period_start)
    end = str(report.period_end)
    return f"{market}_{start}_{end}_weekly_report"


def _emit_result(payload: dict[str, Any], result_path: Path | None) -> None:
    if result_path is not None:
        destination = result_path.expanduser().resolve()
        payload["result_json"] = str(destination)
        _write_json(destination, payload)
    else:
        payload["result_json"] = None
    print(json.dumps(payload, ensure_ascii=False, indent=2))


def _run_ai_review(
    *,
    report: Any,
    validation: Any,
    output_path: Path,
    endpoint: str | None,
    model: str | None,
    timeout: float | None,
    optional: bool,
) -> tuple[Path, str]:
    if timeout is not None and timeout <= 0:
        raise ValueError("--ai-timeout must be positive")
    config = LMStudioConfig.from_env(
        endpoint=endpoint,
        model_identifier=model,
        request_timeout=timeout,
    )
    fingerprint_before = canonical_numeric_fingerprint(report)
    try:
        review = review_report(report, validation, config)
    except Exception as exc:
        fingerprint_after = canonical_numeric_fingerprint(report)
        numeric_unchanged = fingerprint_before == fingerprint_after
        can_fallback = optional and numeric_unchanged
        failure = {
            "status": "error",
            "ai_participated": False,
            "deterministic_fallback": can_fallback,
            "error": {
                "type": type(exc).__name__,
                "message": str(exc),
            },
            "reviewer": {
                "provider": "lm_studio",
                "endpoint": config.endpoint,
                "model": config.model_identifier,
            },
            "canonical_numeric_integrity": {
                "before": fingerprint_before,
                "after": fingerprint_after,
                "unchanged": numeric_unchanged,
            },
        }
        _write_json(output_path, failure)
        if not can_fallback:
            integrity_note = (
                "Canonical numeric fingerprint changed unexpectedly; fallback is "
                "forbidden"
                if not numeric_unchanged
                else "canonical numeric fingerprint remained unchanged"
            )
            raise AIReviewExecutionError(
                f"AI review failed ({integrity_note}): {exc}. "
                "Start the model from the app or pass --ai-optional to continue. "
                f"Details: {output_path}",
                output_path,
            ) from exc
        return output_path, "optional_failed"
    _write_json(output_path, review)
    return output_path, str(review.get("verdict", "complete")).lower()


def _run_weekly_insights(
    *,
    report: Any,
    previous_report: Any | None,
    output_path: Path,
    endpoint: str | None,
    model: str | None,
    timeout: float | None,
) -> tuple[Path, str]:
    """Write advisory cross-week insights without blocking PPT generation."""

    config = LMStudioConfig.from_env(
        endpoint=endpoint,
        model_identifier=model,
        request_timeout=timeout,
    )
    fingerprint_before = canonical_numeric_fingerprint(report)
    try:
        insights = generate_weekly_insights(report, previous_report, config)
    except Exception as exc:
        fingerprint_after = canonical_numeric_fingerprint(report)
        failure = {
            "schema_version": "1.0.0",
            "status": "failed",
            "reason": "local_ai_error",
            "insights": [],
            "facts": [],
            "error": {"type": type(exc).__name__, "message": str(exc)},
            "reviewer": {
                "provider": "lm_studio",
                "endpoint": config.endpoint,
                "model": config.model_identifier,
            },
            "canonical_numeric_integrity": {
                "before": fingerprint_before,
                "after": fingerprint_after,
                "unchanged": fingerprint_before == fingerprint_after,
            },
        }
        _write_json(output_path, failure)
        print(
            f"WARNING: cross-week insights are unavailable, but report generation "
            f"will continue: {exc}",
            file=sys.stderr,
        )
        return output_path, "failed"
    _write_json(output_path, insights)
    return output_path, str(insights.get("status", "complete"))


def _config_for_profile(args: argparse.Namespace, profile: ProfileSpec) -> Path:
    configured = args.config if args.config is not None else profile.config_path
    config = configured.expanduser().resolve()
    if not config.is_file():
        raise FileNotFoundError(f"Config not found: {config}")
    version = load_report_config(config).template_version
    if version != profile.template_version:
        raise ValueError(
            f"Config template_version {version!r} does not match input profile "
            f"{profile.name!r} ({profile.template_version!r})"
        )
    return config


def _build_powerpoint(
    *,
    args: argparse.Namespace,
    profile: ProfileSpec,
    report: Any,
    report_json: Path,
    output_path: Path,
) -> tuple[Path | None, list[Path]]:
    try:
        builder = DECK_BUILDERS[report.template_version]
    except KeyError as exc:
        supported = ", ".join(sorted(DECK_BUILDERS))
        raise RuntimeError(
            f"No PowerPoint builder is registered for template_version "
            f"{report.template_version!r}; supported versions: {supported}"
        ) from exc
    if not builder.script.is_file():
        raise FileNotFoundError(f"PowerPoint builder not found: {builder.script}")

    node = _node_executable(args.node)
    template: Path | None = None
    command = [node, str(builder.script), "--input", str(report_json)]
    if builder.requires_template:
        configured_template = args.template or profile.template_path or DEFAULT_TEMPLATE
        template = configured_template.expanduser().resolve()
        if args.rebuild_template or not template.exists():
            template.parent.mkdir(parents=True, exist_ok=True)
            _run(
                [node, str(DEFAULT_TEMPLATE_BUILDER), "--output", str(template)],
                cwd=PROJECT_ROOT / "ppt" / "build",
            )
        if not template.is_file():
            raise RuntimeError(f"Template builder did not create: {template}")
        command += ["--template", str(template)]
    else:
        if args.template is not None:
            raise ValueError(
                f"--template is not supported by template_version "
                f"{report.template_version!r}; its generic template is built internally"
            )
        if args.rebuild_template:
            raise ValueError(
                f"--rebuild-template is not supported by template_version "
                f"{report.template_version!r}"
            )

    command += ["--output", str(output_path)]
    preview_paths: list[Path] = []
    if report.template_version == "demo-weekly-v1":
        if args.preview_dir is None:
            command.append("--no-previews")
    _run(command, cwd=builder.working_directory)
    if args.preview_dir is not None:
        destination = args.preview_dir.expanduser().resolve()
        destination.mkdir(parents=True, exist_ok=True)
        if report.template_version == "demo-weekly-v1":
            rendered = output_path.parent / f"{output_path.stem}.reimport-preview"
        else:
            rendered = PROJECT_ROOT / "tmp" / "slides" / "it-weekly-final" / "reimport-preview"
        try:
            sources = [rendered / f"slide-{index:02d}.png" for index in range(1, 9)]
            if not all(source.is_file() for source in sources):
                raise RuntimeError(f"PowerPoint preview renderer did not create 8 slides in: {rendered}")
            for index, source in enumerate(sources, start=1):
                target = destination / f"slide-{index:02d}.png"
                shutil.copy2(source, target)
                preview_paths.append(target)
        except Exception as exc:
            preview_paths = []
            print(f"WARNING: PowerPoint was created but previews are unavailable: {exc}", file=sys.stderr)
        finally:
            if report.template_version == "demo-weekly-v1":
                shutil.rmtree(output_path.parent / f"{output_path.stem}.preview", ignore_errors=True)
                shutil.rmtree(output_path.parent / f"{output_path.stem}.reimport-preview", ignore_errors=True)
    return template, preview_paths


def _main(
    argv: list[str] | None = None,
    *,
    execution_context: dict[str, Any] | None = None,
) -> int:
    args = _parser().parse_args(argv)
    context = execution_context if execution_context is not None else {}
    context.update(
        {
            "input_profile": None if args.profile == "auto" else args.profile,
            "config": (
                str(args.config.expanduser().resolve())
                if args.config is not None
                else None
            ),
            "nested_bundle": False,
            "nested_bundle_name": None,
            "input_mode": "folder" if args.input_folder is not None else "bundle",
            "input_kind": (
                "source_folder" if args.input_folder is not None else "zip_bundle"
            ),
            "input_folder": (
                str(args.input_folder.expanduser().resolve())
                if args.input_folder is not None
                else None
            ),
            "discovery": None,
        }
    )
    if args.ai_optional and not args.ai_review:
        raise ValueError("--ai-optional requires --ai-review")
    if args.discover_only and args.input_folder is None:
        raise ValueError("--discover-only requires --input-folder")
    input_path = (
        args.input_folder.expanduser().resolve()
        if args.input_folder is not None
        else args.bundle.expanduser().resolve()
    )
    output_dir = args.output_dir.expanduser().resolve()

    if args.input_folder is not None:
        input_resolver = resolve_input_folder(input_path)
    else:
        if not input_path.is_file():
            raise FileNotFoundError(f"Bundle not found: {input_path}")
        input_resolver = resolve_input_bundle(input_path)

    try:
        resolved_context = input_resolver
        with resolved_context as resolved_bundle:
            if resolved_bundle.discovery is not None:
                context["discovery"] = dict(resolved_bundle.discovery)
            context["nested_bundle"] = resolved_bundle.nested_bundle is not None
            context["nested_bundle_name"] = resolved_bundle.nested_bundle

            profile_matches = matching_input_profiles(
                resolved_bundle.ingested,
                profiles=PROFILE_SPECS,
            )
            if context["discovery"] is not None:
                context["discovery"]["matched_profiles"] = [
                    profile.name for profile in profile_matches
                ]
            try:
                profile = resolve_input_profile(
                    args.profile,
                    resolved_bundle.ingested,
                    profiles=PROFILE_SPECS,
                )
            except Exception as exc:
                if context["discovery"] is not None:
                    context["discovery"]["errors"] = [str(exc)]
                raise
            context["input_profile"] = profile.name
            if context["discovery"] is not None:
                context["discovery"].update(
                    {
                        "selected_profile": profile.name,
                        "profile": profile.name,
                        "ready": True,
                    }
                )
            config = _config_for_profile(args, profile)
            context["config"] = str(config)

            if args.discover_only:
                _emit_result(
                    {
                        "status": "discovered",
                        "ready": True,
                        "input_mode": context["input_mode"],
                        "input_kind": context["input_kind"],
                        "input_folder": context["input_folder"],
                        "input_profile": context["input_profile"],
                        "config": context["config"],
                        "discovery": context["discovery"],
                        "history_written": False,
                    },
                    args.result_json,
                )
                return 0

            output_dir.mkdir(parents=True, exist_ok=True)
            history_db, seed_file = _history_paths(config)
            result = run_data_pipeline(
                resolved_bundle.path,
                config,
                history_db_path=history_db,
                seed_path=seed_file,
                ingested_bundle=resolved_bundle.ingested,
            )
            result.validation.raise_for_errors()

            stem = _period_file_stem(result.report)
            report_json = output_dir / f"{stem}.json"
            validation_json = output_dir / f"{stem}.validation.json"
            _write_json(report_json, result.report.model_dump(mode="json"))
            _write_json(validation_json, result.validation.model_dump(mode="json"))

            ai_review_json: Path | None = None
            ai_review_status = "disabled"
            weekly_insights_json: Path | None = None
            weekly_insights_status = "disabled"
            if args.ai_review:
                ai_review_json, ai_review_status = _run_ai_review(
                    report=result.report,
                    validation=result.validation,
                    output_path=output_dir / f"{stem}.ai-review.json",
                    endpoint=args.ai_endpoint,
                    model=args.ai_model,
                    timeout=args.ai_timeout,
                    optional=args.ai_optional,
                )
                previous_report = HistoryStore(
                    history_db, seed_file
                ).get_previous_report(result.report.market, result.report.period_start)
                weekly_insights_json, weekly_insights_status = _run_weekly_insights(
                    report=result.report,
                    previous_report=previous_report,
                    output_path=output_dir / f"{stem}.weekly-insights.json",
                    endpoint=args.ai_endpoint,
                    model=args.ai_model,
                    timeout=args.ai_timeout,
                )

            common_result = {
                "ready": True,
                "input_mode": context["input_mode"],
                "input_kind": context["input_kind"],
                "input_folder": context["input_folder"],
                "discovery": context["discovery"],
                "input_profile": context["input_profile"],
                "config": context["config"],
                "nested_bundle": context["nested_bundle"],
                "nested_bundle_name": context["nested_bundle_name"],
                "report_json": str(report_json),
                "validation_json": str(validation_json),
                "ai_review_json": str(ai_review_json) if ai_review_json else None,
                "ai_review_status": ai_review_status,
                "weekly_insights_json": (
                    str(weekly_insights_json) if weekly_insights_json else None
                ),
                "weekly_insights_status": weekly_insights_status,
            }
            if args.json_only:
                _emit_result(
                    {
                        "status": "validated",
                        **common_result,
                    },
                    args.result_json,
                )
                return 0

            deck = output_dir / f"{stem}.pptx"
            template, preview_paths = _build_powerpoint(
                args=args,
                profile=profile,
                report=result.report,
                report_json=report_json,
                output_path=deck,
            )
            if not deck.is_file() or deck.stat().st_size == 0:
                raise RuntimeError(
                    f"PowerPoint builder did not create a valid file: {deck}"
                )

            if not args.no_history_write:
                history_db.parent.mkdir(parents=True, exist_ok=True)
                commit_report_history(result.report, history_db)

            _emit_result(
                {
                    "status": "success",
                    "powerpoint": str(deck),
                    "preview_images": [str(path) for path in preview_paths],
                    "preview_count": len(preview_paths),
                    "template": str(template) if template else None,
                    **common_result,
                    "history_written": not args.no_history_write,
                },
                args.result_json,
            )
            return 0
    except InputFolderResolutionError as exc:
        context["discovery"] = exc.discovery
        raise


def main(argv: list[str] | None = None) -> int:
    """Run the CLI with a concise, non-zero process boundary on failure."""

    execution_context: dict[str, Any] = {
        "input_profile": None,
        "config": None,
        "nested_bundle": False,
        "nested_bundle_name": None,
        "input_mode": None,
        "input_kind": None,
        "input_folder": None,
        "discovery": None,
    }
    try:
        return _main(argv, execution_context=execution_context)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        tokens = list(argv) if argv is not None else sys.argv[1:]
        result_path: Path | None = None
        for index, token in enumerate(tokens):
            if token == "--result-json" and index + 1 < len(tokens):
                result_path = Path(tokens[index + 1])
                break
            if token.startswith("--result-json="):
                result_path = Path(token.split("=", 1)[1])
                break
        payload = {
            "status": "error",
            "powerpoint": None,
            "preview_images": [],
            "preview_count": 0,
            "input_profile": execution_context["input_profile"],
            "config": execution_context["config"],
            "input_mode": execution_context["input_mode"],
            "input_kind": execution_context["input_kind"],
            "input_folder": execution_context["input_folder"],
            "discovery": execution_context["discovery"],
            "ready": bool(
                execution_context["discovery"]
                and execution_context["discovery"].get("ready")
            ),
            "nested_bundle": execution_context["nested_bundle"],
            "nested_bundle_name": execution_context["nested_bundle_name"],
            "ai_review_json": (
                str(exc.sidecar) if isinstance(exc, AIReviewExecutionError) else None
            ),
            "ai_review_status": (
                "failed" if isinstance(exc, AIReviewExecutionError) else "not_run"
            ),
            "weekly_insights_json": None,
            "weekly_insights_status": "not_run",
            "history_written": False,
            "error": {"type": type(exc).__name__, "message": str(exc)},
        }
        _emit_result(payload, result_path)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
