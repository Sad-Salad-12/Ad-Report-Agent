"""Historical sample inventory, integrity checks, discovery, and replay support."""

from __future__ import annotations

from collections import Counter, defaultdict
from datetime import date, datetime, timezone
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from typing import Any, Mapping, Sequence
import zipfile
from xml.etree import ElementTree as ET

from .history import commit_report_history
from .ingest import ingest_bundle
from .models import CanonicalReport
from .transform import run_data_pipeline


CATALOG_SCHEMA_VERSION = "2.0.0"
MINIMUM_HISTORICAL_SAMPLE_COUNT = 10
DEFAULT_TARGET_SAMPLE_COUNT = 20
REVIEW_STATUSES = {
    "candidate",
    "historical_reference",
    "known_bad_reference",
    "approved",
    "expected_fail",
}
WORKFLOW_STATUSES = {"runnable", "needs_adapter", "reference_only"}
APPROVED_PREVIOUS_SOURCE_KINDS = {"catalog_sample", "seed_file"}
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")


class SampleCatalogError(ValueError):
    """Raised when the sample inventory cannot be trusted or replayed safely."""


def _is_sha256(value: Any) -> bool:
    return isinstance(value, str) and SHA256_PATTERN.fullmatch(value) is not None


def _parse_approved_at(value: Any) -> datetime:
    if not isinstance(value, str) or not value.strip():
        raise SampleCatalogError("approved_at must be a non-empty ISO-8601 timestamp")
    normalized = value.strip().replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as exc:
        raise SampleCatalogError(f"approved_at is not ISO-8601: {value!r}") from exc
    if parsed.tzinfo is None:
        raise SampleCatalogError("approved_at must include a timezone")
    return parsed


