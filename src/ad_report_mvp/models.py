"""Canonical, serialisable models for the deterministic report pipeline."""

from __future__ import annotations

from datetime import date
from pathlib import Path
from typing import Any, Dict, List, Literal, Optional

from pydantic import BaseModel, ConfigDict, Field, model_validator


class CanonicalModel(BaseModel):
    """Strict base model shared by config, input, output, and validation data."""

    model_config = ConfigDict(extra="forbid", validate_assignment=True)


class ProductConfig(CanonicalModel):
    id: str
    display_name: str
    aliases: List[str]
    creative_pin: str
    creative_asset: Optional[str] = None


class HistoryConfig(CanonicalModel):
    database: str = "history/report_history.sqlite3"
    seed_file: Optional[str] = None
    required_for_comparison: bool = True


class QualityConfig(CanonicalModel):
    money_tolerance: float = 0.01
    ratio_tolerance: float = 0.01
    require_all_three_products: bool = True
    fail_on_missing_creative_metric: bool = True
    fail_on_period_mismatch: bool = True


class ReportConfig(CanonicalModel):
    schema_version: str = "1.0.0"
    template_version: str
    market: str
    country_label: str
    currency: str
    report_title: str
    keyword_top_n: int = Field(default=8, ge=1, le=100)
    products: List[ProductConfig]
    history: HistoryConfig = Field(default_factory=HistoryConfig)
    quality: QualityConfig = Field(default_factory=QualityConfig)

    @model_validator(mode="after")
    def _unique_products(self) -> "ReportConfig":
        ids = [product.id for product in self.products]
        pins = [product.creative_pin.casefold().strip() for product in self.products]
        if len(ids) != len(set(ids)):
            raise ValueError("product ids must be unique")
        if len(pins) != len(set(pins)):
            raise ValueError("creative_pin values must be unique")
        return self


class SourceCellRef(CanonicalModel):
    source_kind: Literal["bundle", "history_db", "history_seed", "formula"]
    file: str
    sheet: Optional[str] = None
    row: Optional[int] = None
    column: Optional[int] = None
    cell: Optional[str] = None
    header: Optional[str] = None
    raw_value: Any = None


class LineageEntry(CanonicalModel):
    target: str
    transform: str = "identity"
    sources: List[SourceCellRef]


class SourceRow(CanonicalModel):
    row_number: int
    values: Dict[str, Any]


SourceKind = Literal[
    "overall",
    "by_day",
    "by_product",
    "campaign",
    "creative",
    "traffic_campaign",
    "audience",
    "keyword",
]


class SourceTable(CanonicalModel):
    kind: SourceKind
    file_name: str
    sheet_name: str
    header_row_number: int
    headers: List[str]
    rows: List[SourceRow]
    period_start: Optional[date] = None
    period_end: Optional[date] = None


class IngestedBundle(CanonicalModel):
    bundle_path: str
    bundle_sha256: str
    tables: Dict[str, SourceTable]


class OverallMetrics(CanonicalModel):
    market: str
    period_start: date
    period_end: date
    amount_spent: float
    purchase_value: float
    purchase_roas: float
    purchases: int
    adds_to_cart: int
    cost_per_purchase: float
    cost_per_add_to_cart: float
    link_clicks: int
    ctr: float
    add_to_cart_rate: float


class DailyMetrics(CanonicalModel):
    day: date
    adds_to_cart: int
    purchases: int
    purchase_roas: float
    amount_spent: float
    purchase_value: float


class ProductSummary(CanonicalModel):
    product_id: str
    display_name: str
    campaign_name: str
    adds_to_cart: int
    purchases: int
    purchase_roas: float
    average_purchase_value: float
    purchase_value: float
    amount_spent: float


class CampaignMetrics(CanonicalModel):
    product_id: str
    campaign_name: str
    amount_spent: float
    purchase_value: float
    purchase_roas: float
    purchases: int
    adds_to_cart: int
    cost_per_purchase: float
    cost_per_add_to_cart: float
    purchase_rate: float
    add_to_cart_rate: float
    impressions: int
    link_clicks: int
    ctr: float
    cpm: float
    cpc: float
    average_purchase_value: float


class CreativeMetrics(CanonicalModel):
    product_id: str
    ad_name: str
    campaign_name: str
    amount_spent: float
    cpm: float
    cpc: float
    ctr: float
    cost_per_add_to_cart: float
    cost_per_purchase: float
    purchase_roas: float
    average_purchase_value: float
    adds_to_cart: int
    purchases: int


class ProductAnalysis(CanonicalModel):
    product_id: str
    display_name: str
    creative_asset: Optional[str] = None
    summary: ProductSummary
    campaign: CampaignMetrics
    creative: CreativeMetrics


class TrafficMetrics(CanonicalModel):
    product_id: str
    campaign_name: str
    amount_spent: float
    purchases: Optional[int] = None
    adds_to_cart: Optional[int] = None
    impressions: int
    link_clicks: int
    ctr: float
    cpm: float
    cpc: float
    landing_page_views: int
    cost_per_landing_page_view: float
    landing_page_view_rate: float


class AudienceMetrics(CanonicalModel):
    product_id: str
    ad_set_name: str
    adds_to_cart: int
    purchases: int
    purchase_roas: float
    purchase_value: float
    amount_spent: float


class KeywordMetrics(CanonicalModel):
    rank: int
    keyword: str
    conversions: float
    conversion_value_per_cost: float
    cost: float
    conversion_value: float


class SourcePeriod(CanonicalModel):
    source_kind: str
    file_name: str
    period_start: Optional[date]
    period_end: Optional[date]


class CanonicalReport(CanonicalModel):
    schema_version: str
    template_version: str
    market: str
    country_label: str
    currency: str
    report_title: str
    period_start: date
    period_end: date
    source_bundle_sha256: str
    source_files: Dict[str, str]
    source_periods: List[SourcePeriod]
    current_overall: OverallMetrics
    previous_overall: Optional[OverallMetrics] = None
    daily: List[DailyMetrics]
    product_summaries: List[ProductSummary]
    product_analyses: List[ProductAnalysis]
    traffic: List[TrafficMetrics]
    audience: List[AudienceMetrics]
    keywords: List[KeywordMetrics]
    lineage: List[LineageEntry]


class ValidationIssue(CanonicalModel):
    severity: Literal["ERROR", "WARNING", "INFO"]
    code: str
    message: str
    path: Optional[str] = None


class ValidationResult(CanonicalModel):
    passed: bool
    issues: List[ValidationIssue] = Field(default_factory=list)

    @property
    def errors(self) -> List[ValidationIssue]:
        return [issue for issue in self.issues if issue.severity == "ERROR"]

    def raise_for_errors(self) -> None:
        if not self.passed:
            from .validation import ReportValidationError

            raise ReportValidationError(self)


class DataPipelineResult(CanonicalModel):
    report: CanonicalReport
    validation: ValidationResult
    previous_overall: Optional[OverallMetrics] = None


class HistoryRecord(CanonicalModel):
    overall: OverallMetrics
    source_kind: Literal["history_db", "history_seed"]
    source_file: str


def load_report_config(path: str | Path) -> ReportConfig:
    """Load and strictly validate a JSON report configuration."""

    return ReportConfig.model_validate_json(Path(path).read_text(encoding="utf-8"))
