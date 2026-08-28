"""Fail-closed input bundle and report-profile resolution for the CLI/app."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
from collections import Counter
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import tempfile
from typing import Any, Iterator, Mapping
import unicodedata
import zipfile

from .ingest import (
    HEADER_FINGERPRINTS,
    REQUIRED_SOURCE_KINDS,
    SUPPORTED_SOURCE_SUFFIXES,
    IngestionError,
    ingest_bundle,
    read_source_payload,
    row_value,
)
from .models import IngestedBundle, ReportConfig, load_report_config


PROJECT_ROOT = Path(__file__).resolve().parents[2]
MAX_NESTED_BUNDLE_BYTES = 256 * 1024 * 1024
MAX_FOLDER_SOURCE_BYTES = 256 * 1024 * 1024
MAX_FOLDER_CANDIDATES = 256
MAX_DISCOVERY_DETAILS = 200


class ProfileResolutionError(ValueError):
    """Raised when the input cannot be assigned to exactly one known profile."""


class InputBundleResolutionError(ValueError):
    """Raised when neither a direct bundle nor one unambiguous nested bundle works."""


class InputFolderResolutionError(ValueError):
    """Raised when a folder does not contain exactly one complete source set."""

    def __init__(self, message: str, discovery: Mapping[str, Any]):
        super().__init__(message)
        self.discovery = dict(discovery)
        self.discovery["ready"] = False
        if not self.discovery.get("errors"):
            self.discovery["errors"] = [message]


@dataclass(frozen=True)
class ProfileSpec:
    """Files and version contract for one supported report profile."""

    name: str
    config_path: Path
    template_version: str
    template_path: Path | None


@dataclass(frozen=True)
class ResolvedInputBundle:
    """A classifiable weekly bundle, direct or safely materialized from an outer ZIP."""

    path: Path
    ingested: IngestedBundle
    nested_bundle: str | None = None
    input_folder: Path | None = None
    discovery: Mapping[str, Any] | None = None


PROFILE_SPECS: Mapping[str, ProfileSpec] = {
    "production": ProfileSpec(
        name="production",
        config_path=PROJECT_ROOT / "config" / "it_weekly_v1.json",
        template_version="it-weekly-v1",
        template_path=PROJECT_ROOT / "ppt" / "semantic_template_it_weekly_v1.pptx",
    ),
    "demo": ProfileSpec(
        name="demo",
        config_path=(
            PROJECT_ROOT
            / "demo_anonymized"
            / "deliverable"
            / "demo_weekly_v1.json"
        ),
        template_version="demo-weekly-v1",
        template_path=None,
    ),
}


def _normalized_text(value: object) -> str:
    return re.sub(
        r"\s+",
        " ",
        unicodedata.normalize("NFKC", str(value or "")),
    ).strip().casefold()


def _matched_product_id(text: object, config: ReportConfig) -> str | None:
    normalized = _normalized_text(text)
    matches: list[tuple[int, str]] = []
    for product in config.products:
        for alias in product.aliases:
            normalized_alias = _normalized_text(alias)
            if normalized_alias and normalized_alias in normalized:
                matches.append((len(normalized_alias), product.id))
    if not matches:
        return None
    longest = max(length for length, _ in matches)
    winners = {product_id for length, product_id in matches if length == longest}
    return next(iter(winners)) if len(winners) == 1 else None


def _bundle_matches_config(bundle: IngestedBundle, config: ReportConfig) -> bool:
    """Match only identifier-bearing fields, leaving metric errors to the pipeline."""

    by_product = bundle.tables.get("by_product")
    creative = bundle.tables.get("creative")
    if by_product is None or creative is None:
        return False

    matched_ids: list[str] = []
    for row in by_product.rows:
        name = row_value(row, "Name", required=False)
        if not _normalized_text(name):
            continue
        product_id = _matched_product_id(name, config)
        if product_id is None:
            return False
        matched_ids.append(product_id)

    expected_ids = [product.id for product in config.products]
    if sorted(matched_ids) != sorted(expected_ids):
        return False

    creative_names = [
        _normalized_text(row_value(row, "Ads", required=False))
        for row in creative.rows
    ]
    for product in config.products:
        pin = _normalized_text(product.creative_pin)
        if not pin or creative_names.count(pin) != 1:
            return False
    return True


def matching_input_profiles(
    bundle: IngestedBundle,
    *,
    profiles: Mapping[str, ProfileSpec] = PROFILE_SPECS,
) -> list[ProfileSpec]:
    """Return every configured profile matching identifier-bearing source fields."""

    matches: list[ProfileSpec] = []
    for profile in profiles.values():
        if not profile.config_path.is_file():
            raise ProfileResolutionError(
                f"profile {profile.name!r} config is missing: {profile.config_path}"
            )
        config = load_report_config(profile.config_path)
        if _bundle_matches_config(bundle, config):
            matches.append(profile)
    return matches


def resolve_input_profile(
    requested: str,
    bundle: IngestedBundle,
    *,
    profiles: Mapping[str, ProfileSpec] = PROFILE_SPECS,
) -> ProfileSpec:
    """Resolve an explicit profile or detect exactly one profile from bundle content."""

    if requested != "auto":
        try:
            return profiles[requested]
        except KeyError as exc:
            raise ProfileResolutionError(
                f"unsupported input profile {requested!r}; expected auto, production, or demo"
            ) from exc

    matches = matching_input_profiles(bundle, profiles=profiles)

    if len(matches) == 1:
        return matches[0]
    if not matches:
        raise ProfileResolutionError(
            "input content did not match any supported report profile; "
            "expected exactly one of production or demo"
        )
    names = ", ".join(sorted(profile.name for profile in matches))
    raise ProfileResolutionError(
        f"input content matched multiple report profiles ({names}); refusing to guess"
    )


def _record_ignored(
    details: list[dict[str, str]],
    counts: Counter[str],
    relative_path: str,
    reason: str,
) -> None:
    counts[reason] += 1
    if len(details) < MAX_DISCOVERY_DETAILS:
        details.append({"path": relative_path, "reason": reason})


def _folder_discovery_base(root: Path) -> dict[str, Any]:
    return {
        "root": str(root),
        "recursive": True,
        "required_kinds": list(HEADER_FINGERPRINTS),
        "required_count": len(HEADER_FINGERPRINTS),
        "candidate_count": 0,
        "candidate_files": [],
        "classified_count": 0,
        "classified_files": {},
        "selected_count": 0,
        "selected_files": {},
        "found_count": 0,
        "found": {},
        "ignored_count": 0,
        "ignored_by_reason": {},
        "ignored_files": [],
        "ignored": [],
        "ignored_files_truncated": False,
        "unrecognized_count": 0,
        "unrecognized_files": [],
        "missing_kinds": list(HEADER_FINGERPRINTS),
        "missing": list(HEADER_FINGERPRINTS),
        "duplicate_kinds": {},
        "duplicates": {},
        "complete_source_set": False,
        "source_set_sha256": None,
        "folder_sha256": None,
        "matched_profiles": [],
        "selected_profile": None,
        "profile": None,
        "ready": False,
        "errors": [],
    }


def _discover_folder_sources(
    root: Path,
) -> tuple[dict[str, tuple[Path, str]], dict[str, Any]]:
    """Recursively classify candidate files without following links or guessing."""

    discovery = _folder_discovery_base(root)
    ignored_details: list[dict[str, str]] = []
    ignored_counts: Counter[str] = Counter()
    candidates: list[tuple[str, Path]] = []

    def on_walk_error(error: OSError) -> None:
        raise InputFolderResolutionError(
            f"input folder could not be read safely: {error}", discovery
        ) from error

    for directory, dirnames, filenames in os.walk(
        root, topdown=True, followlinks=False, onerror=on_walk_error
    ):
        directory_path = Path(directory)
        kept_directories: list[str] = []
        for dirname in sorted(dirnames, key=str.casefold):
            child = directory_path / dirname
            relative = child.relative_to(root).as_posix()
            if dirname.startswith(".") or dirname == "__MACOSX":
                _record_ignored(
                    ignored_details, ignored_counts, relative + "/", "hidden_or_system"
                )
            elif child.is_symlink():
                _record_ignored(
                    ignored_details, ignored_counts, relative + "/", "symbolic_link"
                )
            else:
                kept_directories.append(dirname)
        dirnames[:] = kept_directories

        for filename in sorted(filenames, key=str.casefold):
            path = directory_path / filename
            relative = path.relative_to(root).as_posix()
            suffix = path.suffix.casefold()
            if filename.startswith(".") or filename.startswith("._"):
                _record_ignored(
                    ignored_details, ignored_counts, relative, "hidden_or_system"
                )
                continue
            if filename.startswith("~$") or filename.casefold().endswith(".tmp"):
                _record_ignored(ignored_details, ignored_counts, relative, "temporary")
                continue
            if path.is_symlink():
                _record_ignored(
                    ignored_details, ignored_counts, relative, "symbolic_link"
                )
                continue
            if suffix not in SUPPORTED_SOURCE_SUFFIXES:
                _record_ignored(
                    ignored_details, ignored_counts, relative, "unsupported_extension"
                )
                continue
            if not path.is_file():
                _record_ignored(
                    ignored_details, ignored_counts, relative, "not_regular_file"
                )
                continue
            candidates.append((relative, path))

    discovery["ignored_count"] = sum(ignored_counts.values())
    discovery["ignored_by_reason"] = dict(sorted(ignored_counts.items()))
    discovery["ignored_files"] = ignored_details
    discovery["ignored"] = ignored_details
    discovery["ignored_files_truncated"] = (
        discovery["ignored_count"] > len(ignored_details)
    )
    discovery["candidate_count"] = len(candidates)
    discovery["candidate_files"] = [relative for relative, _ in candidates]

    if len(candidates) > MAX_FOLDER_CANDIDATES:
        raise InputFolderResolutionError(
            f"input folder contains {len(candidates)} candidate source files; "
            f"the safety limit is {MAX_FOLDER_CANDIDATES}",
            discovery,
        )

    classified: dict[str, list[tuple[str, Path, str]]] = {}
    unrecognized: list[dict[str, str]] = []
    for relative, path in candidates:
        try:
            with path.open("rb") as handle:
                payload = handle.read(MAX_FOLDER_SOURCE_BYTES + 1)
            if len(payload) > MAX_FOLDER_SOURCE_BYTES:
                raise IngestionError(
                    f"file is larger than the {MAX_FOLDER_SOURCE_BYTES}-byte safety limit"
                )
            table = read_source_payload(relative, payload)
            file_sha256 = hashlib.sha256(payload).hexdigest()
        except Exception as exc:
            unrecognized.append(
                {
                    "path": relative,
                    "error": f"{type(exc).__name__}: {exc}"[:1000],
                }
            )
            _record_ignored(
                ignored_details, ignored_counts, relative, "unrecognized_source"
            )
            continue
        classified.setdefault(table.kind, []).append((relative, path, file_sha256))

    ordered_classified = {
        kind: [relative for relative, _, _ in classified[kind]]
        for kind in HEADER_FINGERPRINTS
        if kind in classified
    }
    missing = [kind for kind in HEADER_FINGERPRINTS if kind not in classified]
    duplicates = {
        kind: [relative for relative, _, _ in classified[kind]]
        for kind in HEADER_FINGERPRINTS
        if len(classified.get(kind, [])) > 1
    }
    selected = {
        kind: classified[kind][0]
        for kind in HEADER_FINGERPRINTS
        if len(classified.get(kind, [])) == 1
    }
    discovery.update(
        {
            "classified_count": sum(len(items) for items in classified.values()),
            "classified_files": ordered_classified,
            "selected_count": len(selected),
            "selected_files": {
                kind: relative for kind, (relative, _, _) in selected.items()
            },
            "found_count": len(selected),
            "found": {
                kind: relative for kind, (relative, _, _) in selected.items()
            },
            "unrecognized_count": len(unrecognized),
            "unrecognized_files": unrecognized,
            "missing_kinds": missing,
            "missing": missing,
            "duplicate_kinds": duplicates,
            "duplicates": duplicates,
            "complete_source_set": not missing and not duplicates,
            "ignored_count": sum(ignored_counts.values()),
            "ignored_by_reason": dict(sorted(ignored_counts.items())),
            "ignored_files": ignored_details,
            "ignored": ignored_details,
            "ignored_files_truncated": (
                sum(ignored_counts.values()) > len(ignored_details)
            ),
        }
    )

    if missing or duplicates:
        parts: list[str] = []
        if missing:
            parts.append(f"missing={missing}")
        if duplicates:
            duplicate_summary = {
                kind: paths for kind, paths in duplicates.items()
            }
            parts.append(f"duplicates={duplicate_summary}")
        message = (
            "input folder must contain exactly one complete eight-file source set; "
            + ", ".join(parts)
        )
        discovery["errors"] = [message]
        raise InputFolderResolutionError(message, discovery)

    digest = hashlib.sha256()
    selected_paths: dict[str, tuple[Path, str]] = {}
    for kind in HEADER_FINGERPRINTS:
        relative, path, file_sha256 = selected[kind]
        digest.update(kind.encode("utf-8"))
        digest.update(b"\0")
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(bytes.fromhex(file_sha256))
        selected_paths[relative] = (path, file_sha256)
    discovery["source_set_sha256"] = digest.hexdigest()
    discovery["folder_sha256"] = digest.hexdigest()
    return selected_paths, discovery


@contextmanager
def resolve_input_folder(folder_path: str | Path) -> Iterator[ResolvedInputBundle]:
    """Materialize exactly one safely discovered source set as a temporary ZIP.

    The temporary bundle keeps the established deterministic ZIP pipeline intact;
    callers never need to prepare or retain a ZIP themselves.
    """

    root = Path(folder_path).expanduser().resolve()
    discovery = _folder_discovery_base(root)
    if not root.is_dir():
        raise InputFolderResolutionError(
            f"input folder must be a readable directory: {root}", discovery
        )

    selected, discovery = _discover_folder_sources(root)
    with tempfile.TemporaryDirectory(prefix="ad-report-folder-") as temporary:
        bundle_path = Path(temporary) / "discovered-weekly-inputs.zip"
        materialized_digest = hashlib.sha256()
        with zipfile.ZipFile(bundle_path, "w", zipfile.ZIP_DEFLATED) as archive:
            for kind in HEADER_FINGERPRINTS:
                relative = discovery["selected_files"][kind]
                path, discovered_file_sha256 = selected[relative]
                if path.is_symlink() or not path.is_file():
                    raise InputFolderResolutionError(
                        f"selected source changed during discovery: {relative}", discovery
                    )
                try:
                    path.resolve(strict=True).relative_to(root)
                except (OSError, ValueError) as exc:
                    raise InputFolderResolutionError(
                        f"selected source escaped the input folder: {relative}", discovery
                    ) from exc
                with path.open("rb") as handle:
                    payload = handle.read(MAX_FOLDER_SOURCE_BYTES + 1)
                if len(payload) > MAX_FOLDER_SOURCE_BYTES:
                    raise InputFolderResolutionError(
                        f"selected source exceeded the {MAX_FOLDER_SOURCE_BYTES}-byte "
                        f"safety limit during inspection: {relative}",
                        discovery,
                    )
                if hashlib.sha256(payload).hexdigest() != discovered_file_sha256:
                    raise InputFolderResolutionError(
                        f"input source changed during inspection: {relative}", discovery
                    )
                materialized_digest.update(kind.encode("utf-8"))
                materialized_digest.update(b"\0")
                materialized_digest.update(relative.encode("utf-8"))
                materialized_digest.update(b"\0")
                materialized_digest.update(bytes.fromhex(discovered_file_sha256))
                info = zipfile.ZipInfo(relative, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100600 << 16
                archive.writestr(info, payload)
        if materialized_digest.hexdigest() != discovery["source_set_sha256"]:
            raise InputFolderResolutionError(
                "input folder changed while it was being inspected; please try again",
                discovery,
            )
        ingested = ingest_bundle(bundle_path)
        selected_files = discovery["selected_files"]
        ingested = ingested.model_copy(
            update={
                "bundle_path": str(root),
                "bundle_sha256": discovery["source_set_sha256"],
                "tables": {
                    kind: table.model_copy(
                        update={"file_name": selected_files[kind]}
                    )
                    for kind, table in ingested.tables.items()
                },
            }
        )
        yield ResolvedInputBundle(
            path=bundle_path,
            ingested=ingested,
            nested_bundle=None,
            input_folder=root,
            discovery=discovery,
        )


def _read_nested_member(archive: zipfile.ZipFile, member: zipfile.ZipInfo) -> bytes:
    if member.flag_bits & 0x1:
        raise InputBundleResolutionError(
            f"nested ZIP is encrypted and cannot be inspected: {member.filename}"
        )
    if member.file_size > MAX_NESTED_BUNDLE_BYTES:
        raise InputBundleResolutionError(
            f"nested ZIP is larger than the {MAX_NESTED_BUNDLE_BYTES}-byte safety limit: "
            f"{member.filename}"
        )
    with archive.open(member) as handle:
        payload = handle.read(MAX_NESTED_BUNDLE_BYTES + 1)
    if len(payload) > MAX_NESTED_BUNDLE_BYTES:
        raise InputBundleResolutionError(
            f"nested ZIP exceeded the {MAX_NESTED_BUNDLE_BYTES}-byte safety limit: "
            f"{member.filename}"
        )
    return payload


@contextmanager
def resolve_input_bundle(bundle_path: str | Path) -> Iterator[ResolvedInputBundle]:
    """Use a direct weekly ZIP or one uniquely classifiable nested ZIP.

    Nested files are never extracted by their archive paths. Candidate bytes are
    written to controlled temporary names, preventing path traversal and keeping
    the materialized bundle alive only for the duration of the CLI run.
    """

    path = Path(bundle_path).expanduser().resolve()
    try:
        direct = ingest_bundle(path)
    except (IngestionError, OSError, zipfile.BadZipFile) as direct_error:
        if not path.is_file() or not zipfile.is_zipfile(path):
            raise InputBundleResolutionError(str(direct_error)) from direct_error

        with tempfile.TemporaryDirectory(prefix="ad-report-nested-") as temporary:
            successful: list[ResolvedInputBundle] = []
            with zipfile.ZipFile(path) as archive:
                candidates = [
                    member
                    for member in archive.infolist()
                    if not member.is_dir()
                    and not member.filename.startswith("__MACOSX/")
                    and not PurePosixPath(member.filename).name.startswith("._")
                    and PurePosixPath(member.filename).suffix.casefold() == ".zip"
                ]
                for index, member in enumerate(candidates):
                    try:
                        payload = _read_nested_member(archive, member)
                        candidate_path = Path(temporary) / f"candidate-{index:03d}.zip"
                        candidate_path.write_bytes(payload)
                        ingested = ingest_bundle(candidate_path)
                    except (
                        IngestionError,
                        InputBundleResolutionError,
                        OSError,
                        zipfile.BadZipFile,
                    ):
                        continue
                    successful.append(
                        ResolvedInputBundle(
                            path=candidate_path,
                            ingested=ingested,
                            nested_bundle=member.filename,
                        )
                    )

            if len(successful) == 1:
                yield successful[0]
                return
            if not successful:
                raise InputBundleResolutionError(
                    "selected ZIP is not a weekly input bundle and contains no "
                    "classifiable nested weekly ZIP"
                ) from direct_error
            names = ", ".join(item.nested_bundle or "<unknown>" for item in successful)
            raise InputBundleResolutionError(
                f"selected ZIP contains multiple classifiable nested weekly ZIPs "
                f"({names}); refusing to guess"
            ) from direct_error
    else:
        yield ResolvedInputBundle(path=path, ingested=direct, nested_bundle=None)
