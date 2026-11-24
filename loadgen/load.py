"""Concurrent keyed transfers against the edge, then the invariant check.

    python3 loadgen/load.py http://<lb-ip> --workers 20 --seconds 30 --accounts 20

Prints status histogram, latency p50/p95, requests by serving region, and the ledger summary before/after:
total_balance must be identical (money moves, it is never created), transfers must grow by the 201 count.
"""
import argparse, json, random, statistics, sys, threading, time, urllib.request, urllib.error
from collections import Counter

ap = argparse.ArgumentParser()
ap.add_argument("api")
ap.add_argument("--workers", type=int, default=20)
ap.add_argument("--seconds", type=int, default=30)
ap.add_argument("--accounts", type=int, default=20)
ap.add_argument("--amount", type=int, default=3)
a = ap.parse_args()

codes, regions, lats = Counter(), Counter(), []
lock = threading.Lock()


def summary():
    with urllib.request.urlopen(a.api + "/ledger/summary", timeout=15) as r:
        return json.load(r)["summary"]


def worker(wid: int):
    rnd = random.Random(wid)
    end = time.time() + a.seconds
    n = 0
    while time.time() < end:
        n += 1
        src = rnd.randrange(a.accounts)
        dst = (src + rnd.randrange(1, a.accounts)) % a.accounts
        body = json.dumps({"key": f"load-{int(end)}-{wid}-{n}", "from": f"acc-{src:03d}", "to": f"acc-{dst:03d}", "amount": a.amount}).encode()
        req = urllib.request.Request(a.api + "/transfers", data=body, headers={"content-type": "application/json"}, method="POST")
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                code, reg = r.status, r.headers.get("X-Served-By-Region", "-")
        except urllib.error.HTTPError as e:
            code, reg = e.code, e.headers.get("X-Served-By-Region", "-")
        except Exception:
            code, reg = 0, "-"
        dt = (time.time() - t0) * 1000
        with lock:
            codes[code] += 1
            regions[reg] += 1
            lats.append(dt)


before = summary()
print(f"before: {before}")
threads = [threading.Thread(target=worker, args=(i,), daemon=True) for i in range(a.workers)]
t0 = time.time()
for t in threads:
    t.start()
for t in threads:
    t.join()
elapsed = time.time() - t0
after = summary()
total = sum(codes.values())
lats.sort()
p = lambda q: lats[min(len(lats) - 1, int(q * len(lats)))] if lats else 0
print(f"requests: {total} in {elapsed:.0f}s = {total / elapsed:.1f} rps  codes: {dict(sorted(codes.items()))}")
print(f"served by region: {dict(regions)}")
print(f"latency ms: p50={p(0.5):.0f} p95={p(0.95):.0f} p99={p(0.99):.0f} max={lats[-1] if lats else 0:.0f}")
print(f"after:  {after}")
ok = after["total_balance"] == before["total_balance"] and after["transfers"] - before["transfers"] == codes.get(201, 0)
print("INVARIANT OK: total_balance unchanged, transfers grew by exactly the 201 count" if ok else "INVARIANT BROKEN")
sys.exit(0 if ok else 1)
