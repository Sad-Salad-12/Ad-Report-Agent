"""Public API for the deterministic advertising report data pipeline."""

from .history import HistoryError, HistoryStore, commit_report_history
from .ingest import IngestionError, ingest_bundle
from .lm_studio import (
    LMStudioConfig,
    LMStudioError,
    LMStudioResponseError,
    LMStudioUnavailableError,
    build_review_input,
    canonical_numeric_fingerprint,
    get_status as get_lm_studio_status,
    review_report,
    start_model as start_lm_studio_model,
)
from .models import (
    CanonicalReport,
    DataPipelineResult,
    ReportConfig,
    ValidationResult,
    load_report_config,
)
from .sample_catalog import (
    SampleCatalogError,
    catalog_status,
    load_catalog,
    replay_catalog,
)
from .transform import TransformationError, run_data_pipeline, transform_bundle
from .validation import ReportValidationError, validate_report
from .weekly_insights import build_cross_week_facts, generate_weekly_insights

__all__ = [
    "CanonicalReport",
    "DataPipelineResult",
    "HistoryError",
    "HistoryStore",
    "IngestionError",
    "LMStudioConfig",
    "LMStudioError",
    "LMStudioResponseError",
    "LMStudioUnavailableError",
    "ReportConfig",
    "ReportValidationError",
    "SampleCatalogError",
    "TransformationError",
    "ValidationResult",
    "commit_report_history",
    "catalog_status",
    "build_review_input",
    "build_cross_week_facts",
    "canonical_numeric_fingerprint",
    "ingest_bundle",
    "load_report_config",
    "load_catalog",
    "get_lm_studio_status",
    "generate_weekly_insights",
    "replay_catalog",
    "run_data_pipeline",
    "review_report",
    "start_lm_studio_model",
    "transform_bundle",
    "validate_report",
]