def sha256_file(path: str | Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _date_text(value: Any, field: str) -> str:
    try:
        return date.fromisoformat(str(value)).isoformat()
    except (TypeError, ValueError) as exc:
        raise SampleCatalogError(f"{field} must be an ISO date, got {value!r}") from exc


def _safe_catalog(catalog: Mapping[str, Any]) -> dict[str, Any]:
    payload = dict(catalog)
    samples = payload.get("samples", [])
    if not isinstance(samples, list):
        raise SampleCatalogError("catalog.samples must be an array")
    # Loading a v1 catalog is a migration boundary.  Everything returned from
    # this module follows the current contract, even before it is written back.
    payload["schema_version"] = CATALOG_SCHEMA_VERSION
    payload.pop("registered_sample_count", None)
    payload.pop("remaining_to_target", None)
    payload.setdefault("minimum_historical_sample_count", MINIMUM_HISTORICAL_SAMPLE_COUNT)
    payload.setdefault("target_sample_count", DEFAULT_TARGET_SAMPLE_COUNT)
    minimum = int(payload["minimum_historical_sample_count"])
    target = int(payload["target_sample_count"])
    if minimum < 1 or target < minimum:
        raise SampleCatalogError("catalog sample targets are invalid")
    seen_ids: set[str] = set()
    seen_market_periods: set[tuple[str, str, str]] = set()
    normalized: list[dict[str, Any]] = []
    for raw in samples:
        if not isinstance(raw, dict):
            raise SampleCatalogError("each catalog sample must be an object")
        item = dict(raw)
        sample_id = str(item.get("sample_id", "")).strip()
        if not sample_id:
            raise SampleCatalogError("every sample requires sample_id")
        if sample_id in seen_ids:
            raise SampleCatalogError(f"duplicate sample_id: {sample_id}")
        seen_ids.add(sample_id)
        item["sample_id"] = sample_id
        item["market"] = str(item.get("market", "")).upper().strip()
        if not item["market"]:
            raise SampleCatalogError(f"{sample_id}: market is required")
        legacy_bundle = item.get("bundle") if isinstance(item.get("bundle"), dict) else {}
        item["period_start"] = _date_text(
            item.get("period_start") or legacy_bundle.get("period_start"),
            f"{sample_id}.period_start",
        )
        item["period_end"] = _date_text(
            item.get("period_end") or legacy_bundle.get("period_end"),
            f"{sample_id}.period_end",
        )
        if item["period_end"] < item["period_start"]:
            raise SampleCatalogError(f"{sample_id}: period is inverted")
        market_period = (item["market"], item["period_start"], item["period_end"])
        if market_period in seen_market_periods:
            raise SampleCatalogError(
                f"duplicate market-period: {item['market']} "
                f"{item['period_start']}..{item['period_end']}"
            )
        seen_market_periods.add(market_period)
        if "source" not in item and "bundle" in item:
            bundle = item["bundle"]
            item["source"] = {
                "kind": "zip_bundle",
                "path": bundle.get("path"),
                "sha256": bundle.get("sha256"),
                "files": bundle.get("files", []),
                "ingestion_profile": "it_weekly_v1",
            }
        if "deck" not in item and item.get("reviewed_deck"):
            deck = item["reviewed_deck"]
            item["deck"] = {"kind": "file", **deck}
        item.setdefault(
            "review_status",
            "historical_reference" if item.get("deck") else "candidate",
        )
        item.setdefault("workflow_status", "reference_only")
        if item["review_status"] not in REVIEW_STATUSES:
            raise SampleCatalogError(
                f"{sample_id}: unsupported review_status {item['review_status']!r}"
            )
        if item["workflow_status"] not in WORKFLOW_STATUSES:
            raise SampleCatalogError(
                f"{sample_id}: unsupported workflow_status {item['workflow_status']!r}"
            )
        if not isinstance(item.get("source"), dict):
            raise SampleCatalogError(f"{sample_id}: source is required")
        item.setdefault("tags", [])
        item.setdefault("review", {})
        normalized.append(item)
    payload["samples"] = sorted(
        normalized,
        key=lambda item: (item["period_start"], item["market"], item["sample_id"]),
    )
    return payload


def load_catalog(path: str | Path) -> dict[str, Any]:
    catalog_path = Path(path)
    if not catalog_path.exists():
        return _safe_catalog(
            {
                "schema_version": CATALOG_SCHEMA_VERSION,
                "minimum_historical_sample_count": MINIMUM_HISTORICAL_SAMPLE_COUNT,
                "target_sample_count": DEFAULT_TARGET_SAMPLE_COUNT,
                "samples": [],
            }
        )
    try:
        raw = json.loads(catalog_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SampleCatalogError(f"cannot read catalog {catalog_path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise SampleCatalogError("catalog root must be an object")
    return _safe_catalog(raw)


def _status_counts(catalog: Mapping[str, Any]) -> dict[str, int | bool]:
    samples = list(catalog.get("samples", []))
    review = Counter(item["review_status"] for item in samples)
    workflow = Counter(item["workflow_status"] for item in samples)
    minimum = int(catalog["minimum_historical_sample_count"])
    target = int(catalog["target_sample_count"])
    inventory = len(samples)
    approved = review["approved"]
    return {
        "inventory_count": inventory,
        "minimum_historical_sample_count": minimum,
        "target_sample_count": target,
        "remaining_inventory_to_minimum": max(0, minimum - inventory),
        "remaining_inventory_to_target": max(0, target - inventory),
        "inventory_minimum_met": inventory >= minimum,
        "approved_count": approved,
        "remaining_approved_to_minimum": max(0, minimum - approved),
        "approved_minimum_met": approved >= minimum,
        "runnable_count": workflow["runnable"],
        "needs_adapter_count": workflow["needs_adapter"],
        "reference_only_count": workflow["reference_only"],
        "candidate_count": review["candidate"],
        "historical_reference_count": review["historical_reference"],
        "known_bad_reference_count": review["known_bad_reference"],
        "expected_fail_count": review["expected_fail"],
    }


def write_catalog(path: str | Path, catalog: Mapping[str, Any]) -> dict[str, Any]:
    catalog_path = Path(path)
    payload = _safe_catalog(catalog)
    payload.update(_status_counts(payload))
    payload["updated_at"] = datetime.now(timezone.utc).isoformat()
    catalog_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = catalog_path.with_suffix(catalog_path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    temporary.replace(catalog_path)
    return payload


def resolve_sample_path(
    raw_path: str | Path,
    *,
    catalog_path: str | Path,
    sample_root: str | Path | None = None,
) -> Path:
    path = Path(str(raw_path)).expanduser()
    if path.is_absolute():
        return path
    root_override = os.environ.get("AD_REPORT_SAMPLE_ROOT")
    if root_override:
        root = Path(root_override).expanduser()
    elif sample_root:
        root = Path(sample_root).expanduser()
        if not root.is_absolute():
            root = Path(catalog_path).resolve().parent / root
    else:
        root = Path(catalog_path).resolve().parent
    return (root / path).resolve()


def inspect_production_bundle(path: str | Path) -> dict[str, Any]:
    bundle_path = Path(path).expanduser().resolve()
    ingested = ingest_bundle(bundle_path)
    dated = [
        (table.period_start, table.period_end)
        for kind, table in ingested.tables.items()
        if kind != "keyword"
    ]
    if any(start is None or end is None for start, end in dated):
        raise SampleCatalogError(f"{bundle_path}: one or more source periods are missing")
    periods = {(start, end) for start, end in dated}
    if len(periods) != 1:
        raise SampleCatalogError(f"{bundle_path}: source periods disagree: {periods}")
    period_start, period_end = next(iter(periods))
    return {
        "kind": "zip_bundle",
        "path": str(bundle_path),
        "sha256": ingested.bundle_sha256,
        "ingestion_profile": "it_weekly_v1",
        "source_kinds": sorted(ingested.tables),
        "files": {kind: table.file_name for kind, table in ingested.tables.items()},
        "period_start": period_start.isoformat(),
        "period_end": period_end.isoformat(),
    }


def _deck_xml_summary(payload: bytes, *, source_label: str) -> dict[str, Any]:
    try:
        archive = zipfile.ZipFile(__import__("io").BytesIO(payload))
    except zipfile.BadZipFile as exc:
        raise SampleCatalogError(f"not a readable PowerPoint: {source_label}") from exc
    with archive:
        slide_names = sorted(
            name
            for name in archive.namelist()
            if re.fullmatch(r"ppt/slides/slide\d+\.xml", name)
        )
        texts: list[str] = []
        slide_texts: list[str] = []
        object_names: list[str] = []
        for slide_name in slide_names:
            root = ET.fromstring(archive.read(slide_name))
            current_slide_texts: list[str] = []
            for element in root.iter():
                if element.tag.endswith("}t") and element.text:
                    texts.append(element.text)
                    current_slide_texts.append(element.text)
                if element.tag.endswith("}cNvPr") and element.get("name"):
                    object_names.append(str(element.get("name")))
            slide_texts.append(" ".join(current_slide_texts))
        visible = " ".join(texts)
        period_pattern = re.compile(
            r"(?<!\d)(\d{1,2})[./](\d{1,2})\s*[–—-]\s*(\d{1,2})[./](\d{1,2})(?!\d)"
        )

        def period_tokens(text: str) -> set[str]:
            return {
                f"{int(a)}.{int(b)}–{int(c)}.{int(d)}"
                for a, b, c, d in period_pattern.findall(text)
            }

        compact_periods = period_tokens(visible)
        period_slide_counts = Counter(
            token
            for slide_text in slide_texts
            for token in period_tokens(slide_text)
        )
        primary_count = max(period_slide_counts.values(), default=0)
        primary_periods = sorted(
            token for token, count in period_slide_counts.items() if count == primary_count
        )
        full_dates = sorted(set(re.findall(r"20\d{2}-\d{2}-\d{2}", visible)))
        visible_markets = sorted(
            set(re.findall(r"(?<![A-Za-z])(FR|IT|UK|AU)(?![A-Za-z])", visible))
        )
        charts = [
            name
            for name in archive.namelist()
            if re.fullmatch(r"ppt/(?:slides/)?charts/chart\d+\.xml", name)
        ]
        return {
            "sha256": sha256_bytes(payload),
            "slide_count": len(slide_names),
            "native_chart_count": len(charts),
            "visible_period_tokens": sorted(compact_periods),
            "primary_period_tokens": primary_periods,
            "period_token_slide_counts": dict(sorted(period_slide_counts.items())),
            "visible_full_dates": full_dates,
            "visible_market_tokens": visible_markets,
            "semantic_slot_count": sum(
                1 for name in object_names if name.startswith(("slot.", "asset."))
            ),
            "contains_unresolved_tokens": "{{" in visible,
        }


def inspect_deck_file(path: str | Path) -> dict[str, Any]:
    deck_path = Path(path).expanduser().resolve()
    summary = _deck_xml_summary(deck_path.read_bytes(), source_label=str(deck_path))
    return {"kind": "file", "path": str(deck_path), **summary}


def _archive_member_by_hash(archive_path: Path, expected_hash: str) -> tuple[str, bytes] | None:
    with zipfile.ZipFile(archive_path) as archive:
        for member in archive.infolist():
            if member.is_dir():
                continue
            payload = archive.read(member)
            if sha256_bytes(payload) == expected_hash:
                return member.filename, payload
    return None


def inspect_deck_archive_member(
    archive_path: str | Path,
    *,
    member_sha256: str,
    display_name: str | None = None,
) -> dict[str, Any]:
    path = Path(archive_path).expanduser().resolve()
    found = _archive_member_by_hash(path, member_sha256)
    if found is None:
        raise SampleCatalogError(
            f"deck member hash {member_sha256} was not found in {path}"
        )
    member_name, payload = found
    summary = _deck_xml_summary(
        payload, source_label=f"{path}!{display_name or member_name}"
    )
    return {
        "kind": "archive_member",
        "archive_path": str(path),
        "archive_sha256": sha256_file(path),
        "member_name": display_name or member_name,
        "member_sha256": member_sha256,
        **summary,
    }


def _period_token(start: str, end: str) -> str:
    left = date.fromisoformat(start)
    right = date.fromisoformat(end)
    return f"{left.month}.{left.day}–{right.month}.{right.day}"


def pair_score(source: Mapping[str, Any], deck: Mapping[str, Any], market: str) -> int:
    score = 0
    token = _period_token(str(source["period_start"]), str(source["period_end"]))
    if token in deck.get("primary_period_tokens", []):
        score += 100
    elif token in deck.get("visible_period_tokens", []):
        # A comparison table often mentions the previous week.  That is useful
        # evidence, but never strong enough by itself for automatic pairing.
        score += 40
    source_path = source.get("path") or source.get("archive_path")
    deck_path = deck.get("path") or deck.get("archive_path")
    if source_path and deck_path and Path(str(source_path)).parent == Path(str(deck_path)).parent:
        score += 20
    if market.casefold() in Path(str(deck_path or "")).name.casefold():
        score += 10
    return score


def discover_pairs(
    bundle_paths: Sequence[str | Path],
    deck_paths: Sequence[str | Path],
    *,
    market: str,
) -> dict[str, Any]:
    bundles: list[dict[str, Any]] = []
    rejected_bundles: list[dict[str, str]] = []
    for raw in bundle_paths:
        try:
            bundles.append(inspect_production_bundle(raw))
        except Exception as exc:
            rejected_bundles.append({"path": str(Path(raw).resolve()), "error": str(exc)})
    decks: list[dict[str, Any]] = []
    rejected_decks: list[dict[str, str]] = []
    for raw in deck_paths:
        try:
            decks.append(inspect_deck_file(raw))
        except Exception as exc:
            rejected_decks.append({"path": str(Path(raw).resolve()), "error": str(exc)})
    candidates: list[dict[str, Any]] = []
    for bundle in bundles:
        ranked = sorted(
            (
                {
                    "score": pair_score(bundle, deck, market),
                    "deck": deck,
                }
                for deck in decks
            ),
            key=lambda item: item["score"],
            reverse=True,
        )
        candidates.append(
            {
                "bundle": bundle,
                "deck_candidates": ranked[:5],
                "auto_pair": (
                    ranked[0]["deck"]
                    if ranked
                    and ranked[0]["score"] >= 100
                    and (len(ranked) == 1 or ranked[0]["score"] > ranked[1]["score"])
                    else None
                ),
            }
        )
    return {
        "market": market.upper(),
        "bundle_count": len(bundles),
        "deck_count": len(decks),
        "candidates": candidates,
        "rejected_bundles": rejected_bundles,
        "rejected_decks": rejected_decks,
    }


def _asset_path(
    reference: Mapping[str, Any],
    *,
    catalog_path: Path,
    sample_root: str | Path | None,
) -> tuple[Path | None, str | None]:
    if reference.get("kind") in {"file", "zip_bundle"}:
        raw = reference.get("path")
        return (
            resolve_sample_path(raw, catalog_path=catalog_path, sample_root=sample_root)
            if raw
            else None,
            reference.get("sha256"),
        )
    if reference.get("kind") in {"archive", "archive_member", "archive_member_set"}:
        raw = reference.get("archive_path")
        return (
            resolve_sample_path(raw, catalog_path=catalog_path, sample_root=sample_root)
            if raw
            else None,
            reference.get("archive_sha256"),
        )
    return None, None


def catalog_status(
    catalog: Mapping[str, Any],
    *,
    catalog_path: str | Path,
    verify_hashes: bool = True,
) -> dict[str, Any]:
    payload = _safe_catalog(catalog)
    path = Path(catalog_path).resolve()
    sample_root = payload.get("sample_root")
    digest_cache: dict[Path, str] = {}
    archive_members: dict[Path, list[tuple[str, str]]] = {}

    def members_for(archive_path: Path) -> list[tuple[str, str]]:
        if archive_path not in archive_members:
            with zipfile.ZipFile(archive_path) as archive:
                archive_members[archive_path] = [
                    (member.filename, sha256_bytes(archive.read(member)))
                    for member in archive.infolist()
                    if not member.is_dir()
                ]
        return archive_members[archive_path]

    samples_by_id = {item["sample_id"]: item for item in payload["samples"]}
    sample_results: list[dict[str, Any]] = []
    for item in payload["samples"]:
        issues: list[dict[str, str]] = []
        approved = item["review_status"] == "approved"
        for role in ("source", "deck", "golden_json"):
            reference = item.get(role)
            if not reference:
                if role == "source":
                    issues.append({"code": "MISSING_SOURCE_REF", "message": "source reference is missing"})
                if role == "deck" and item["review_status"] == "approved":
                    issues.append({"code": "MISSING_APPROVED_DECK", "message": "approved sample requires a deck"})
                if role == "golden_json" and item["review_status"] == "approved":
                    issues.append({"code": "MISSING_APPROVED_GOLDEN", "message": "approved sample requires golden JSON"})
                continue
            asset_path, expected_hash = _asset_path(
                reference, catalog_path=path, sample_root=sample_root
            )
            if asset_path is None:
                issues.append({"code": f"INVALID_{role.upper()}_REF", "message": "reference path is missing"})
                continue
            if not asset_path.is_file():
                issues.append({"code": f"MISSING_{role.upper()}", "message": str(asset_path)})
                continue
            if approved and not _is_sha256(expected_hash):
                issues.append(
                    {
                        "code": f"INVALID_APPROVED_{role.upper()}_SHA256",
                        "message": "approved assets require a complete SHA-256",
                    }
                )
            elif expected_hash and not _is_sha256(expected_hash):
                issues.append(
                    {
                        "code": f"INVALID_{role.upper()}_SHA256",
                        "message": str(expected_hash),
                    }
                )
            if verify_hashes and expected_hash:
                actual = digest_cache.setdefault(asset_path, sha256_file(asset_path))
                if actual != expected_hash:
                    issues.append(
                        {
                            "code": f"{role.upper()}_HASH_MISMATCH",
                            "message": f"expected {expected_hash}, got {actual}",
                        }
                    )
            reference_kind = reference.get("kind")
            if reference_kind in {"archive_member", "archive_member_set"}:
                try:
                    members = members_for(asset_path)
                except zipfile.BadZipFile:
                    issues.append(
                        {
                            "code": f"INVALID_{role.upper()}_ARCHIVE",
                            "message": str(asset_path),
                        }
                    )
                    continue
                if reference_kind == "archive_member":
                    member_name = reference.get("member_name")
                    member_sha256 = reference.get("member_sha256")
                    if not isinstance(member_name, str) or not member_name:
                        issues.append(
                            {
                                "code": f"MISSING_{role.upper()}_MEMBER_NAME",
                                "message": "archive_member requires member_name",
                            }
                        )
                    named_digests = [
                        digest for name, digest in members if name == member_name
                    ]
                    if member_name and not named_digests:
                        issues.append(
                            {
                                "code": f"{role.upper()}_MEMBER_NAME_MISSING",
                                "message": f"{member_name!r} is not in {asset_path}",
                            }
                        )
                    if not _is_sha256(member_sha256):
                        issues.append(
                            {
                                "code": f"INVALID_{role.upper()}_MEMBER_SHA256",
                                "message": "archive_member requires a complete member SHA-256",
                            }
                        )
                    elif verify_hashes and named_digests and member_sha256 not in named_digests:
                        issues.append(
                            {
                                "code": f"{role.upper()}_MEMBER_HASH_MISMATCH",
                                "message": (
                                    f"{member_name!r} does not have hash {member_sha256}"
                                ),
                            }
                        )
                else:
                    selectors = [str(value) for value in reference.get("selectors", [])]
                    expected_members = [
                        str(value) for value in reference.get("member_sha256s", [])
                    ]
                    if not selectors:
                        issues.append(
                            {
                                "code": f"MISSING_{role.upper()}_SELECTORS",
                                "message": "archive_member_set requires selectors",
                            }
                        )
                    selected = [
                        (name, digest)
                        for name, digest in members
                        if any(fnmatch.fnmatchcase(name, selector) for selector in selectors)
                    ]
                    for selector in selectors:
                        if not any(
                            fnmatch.fnmatchcase(name, selector) for name, _ in members
                        ):
                            issues.append(
                                {
                                    "code": f"{role.upper()}_SELECTOR_EMPTY",
                                    "message": f"{selector!r} matched no member in {asset_path}",
                                }
                            )
                    if not expected_members or not all(
                        _is_sha256(value) for value in expected_members
                    ):
                        issues.append(
                            {
                                "code": f"INVALID_{role.upper()}_MEMBER_SET_SHA256",
                                "message": "member_sha256s must contain complete SHA-256 values",
                            }
                        )
                    elif verify_hashes and Counter(
                        digest for _, digest in selected
                    ) != Counter(expected_members):
                        issues.append(
                            {
                                "code": f"{role.upper()}_MEMBER_SET_MISMATCH",
                                "message": (
                                    "selector results and member_sha256s are not one-to-one"
                                ),
                            }
                        )
            if role == "golden_json":
                try:
                    golden_raw = json.loads(asset_path.read_text(encoding="utf-8"))
                    report_raw = golden_raw.get("report", golden_raw)
                    golden_report = CanonicalReport.model_validate(report_raw)
                    if golden_report.market.upper() != item["market"]:
                        raise SampleCatalogError("golden market does not match sample")
                    if golden_report.period_start.isoformat() != item["period_start"]:
                        raise SampleCatalogError("golden period_start does not match sample")
                    if golden_report.period_end.isoformat() != item["period_end"]:
                        raise SampleCatalogError("golden period_end does not match sample")
                except Exception as exc:
                    issues.append(
                        {
                            "code": "INVALID_GOLDEN_REPORT",
                            "message": str(exc),
                        }
                    )
            if approved and role == "deck":
                try:
                    if reference_kind == "file":
                        deck_payload = asset_path.read_bytes()
                    elif reference_kind == "archive_member":
                        with zipfile.ZipFile(asset_path) as archive:
                            deck_payload = archive.read(str(reference["member_name"]))
                    else:
                        raise SampleCatalogError(
                            "approved deck must be a file or one archive member"
                        )
                    deck_summary = _deck_xml_summary(
                        deck_payload, source_label=f"approved:{item['sample_id']}"
                    )
                    expected_period = _period_token(
                        item["period_start"], item["period_end"]
                    )
                    if expected_period not in deck_summary["primary_period_tokens"]:
                        raise SampleCatalogError(
                            f"deck primary period does not include {expected_period}"
                        )
                    if item["market"] not in deck_summary["visible_market_tokens"]:
                        raise SampleCatalogError(
                            f"deck does not contain market token {item['market']}"
                        )
                except Exception as exc:
                    issues.append(
                        {"code": "INVALID_APPROVED_DECK_SCOPE", "message": str(exc)}
                    )
        previous_source = item.get("previous_source")
        if previous_source:
            previous_kind = previous_source.get("kind")
            if previous_kind == "catalog_sample":
                previous_id = previous_source.get("sample_id")
                previous = samples_by_id.get(previous_id)
                if previous is None:
                    issues.append(
                        {
                            "code": "PREVIOUS_SAMPLE_MISSING",
                            "message": str(previous_id),
                        }
                    )
                elif previous["market"] != item["market"] or (
                    date.fromisoformat(item["period_start"])
                    - date.fromisoformat(previous["period_end"])
                ).days != 1:
                    issues.append(
                        {
                            "code": "PREVIOUS_SAMPLE_NOT_ADJACENT",
                            "message": str(previous_id),
                        }
                    )
            elif previous_kind == "seed_file":
                raw_seed = previous_source.get("path")
                seed_file = (
                    resolve_sample_path(
                        raw_seed, catalog_path=path, sample_root=sample_root
                    )
                    if raw_seed
                    else None
                )
                expected_seed_hash = previous_source.get("sha256")
                if seed_file is None or not seed_file.is_file():
                    issues.append(
                        {
                            "code": "PREVIOUS_SEED_MISSING",
                            "message": str(seed_file or raw_seed),
                        }
                    )
                elif not _is_sha256(expected_seed_hash):
                    issues.append(
                        {
                            "code": "INVALID_PREVIOUS_SEED_SHA256",
                            "message": str(expected_seed_hash),
                        }
                    )
                elif verify_hashes and sha256_file(seed_file) != expected_seed_hash:
                    issues.append(
                        {
                            "code": "PREVIOUS_SEED_HASH_MISMATCH",
                            "message": str(seed_file),
                        }
                    )
            elif approved or item["workflow_status"] == "runnable":
                issues.append(
                    {
                        "code": "UNSUPPORTED_PREVIOUS_SOURCE",
                        "message": str(previous_kind),
                    }
                )
        elif approved or item["workflow_status"] == "runnable":
            issues.append(
                {
                    "code": "MISSING_PREVIOUS_SOURCE",
                    "message": "runnable and approved samples require previous_source",
                }
            )
        if approved:
            review = item.get("review") if isinstance(item.get("review"), dict) else {}
            reviewer = review.get("reviewer")
            if not isinstance(reviewer, str) or not reviewer.strip():
                issues.append(
                    {"code": "MISSING_APPROVED_REVIEWER", "message": "reviewer is required"}
                )
            try:
                _parse_approved_at(review.get("approved_at"))
            except SampleCatalogError as exc:
                issues.append(
                    {"code": "INVALID_APPROVED_AT", "message": str(exc)}
                )
            if (
                not previous_source
                or previous_source.get("kind") not in APPROVED_PREVIOUS_SOURCE_KINDS
            ):
                issues.append(
                    {
                        "code": "INVALID_APPROVED_PREVIOUS_SOURCE",
                        "message": "approved previous_source must be catalog_sample or seed_file",
                    }
                )
        sample_results.append(
            {
                "sample_id": item["sample_id"],
                "market": item["market"],
                "period_start": item["period_start"],
                "period_end": item["period_end"],
                "review_status": item["review_status"],
                "workflow_status": item["workflow_status"],
                "integrity": "PASS" if not issues else "FAIL",
                "issues": issues,
            }
        )

    gaps: list[dict[str, Any]] = []
    by_market: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for item in payload["samples"]:
        by_market[item["market"]].append(item)
    for market, items in by_market.items():
        ordered = sorted(items, key=lambda item: item["period_start"])
        for previous, current in zip(ordered, ordered[1:]):
            previous_end = date.fromisoformat(previous["period_end"])
            current_start = date.fromisoformat(current["period_start"])
            gap_days = (current_start - previous_end).days - 1
            if gap_days != 0:
                gaps.append(
                    {
                        "market": market,
                        "previous_sample_id": previous["sample_id"],
                        "next_sample_id": current["sample_id"],
                        "gap_days": gap_days,
                    }
                )
    summary = _status_counts(payload)
    summary.update(
        {
            "integrity_pass_count": sum(
                1 for item in sample_results if item["integrity"] == "PASS"
            ),
            "integrity_fail_count": sum(
                1 for item in sample_results if item["integrity"] == "FAIL"
            ),
            "period_gap_count": len(gaps),
        }
    )
    return {"summary": summary, "samples": sample_results, "period_gaps": gaps}


def register_production_sample(
    *,
    catalog_path: str | Path,
    bundle_path: str | Path,
    deck_path: str | Path | None,
    market: str,
    review_status: str = "candidate",
    workflow_status: str = "runnable",
    reviewer: str | None = None,
    approved_at: str | None = None,
    golden_json_path: str | Path | None = None,
    previous_source: Mapping[str, Any] | None = None,
    notes: str = "",
    tags: Sequence[str] = (),
    replace: bool = False,
) -> dict[str, Any]:
    if review_status not in REVIEW_STATUSES:
        raise SampleCatalogError(f"unsupported review_status: {review_status}")
    if workflow_status not in WORKFLOW_STATUSES:
        raise SampleCatalogError(f"unsupported workflow_status: {workflow_status}")
    source = inspect_production_bundle(bundle_path)
    deck = inspect_deck_file(deck_path) if deck_path else None
    golden = None
    if golden_json_path:
        golden_path = Path(golden_json_path).expanduser().resolve()
        golden_raw = json.loads(golden_path.read_text(encoding="utf-8"))
        golden_report = CanonicalReport.model_validate(
            golden_raw.get("report", golden_raw)
        )
        if golden_report.market.upper() != market.upper():
            raise SampleCatalogError("golden JSON market does not match --market")
        if golden_report.period_start.isoformat() != source["period_start"] or (
            golden_report.period_end.isoformat() != source["period_end"]
        ):
            raise SampleCatalogError("golden JSON period does not match source bundle")
        golden = {
            "kind": "file",
            "path": str(golden_path),
            "sha256": sha256_file(golden_path),
        }
    if review_status == "approved":
        if (
            deck is None
            or golden is None
            or not isinstance(reviewer, str)
            or not reviewer.strip()
            or not approved_at
            or not previous_source
        ):
            raise SampleCatalogError(
                "approved samples require deck, golden JSON, reviewer, approved_at, "
                "and previous_source"
            )
        _parse_approved_at(approved_at)
        if previous_source.get("kind") not in APPROVED_PREVIOUS_SOURCE_KINDS:
            raise SampleCatalogError(
                "approved previous_source must be catalog_sample or seed_file"
            )
    sample_id = f"{market.lower()}-{source['period_start']}"
    sample = {
        "sample_id": sample_id,
        "market": market.upper(),
        "period_start": source["period_start"],
        "period_end": source["period_end"],
        "review_status": review_status,
        "workflow_status": workflow_status,
        "source": source,
        "deck": deck,
        "golden_json": golden,
        "previous_source": dict(previous_source) if previous_source else None,
        "review": {
            "reviewer": reviewer,
            "approved_at": approved_at,
            "notes": notes,
        },
        "tags": sorted(set(tags)),
        "registered_at": datetime.now(timezone.utc).isoformat(),
    }
    catalog = load_catalog(catalog_path)
    existing = next(
        (item for item in catalog["samples"] if item["sample_id"] == sample_id), None
    )
    if existing:
        comparable_existing = dict(existing)
        comparable_sample = dict(sample)
        comparable_existing.pop("registered_at", None)
        comparable_sample.pop("registered_at", None)
        if comparable_existing == comparable_sample:
            return existing
        if not replace:
            raise SampleCatalogError(
                f"{sample_id} already exists with different metadata; pass --replace after review"
            )
        catalog["samples"] = [
            item for item in catalog["samples"] if item["sample_id"] != sample_id
        ]
    period_duplicate = next(
        (
            item
            for item in catalog["samples"]
            if item["market"] == sample["market"]
            and item["period_start"] == sample["period_start"]
            and item["period_end"] == sample["period_end"]
        ),
        None,
    )
    if period_duplicate:
        raise SampleCatalogError(
            f"market-period is already registered as {period_duplicate['sample_id']}"
        )
    duplicate = next(
        (
            item
            for item in catalog["samples"]
            if item.get("source", {}).get("sha256") == source["sha256"]
        ),
        None,
    )
    if duplicate:
        raise SampleCatalogError(
            f"source bundle is already registered as {duplicate['sample_id']}"
        )
    catalog["samples"].append(sample)
    registration_status = catalog_status(
        catalog, catalog_path=catalog_path, verify_hashes=True
    )
    registered_result = next(
        item
        for item in registration_status["samples"]
        if item["sample_id"] == sample_id
    )
    if registered_result["integrity"] != "PASS":
        raise SampleCatalogError(
            f"registration integrity failed: {registered_result['issues']}"
        )
    write_catalog(catalog_path, catalog)
    return sample


def _normalized_golden(report: Mapping[str, Any]) -> dict[str, Any]:
    payload = json.loads(json.dumps(report, ensure_ascii=False))
    for entry in payload.get("lineage", []):
        for source in entry.get("sources", []):
            if source.get("source_kind") in {"history_seed", "history_db"}:
                source["file"] = Path(str(source.get("file", ""))).name
    return payload


def replay_catalog(
    catalog: Mapping[str, Any],
    *,
    catalog_path: str | Path,
    config_path: str | Path,
    seed_path: str | Path,
    build_ppt: bool = False,
    template_path: str | Path | None = None,
    deck_builder_path: str | Path | None = None,
    node_path: str | Path | None = None,
) -> dict[str, Any]:
    payload = _safe_catalog(catalog)
    status = catalog_status(payload, catalog_path=catalog_path, verify_hashes=True)
    integrity = {item["sample_id"]: item for item in status["samples"]}
    root = Path(__file__).resolve().parents[2]
    catalog_file = Path(catalog_path).resolve()
    sample_root = payload.get("sample_root")
    results: list[dict[str, Any]] = []
    ordered = sorted(
        payload["samples"],
        key=lambda item: (item["market"], item["period_start"], item["sample_id"]),
    )
    tmp_parent = root / "tmp"
    tmp_parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="sample-replay-", dir=tmp_parent) as temp_name:
        temporary = Path(temp_name)
        results_by_id: dict[str, dict[str, Any]] = {}
        passed_reports: dict[str, CanonicalReport] = {}
        for item in ordered:
            sample_id = item["sample_id"]
            base = {
                "sample_id": sample_id,
                "market": item["market"],
                "period_start": item["period_start"],
                "review_status": item["review_status"],
                "workflow_status": item["workflow_status"],
            }
            if integrity[sample_id]["integrity"] != "PASS":
                outcome = {
                    **base,
                    "status": "FAIL",
                    "reason": "asset integrity failed",
                    "issues": integrity[sample_id]["issues"],
                }
                results.append(outcome)
                results_by_id[sample_id] = outcome
                continue
            if item["workflow_status"] != "runnable":
                outcome = {
                    **base,
                    "status": "SKIP",
                    "reason": item.get("adapter_reason")
                    or f"workflow_status={item['workflow_status']}",
                }
                results.append(outcome)
                results_by_id[sample_id] = outcome
                continue
            source = item["source"]
            if source.get("kind") != "zip_bundle" or source.get("ingestion_profile") != "it_weekly_v1":
                outcome = {
                    **base,
                    "status": "FAIL",
                    "reason": "runnable sample has unsupported source reference",
                }
                results.append(outcome)
                results_by_id[sample_id] = outcome
                continue
            bundle = resolve_sample_path(
                source["path"], catalog_path=catalog_file, sample_root=sample_root
            )
            history_db = temporary / f"history-{sample_id}.sqlite3"
            try:
                previous_source = item.get("previous_source") or {}
                previous_kind = previous_source.get("kind")
                seed_for_run: Path | None = None
                previous_evidence: dict[str, Any]
                if previous_kind == "seed_file":
                    seed_for_run = resolve_sample_path(
                        previous_source["path"],
                        catalog_path=catalog_file,
                        sample_root=sample_root,
                    )
                    previous_evidence = {
                        "kind": "seed_file",
                        "path": str(seed_for_run),
                        "sha256": sha256_file(seed_for_run),
                    }
                elif previous_kind == "catalog_sample":
                    previous_id = str(previous_source.get("sample_id", ""))
                    previous_result = results_by_id.get(previous_id)
                    previous_report = passed_reports.get(previous_id)
                    if not previous_result or previous_result.get("status") != "PASS" or (
                        previous_report is None
                    ):
                        raise SampleCatalogError(
                            f"previous_source chain is not runnable: {previous_id}"
                        )
                    commit_report_history(previous_report, history_db)
                    previous_evidence = {
                        "kind": "catalog_sample",
                        "sample_id": previous_id,
                    }
                else:
                    raise SampleCatalogError(
                        f"unsupported previous_source for replay: {previous_kind!r}"
                    )
                pipeline = run_data_pipeline(
                    bundle,
                    config_path,
                    history_db_path=history_db,
                    seed_path=seed_for_run,
                )
                pipeline.validation.raise_for_errors()
                actual = _normalized_golden(pipeline.report.model_dump(mode="json"))
                golden_ref = item.get("golden_json")
                golden_match: bool | None = None
                if golden_ref:
                    golden_path = resolve_sample_path(
                        golden_ref["path"],
                        catalog_path=catalog_file,
                        sample_root=sample_root,
                    )
                    expected_raw = json.loads(golden_path.read_text(encoding="utf-8"))
                    expected = _normalized_golden(expected_raw.get("report", expected_raw))
                    golden_match = expected == actual
                    if not golden_match:
                        raise SampleCatalogError("canonical output differs from frozen golden JSON")
                deck_built = False
                if build_ppt:
                    if not template_path or not deck_builder_path:
                        raise SampleCatalogError(
                            "build_ppt requires template_path and deck_builder_path"
                        )
                    report_path = temporary / f"{sample_id}.json"
                    deck_path = temporary / f"{sample_id}.pptx"
                    report_path.write_text(
                        json.dumps(actual, ensure_ascii=False, indent=2) + "\n",
                        encoding="utf-8",
                    )
                    node = str(node_path or "node")
                    builder = Path(deck_builder_path).resolve()
                    builder_cwd = builder.parent / "build"
                    if not builder_cwd.is_dir():
                        builder_cwd = builder.parent
                    completed = subprocess.run(
                        [
                            node,
                            str(builder),
                            "--input",
                            str(report_path),
                            "--template",
                            str(Path(template_path).resolve()),
                            "--output",
                            str(deck_path),
                        ],
                        cwd=builder_cwd,
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                    if completed.returncode or not deck_path.is_file():
                        raise SampleCatalogError(
                            f"PowerPoint replay failed: {completed.stdout[-1000:]} {completed.stderr[-1000:]}"
                        )
                    with zipfile.ZipFile(deck_path) as archive:
                        slide_count = sum(
                            1
                            for name in archive.namelist()
                            if re.fullmatch(r"ppt/slides/slide\d+\.xml", name)
                        )
                    if slide_count != 8:
                        raise SampleCatalogError(
                            f"PowerPoint replay produced {slide_count} slides instead of 8"
                        )
                    deck_built = True
                commit_report_history(pipeline.report, history_db)
                outcome = {
                    **base,
                    "status": "PASS",
                    "validation_issue_count": len(pipeline.validation.issues),
                    "lineage_count": len(pipeline.report.lineage),
                    "golden_compared": golden_match is not None,
                    "golden_match": golden_match,
                    "ppt_built": deck_built,
                    "previous_source_used": previous_evidence,
                }
                results.append(outcome)
                results_by_id[sample_id] = outcome
                passed_reports[sample_id] = pipeline.report
            except Exception as exc:
                outcome = {**base, "status": "FAIL", "reason": str(exc)}
                results.append(outcome)
                results_by_id[sample_id] = outcome
    summary = Counter(item["status"] for item in results)
    approved_failures = [
        item
        for item in results
        if item["review_status"] == "approved" and item["status"] != "PASS"
    ]
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "total": len(results),
            "pass": summary["PASS"],
            "fail": summary["FAIL"],
            "skip": summary["SKIP"],
            "executed": summary["PASS"] + summary["FAIL"],
            "approved_failures": len(approved_failures),
            "passed": (
                summary["PASS"] > 0
                and summary["FAIL"] == 0
                and not approved_failures
            ),
        },
        "results": results,
    }
