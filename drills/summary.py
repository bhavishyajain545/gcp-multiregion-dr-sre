"""One-line ledger summary for the drills: python3 drills/summary.py <api> [?asof=...]"""
import json, sys, urllib.request

api = sys.argv[1]
query = sys.argv[2] if len(sys.argv) > 2 else ""
try:
    with urllib.request.urlopen(api + "/ledger/summary" + query, timeout=20) as r:
        d = json.load(r)
except Exception as exc:  # the AS OF read can be refused if the timestamp is outside the retention window
    print(f"error: {exc}")
    sys.exit(1)
s, rd = d["summary"], d["read"]
print(f"accounts={s['accounts']} total_balance={s['total_balance']} transfers={s['transfers']}  ({rd['read_kind']} read @ {rd['read_timestamp']}, served by {d['region']})")
