"""Fail-closed cross-source reconciliation for canonical reports."""

from __future__ import annotations

from datetime import timedelta
from typing import Dict, Iterable, List, Optional, Sequence

from .models import (
    CanonicalReport,
    OverallMetrics,
    ReportConfig,
    ValidationIssue,
    ValidationResult,
)


class ReportValidationError(ValueError):
    def __init__(self, result: ValidationResult):
        self.result = result
        summary = "; ".join(f"{issue.code}: {issue.message}" for issue in result.errors)
        super().__init__(summary or "report validation failed")


def validate_report(
    report: CanonicalReport,
    config: ReportConfig,
    previous_overall: Optional[OverallMetrics] = None,
) -> ValidationResult:
    """Reconcile every slide data group and return machine-readable issues."""

    issues: List[ValidationIssue] = []

    def issue(severity: str, code: str, message: str, path: Optional[str] = None) -> None:
        issues.append(
            ValidationIssue(severity=severity, code=code, message=message, path=path)  # type: ignore[arg-type]
        )

    def error(code: str, message: str, path: Optional[str] = None) -> None:
        issue("ERROR", code, message, path)

    def warning(code: str, message: str, path: Optional[str] = None) -> None:
        issue("WARNING", code, message, path)

    def close(
        actual: float,
        expected: float,
        tolerance: float,
        code: str,
        path: str,
        label: str,
    ) -> None:
        # A source can legitimately differ by exactly one displayed cent because
        # daily exports are rounded before they are summed.
        if abs(actual - expected) > tolerance + 1e-9:
            error(
                code,
                f"{label} mismatch: actual={actual:.10g}, expected={expected:.10g}, tolerance={tolerance}",
                path,
            )

    if report.schema_version != config.schema_version:
        error("SCHEMA_VERSION_MISMATCH", "report schema version does not match config", "schema_version")
    if report.template_version != config.template_version:
        error(
            "TEMPLATE_VERSION_MISMATCH",
            "report template version does not match config",
            "template_version",
        )
    if report.market != config.market:
        error("MARKET_MISMATCH", "report market does not match config", "market")
    if report.period_end < report.period_start:
        error("INVALID_PERIOD", "period_end is before period_start", "period_end")
    current = report.current_overall
    if (current.period_start, current.period_end) != (report.period_start, report.period_end):
        error(
            "OVERALL_PERIOD_MISMATCH",
            "current overall period does not match report period",
            "current_overall",
        )
    if current.market != report.market:
        error("OVERALL_MARKET_MISMATCH", "current overall market does not match report", "current_overall.market")

    expected_sources = {
        "overall",
        "by_day",
        "by_product",
        "campaign",
        "creative",
        "traffic_campaign",
        "audience",
        "keyword",
    }
    actual_sources = set(report.source_files)
    if actual_sources != expected_sources:
        error(
            "SOURCE_SET_MISMATCH",
            f"source set mismatch; missing={sorted(expected_sources - actual_sources)}, "
            f"unexpected={sorted(actual_sources - expected_sources)}",
            "source_files",
        )
    for source in report.source_periods:
        if source.source_kind == "keyword":
            continue
        if (source.period_start, source.period_end) != (report.period_start, report.period_end):
            severity = "ERROR" if config.quality.fail_on_period_mismatch else "WARNING"
            issue(
                severity,
                "SOURCE_PERIOD_MISMATCH",
                f"{source.source_kind} has {source.period_start}..{source.period_end}, "
                f"expected {report.period_start}..{report.period_end}",
                f"source_periods.{source.source_kind}",
            )

    previous = report.previous_overall or previous_overall
    if config.history.required_for_comparison and previous is None:
        error(
            "MISSING_PREVIOUS_OVERALL",
            "a prior overall row is required for the comparison slide",
            "previous_overall",
        )
    if previous is not None:
        if previous.market != report.market:
            error(
                "PREVIOUS_MARKET_MISMATCH",
                "previous overall market does not match current report",
                "previous_overall.market",
            )
        expected_previous_end = report.period_start - timedelta(days=1)
        if previous.period_end != expected_previous_end:
            error(
                "HISTORY_NOT_ADJACENT",
                f"previous period ends {previous.period_end}; expected {expected_previous_end}",
                "previous_overall.period_end",
            )

    expected_days = []
    cursor = report.period_start
    while cursor <= report.period_end:
        expected_days.append(cursor)
        cursor += timedelta(days=1)
    actual_days = [item.day for item in report.daily]
    if actual_days != expected_days:
        error(
            "DAILY_DATE_COVERAGE",
            f"daily rows are not the exact contiguous period: {actual_days}",
            "daily",
        )
    close(
        sum(item.amount_spent for item in report.daily),
        current.amount_spent,
        config.quality.money_tolerance,
        "DAILY_SPEND_RECONCILIATION",
        "daily",
        "daily amount spent sum",
    )
    close(
        sum(item.purchase_value for item in report.daily),
        current.purchase_value,
        config.quality.money_tolerance,
        "DAILY_VALUE_RECONCILIATION",
        "daily",
        "daily purchase value sum",
    )
    if sum(item.purchases for item in report.daily) != current.purchases:
        error("DAILY_PURCHASE_RECONCILIATION", "daily purchases do not sum to overall", "daily")
    if sum(item.adds_to_cart for item in report.daily) != current.adds_to_cart:
        error("DAILY_ATC_RECONCILIATION", "daily adds to cart do not sum to overall", "daily")

    if current.link_clicks <= 0:
        error("INVALID_LINK_CLICKS", "overall link clicks must be positive", "current_overall.link_clicks")
    else:
        close(
            current.add_to_cart_rate,
            current.adds_to_cart / current.link_clicks * 100.0,
            config.quality.ratio_tolerance,
            "ATC_RATE_FORMULA",
            "current_overall.add_to_cart_rate",
            "overall add-to-cart rate",
        )

    configured_ids = [product.id for product in config.products]
    summary_ids = [item.product_id for item in report.product_summaries]
    analysis_ids = [item.product_id for item in report.product_analyses]
    if config.quality.require_all_three_products and len(configured_ids) != 3:
        error("CONFIG_PRODUCT_COUNT", "MVP v1 requires exactly three configured products", "products")
    if summary_ids != configured_ids:
        error(
            "PRODUCT_SUMMARY_SET",
            f"product summaries must follow config order {configured_ids}, got {summary_ids}",
            "product_summaries",
        )
    if analysis_ids != configured_ids:
        error(
            "PRODUCT_ANALYSIS_SET",
            f"product analyses must follow config order {configured_ids}, got {analysis_ids}",
            "product_analyses",
        )

    close(
        sum(item.amount_spent for item in report.product_summaries),
        current.amount_spent,
        config.quality.money_tolerance,
        "PRODUCT_SPEND_RECONCILIATION",
        "product_summaries",
        "product summary spend sum",
    )
    close(
        sum(item.purchase_value for item in report.product_summaries),
        current.purchase_value,
        config.quality.money_tolerance,
        "PRODUCT_VALUE_RECONCILIATION",
        "product_summaries",
        "product summary value sum",
    )
    if sum(item.purchases for item in report.product_summaries) != current.purchases:
        error("PRODUCT_PURCHASE_RECONCILIATION", "product purchases do not sum to overall", "product_summaries")
    if sum(item.adds_to_cart for item in report.product_summaries) != current.adds_to_cart:
        error("PRODUCT_ATC_RECONCILIATION", "product adds to cart do not sum to overall", "product_summaries")

    traffic_by_product = {item.product_id: item for item in report.traffic}
    audience_by_product = {item.product_id: item for item in report.audience}
    analysis_by_product = {item.product_id: item for item in report.product_analyses}
    if set(traffic_by_product) != set(configured_ids):
        error("TRAFFIC_PRODUCT_SET", "traffic rows do not cover configured products", "traffic")
    if set(audience_by_product) != set(configured_ids):
        error("AUDIENCE_PRODUCT_SET", "audience rows do not cover configured products", "audience")

    conversion_spend = 0.0
    traffic_spend = sum(item.amount_spent for item in report.traffic)
    total_clicks = sum(item.link_clicks for item in report.traffic)
    total_impressions = sum(item.impressions for item in report.traffic)
    for product in config.products:
        analysis = analysis_by_product.get(product.id)
        traffic = traffic_by_product.get(product.id)
        audience = audience_by_product.get(product.id)
        if analysis is None:
            continue
        campaign = analysis.campaign
        creative = analysis.creative
        conversion_spend += campaign.amount_spent
        total_clicks += campaign.link_clicks
        total_impressions += campaign.impressions
        if creative.ad_name.casefold().strip() != product.creative_pin.casefold().strip():
            error(
                "CREATIVE_PIN_MISMATCH",
                f"{product.id} selected {creative.ad_name!r}, expected {product.creative_pin!r}",
                f"product_analyses.{product.id}.creative.ad_name",
            )
        if creative.product_id != product.id or campaign.product_id != product.id:
            error(
                "PRODUCT_ID_MISMATCH",
                f"nested metrics do not match {product.id}",
                f"product_analyses.{product.id}",
            )
        if traffic is not None:
            close(
                analysis.summary.amount_spent,
                campaign.amount_spent + traffic.amount_spent,
                config.quality.money_tolerance,
                "PRODUCT_SPEND_COMPONENTS",
                f"product_analyses.{product.id}.summary.amount_spent",
                f"{product.id} total spend",
            )
        if audience is not None:
            close(
                audience.amount_spent,
                campaign.amount_spent,
                config.quality.money_tolerance,
                "AUDIENCE_CAMPAIGN_SPEND",
                f"audience.{product.id}.amount_spent",
                f"{product.id} audience/campaign spend",
            )
            close(
                audience.purchase_value,
                campaign.purchase_value,
                config.quality.money_tolerance,
                "AUDIENCE_CAMPAIGN_VALUE",
                f"audience.{product.id}.purchase_value",
                f"{product.id} audience/campaign purchase value",
            )
            if audience.purchases != campaign.purchases or audience.adds_to_cart != campaign.adds_to_cart:
                error(
                    "AUDIENCE_CAMPAIGN_COUNTS",
                    f"{product.id} audience counts do not equal campaign counts",
                    f"audience.{product.id}",
                )
        if analysis.summary.purchases != campaign.purchases or analysis.summary.adds_to_cart != campaign.adds_to_cart:
            error(
                "SUMMARY_CAMPAIGN_COUNTS",
                f"{product.id} product summary counts do not equal conversion campaign",
                f"product_analyses.{product.id}.summary",
            )
        close(
            analysis.summary.purchase_value,
            campaign.purchase_value,
            config.quality.money_tolerance,
            "SUMMARY_CAMPAIGN_VALUE",
            f"product_analyses.{product.id}.summary.purchase_value",
            f"{product.id} summary/campaign value",
        )
        if config.quality.fail_on_missing_creative_metric:
            for field in (
                "amount_spent",
                "cpm",
                "cpc",
                "ctr",
                "cost_per_add_to_cart",
                "cost_per_purchase",
                "purchase_roas",
                "average_purchase_value",
            ):
                if getattr(creative, field) < 0:
                    error(
                        "INVALID_CREATIVE_METRIC",
                        f"{product.id} creative {field} cannot be negative",
                        f"product_analyses.{product.id}.creative.{field}",
                    )

    close(
        conversion_spend + traffic_spend,
        current.amount_spent,
        config.quality.money_tolerance,
        "CAMPAIGN_TRAFFIC_SPEND_RECONCILIATION",
        "product_analyses",
        "conversion campaign plus traffic spend",
    )
    if total_clicks != current.link_clicks:
        error(
            "CLICK_RECONCILIATION",
            f"campaign+traffic clicks {total_clicks} do not equal overall {current.link_clicks}",
            "current_overall.link_clicks",
        )
    if total_impressions > 0:
        close(
            current.ctr,
            total_clicks / total_impressions * 100.0,
            config.quality.ratio_tolerance,
            "CTR_RECONCILIATION",
            "current_overall.ctr",
            "overall CTR",
        )

    if len(report.keywords) != config.keyword_top_n:
        error(
            "KEYWORD_COUNT",
            f"expected {config.keyword_top_n} keywords, got {len(report.keywords)}",
            "keywords",
        )
    conversions = [item.conversions for item in report.keywords]
    if conversions != sorted(conversions, reverse=True):
        error("KEYWORD_ORDER", "keywords are not ordered by conversions descending", "keywords")
    if [item.rank for item in report.keywords] != list(range(1, len(report.keywords) + 1)):
        error("KEYWORD_RANK", "keyword ranks are not contiguous from one", "keywords")

    expected_lineage = {
        *(f"current_overall.{field}" for field in type(current).model_fields if field != "market"),
        *(
            f"daily.{index}.{field}"
            for index, item in enumerate(report.daily)
            for field in type(item).model_fields
        ),
        *(
            f"product_summaries.{index}.{field}"
            for index, item in enumerate(report.product_summaries)
            for field in type(item).model_fields
            if field not in {"product_id", "display_name"}
        ),
        *(
            f"product_analyses.{index}.campaign.{field}"
            for index, item in enumerate(report.product_analyses)
            for field in type(item.campaign).model_fields
            if field != "product_id"
        ),
        *(
            f"product_analyses.{index}.creative.{field}"
            for index, item in enumerate(report.product_analyses)
            for field in type(item.creative).model_fields
            if field != "product_id"
        ),
        *(
            f"traffic.{index}.{field}"
            for index, item in enumerate(report.traffic)
            for field in type(item).model_fields
            if field != "product_id"
        ),
        *(
            f"audience.{index}.{field}"
            for index, item in enumerate(report.audience)
            for field in type(item).model_fields
            if field != "product_id"
        ),
        *(
            f"keywords.{index}.{field}"
            for index, item in enumerate(report.keywords)
            for field in type(item).model_fields
            if field != "rank"
        ),
    }
    if previous is not None:
        expected_lineage.update(
            f"previous_overall.{field}"
            for field in type(previous).model_fields
            if field != "market"
        )
    actual_lineage = {entry.target for entry in report.lineage}
    missing_lineage = sorted(expected_lineage - actual_lineage)
    if missing_lineage:
        error(
            "MISSING_LINEAGE",
            f"missing lineage for {len(missing_lineage)} fields: {missing_lineage[:10]}",
            "lineage",
        )
    duplicate_targets = sorted(
        target
        for target in actual_lineage
        if sum(1 for entry in report.lineage if entry.target == target) > 1
    )
    if duplicate_targets:
        warning(
            "DUPLICATE_LINEAGE_TARGET",
            f"multiple lineage records exist for {duplicate_targets[:10]}",
            "lineage",
        )

    return ValidationResult(
        passed=not any(item.severity == "ERROR" for item in issues),
        issues=issues,
    )
