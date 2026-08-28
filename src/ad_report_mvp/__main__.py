"""Allow ``python -m ad_report_mvp``."""

import sys

from ad_report_mvp.cli import main


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
