#!/usr/bin/env bash
#
# scripts/cost-snapshot.sh
#
# Prints a snapshot of month-to-date Azure cost across the MCA billing
# profile, grouped by subscription. Stop-gap until platform/20-management
# lands the proper cost exports + budget-alerts-per-sub.
#
# Usage:
#   source ~/.keystone/secrets.env
#   ./scripts/cost-snapshot.sh
#
# Requirements:
#   - `az` CLI ≥ 2.45 (uses `az rest` against the Cost Management REST
#     API; no extension required — the `costmanagement` extension only
#     covers exports, not on-demand query).
#   - `python3` (used for JSON parsing).
#   - Cost Management Reader (or higher) on the MCA billing profile.
#     If you're MCA admin you already have it.
#
# Note: cost data has a documented refresh lag — Microsoft says "actuals
# are usually updated within 8–24 hours." So this snapshot is "yesterday's
# cost or earlier", not real-time. The portal's Cost Analysis view has
# the same lag.

set -euo pipefail

if [[ -z "${KEYSTONE_MCA_BILLING_PROFILE_ID:-}" ]]; then
  echo "ERROR: KEYSTONE_MCA_BILLING_PROFILE_ID not set." >&2
  echo "       Run: source ~/.keystone/secrets.env" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not installed." >&2
  exit 1
fi

month_start="$(date -u +%Y-%m-01)"
today="$(date -u +%Y-%m-%d)"

echo "=== Keystone cost snapshot ==="
echo "Scope:    <MCA billing profile> (id redacted)"
echo "Window:   ${month_start} → ${today} (month-to-date, UTC)"
echo

# Cost Management REST API query at the billing-profile scope.
#   ActualCost  = already-billed/used (excludes projected future cost).
#   MonthToDate = the date window we want.
# Grouping by SubscriptionName surfaces per-sub totals.
url="https://management.azure.com${KEYSTONE_MCA_BILLING_PROFILE_ID}/providers/Microsoft.CostManagement/query?api-version=2023-11-01"

# `aggregation.totalCost` is what makes the API return an actual cost
# column. Without it, the response is just dimension values (grouping
# without a measure). The label "Cost" here is what shows up as the
# column name in the response.
body='{
  "type": "ActualCost",
  "timeframe": "MonthToDate",
  "dataset": {
    "granularity": "None",
    "aggregation": {
      "totalCost": {
        "name": "Cost",
        "function": "Sum"
      }
    },
    "grouping": [
      { "type": "Dimension", "name": "SubscriptionName" }
    ]
  }
}'

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

az rest --method post --url "$url" --body "$body" --output json > "$tmp" 2>/dev/null

if [[ ! -s "$tmp" ]]; then
  echo "No cost data returned. Either:" >&2
  echo "  - no spend so far this month (likely for a fresh tenant), OR" >&2
  echo "  - you don't have Cost Management Reader on the billing profile." >&2
  exit 0
fi

# Parse via python3. The heredoc is single-quote-delimited so bash does
# no expansion; the temp-file path is passed in argv[1].
python3 - "$tmp" <<'PY'
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

props = data.get("properties", {})
columns = props.get("columns", [])
rows = props.get("rows", [])

if not rows:
    print("No rows returned (no spend recorded yet for this period).")
    sys.exit(0)

# Build a column-name → index map so we don't depend on positional order
# (the API has been observed to return Cost/Currency in different
# orders depending on aggregation shape).
idx = {col["name"]: i for i, col in enumerate(columns)}

def get(row, name, default=None):
    return row[idx[name]] if name in idx else default

# Sort by cost descending.
rows.sort(key=lambda r: -float(get(r, "Cost", 0)))

header = "Subscription"
print(f"{header:<40} {'Cost':>12}  Currency")
print(f"{'-' * 40} {'-' * 12}  --------")

total = 0.0
currency = ""
for row in rows:
    cost = float(get(row, "Cost", 0))
    name = str(get(row, "SubscriptionName", "(unknown)"))
    currency = str(get(row, "Currency", ""))
    total += cost
    print(f"{name:<40} {cost:>12.2f}  {currency}")

print()
print(f"{'TOTAL':<40} {total:>12.2f}  {currency}")
PY
