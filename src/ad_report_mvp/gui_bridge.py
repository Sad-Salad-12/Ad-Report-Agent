"""Small JSON-only bridge used by the native macOS application."""

from __future__ import annotations

import argparse
from dataclasses import replace
import json
from pathlib import Path
import sys

from .diagnostic_explainer import explain_diagnostic, load_diagnostic_json
from .lm_studio import (
    DEFAULT_ENDPOINT,
    DEFAULT_MODEL_IDENTIFIER,
    LMStudioConfig,
    get_status,
    start_model,
)
from .profiles import (
    PROFILE_SPECS,
    InputFolderResolutionError,
    matching_input_profiles,
    resolve_input_folder,
    resolve_input_profile,
)


class _JSONArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise ValueError(message)


def _parser() -> argparse.ArgumentParser:
    parser = _JSONArgumentParser(
        prog="ad-report-gui-bridge",
        description="JSON-only local-model control bridge for the macOS app",
        add_help=False,
    )
    parser.add_argument(
        "command",
        choices=("status", "start-model", "inspect-folder", "explain-diagnostic"),
        help=(
            "Read model status, start/load the model, inspect an input folder, "
            "or explain a bounded diagnostic"
        ),
    )
    parser.add_argument("--input-folder", type=Path, default=None)
    parser.add_argument("--diagnostic-json", type=Path, default=None)
    parser.add_argument(
        "--profile", choices=("auto", "production", "demo"), default="auto"
    )
    parser.add_argument(
        "--endpoint",
        default=None,
        help=f"LM Studio OpenAI-compatible base URL (default: {DEFAULT_ENDPOINT})",
    )
    parser.add_argument(
        "--model",
        default=None,
        help=f"API model identifier (default: {DEFAULT_MODEL_IDENTIFIER})",
    )
    parser.add_argument(
        "--model-file",
        default=None,
        help="Local model file or directory path override",
    )
    parser.add_argument("--lms", default=None, help="lms executable path override")
    parser.add_argument(
        "--request-timeout", type=float, default=None, help="HTTP timeout in seconds"
    )
    parser.add_argument(
        "--startup-timeout",
        type=float,
        default=None,
        help="Bounded server/model readiness wait in seconds",
    )
    return parser


def _config(args: argparse.Namespace) -> LMStudioConfig:
    config = LMStudioConfig.from_env(
        endpoint=args.endpoint,
        model_identifier=args.model,
        model_file=args.model_file,
        lms_path=args.lms,
        request_timeout=args.request_timeout,
    )
    if args.startup_timeout is not None:
        if args.startup_timeout <= 0:
            raise ValueError("--startup-timeout must be positive")
        config = replace(config, startup_timeout=args.startup_timeout)
    return config


def _emit(payload: object) -> None:
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))


def main(argv: list[str] | None = None) -> int:
    """Emit exactly one JSON object to stdout for every invocation."""

    try:
        args = _parser().parse_args(argv)
        if args.command == "explain-diagnostic":
            if args.diagnostic_json is None:
                raise ValueError("explain-diagnostic requires --diagnostic-json")
            diagnostic = load_diagnostic_json(args.diagnostic_json.expanduser())
            explanation = explain_diagnostic(diagnostic, _config(args))
            _emit({"status": "explained", "explanation": explanation})
            return 0
        if args.command == "inspect-folder":
            if args.input_folder is None:
                raise ValueError("inspect-folder requires --input-folder")
            root = args.input_folder.expanduser().resolve()
            discovery: dict[str, object] | None = None
            try:
                with resolve_input_folder(root) as resolved:
                    discovery = dict(resolved.discovery or {})
                    matches = matching_input_profiles(
                        resolved.ingested, profiles=PROFILE_SPECS
                    )
                    discovery["matched_profiles"] = [item.name for item in matches]
                    profile = resolve_input_profile(
                        args.profile, resolved.ingested, profiles=PROFILE_SPECS
                    )
                    discovery.update(
                        {
                            "selected_profile": profile.name,
                            "profile": profile.name,
                            "ready": True,
                            "errors": [],
                        }
                    )
                _emit(
                    {
                        "status": "discovered",
                        "ready": True,
                        "input_mode": "folder",
                        "input_kind": "source_folder",
                        "input_folder": str(root),
                        "input_profile": profile.name,
                        "discovery": discovery,
                    }
                )
                return 0
            except InputFolderResolutionError as exc:
                _emit(
                    {
                        "status": "error",
                        "ready": False,
                        "input_mode": "folder",
                        "input_kind": "source_folder",
                        "input_folder": str(root),
                        "input_profile": None,
                        "discovery": exc.discovery,
                        "error": {
                            "type": type(exc).__name__,
                            "message": str(exc),
                        },
                    }
                )
                return 2
            except Exception as exc:
                if discovery is None:
                    discovery = {
                        "root": str(root),
                        "required_count": 8,
                        "selected_count": 0,
                        "selected_files": {},
                        "found": {},
                        "missing": [],
                        "duplicates": {},
                        "ignored": [],
                        "folder_sha256": None,
                    }
                discovery["ready"] = False
                discovery["errors"] = [str(exc)]
                _emit(
                    {
                        "status": "error",
                        "ready": False,
                        "input_mode": "folder",
                        "input_kind": "source_folder",
                        "input_folder": str(root),
                        "input_profile": None,
                        "discovery": discovery,
                        "error": {
                            "type": type(exc).__name__,
                            "message": str(exc),
                        },
                    }
                )
                return 2
        config = _config(args)
        payload = get_status(config) if args.command == "status" else start_model(config)
        _emit(payload)
        return 0
    except (Exception, SystemExit) as exc:  # stable Swift process boundary
        _emit(
            {
                "status": "error",
                "error": {
                    "type": type(exc).__name__,
                    "message": str(exc) or "invalid gui bridge invocation",
                },
            }
        )
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
