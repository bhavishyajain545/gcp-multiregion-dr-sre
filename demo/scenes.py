"""Demo video for Project 6: multi-region DR with Spanner.

Prerequisites:
  * platform deployed (`./deploy.sh`), accounts seeded, drills work by hand
  * Chrome started with --remote-debugging-port=9222 and signed in to the Cloud console
  * DEMO_EXTRA_PATH with gcloud and ffmpeg; WSL has gcloud/terraform/python3
  * optional DEMO_CI_URL: a finished GitHub Actions run to show

  python -u demo/scenes.py

Rule: nothing slow runs inside a scene. Every command runs BEFORE its scene (the drills take 1-2 minutes each)
and the scene types the commands and pastes the captured output, paced over the narration. Waiting between
scenes is cut by the recorder.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import subprocess
import time
from pathlib import Path

from recorder import Demo

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
PROJECT = "bj-multiregion-dr"
CDP_URL = os.environ.get("DEMO_CDP_URL", "http://127.0.0.1:9222")
CI_URL = os.environ.get("DEMO_CI_URL", "")

for p in os.environ.get("DEMO_EXTRA_PATH", "").split(os.pathsep):
    if p:
        os.environ["PATH"] = p + os.pathsep + os.environ["PATH"]
os.chdir(ROOT)


def wsl(cmd: str, timeout: int = 300) -> str:
    root = "/mnt/" + ROOT.drive[0].lower() + ROOT.as_posix()[2:]
    full = f"source ~/.gcp-env.sh; cd {root}; {cmd}"
    try:
        r = subprocess.run(["wsl", "-e", "bash", "-c", full], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout)
        return (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return "(timed out)"


def cdp_available() -> bool:
    import urllib.request
    try:
        with urllib.request.urlopen(CDP_URL + "/json/version", timeout=2):
            return True
    except Exception:
        return False


async def type_cmd(page, cmd: str, type_delay: int = 7, chunk: int = 4) -> None:
    await page.evaluate("(c) => window.__prompt(c)", "")
    for i in range(0, len(cmd), chunk):
        await page.evaluate("(c) => window.__type(c)", cmd[i:i + chunk])
        await asyncio.sleep(type_delay * chunk / 1000)


def capture_steps(steps) -> list[tuple[str, str]]:
    return [(cmd, (producer() if callable(producer) else producer)) for cmd, producer in steps]


async def precapture(steps) -> list[tuple[str, str]]:
    return await asyncio.to_thread(capture_steps, steps)


async def replay(page, steps, spread: float, type_delay: int = 5, hold: float = 2.0) -> None:
    n = max(len(steps), 1)
    pause = max(0.4, min(3.0, spread / n / 2))
    for cmd, out in steps:
        await type_cmd(page, cmd, type_delay)
        await asyncio.sleep(pause)
        await page.evaluate("(o) => window.__output(o)", out)
        await asyncio.sleep(pause)
    await asyncio.sleep(hold)


async def console_ready(tab, text: str, reload: bool = True) -> None:
    try:
        if reload:
            await tab.reload(wait_until="commit")
        await tab.wait_for_selector(f"text={text}", timeout=60000)
        await asyncio.sleep(2.5)
    except Exception as exc:
        print(f"  ! console tab not ready ({text}): {type(exc).__name__}")


def retry_nonempty(producer, tries: int = 3) -> str:
    out = ""
    for _ in range(tries):
        out = producer()
        if out.strip():
            return out
    return out or "(no output)"


def trim(s: str, n: int = 1800) -> str:
    return s if len(s) <= n else s[:n] + "\n…"


def squeeze_timeline(out: str, keep_before: int = 4, keep_after: int = 4) -> str:
    """The outage drill prints ~90 one-per-second lines; keep the header, the window around the 5xx burst, and the verdict."""
    lines = out.splitlines()
    tl = [i for i, l in enumerate(lines) if re.match(r"^\d\d:\d\d:\d\d  ok=", l)]
    if not tl:
        return trim(out, 2200)
    err = [i for i in tl if not re.search(r"err=0 ", lines[i])]
    if err:
        a, b = max(tl[0], err[0] - keep_before), min(tl[-1], err[-1] + keep_after)
    else:
        a, b = tl[0], min(tl[-1], tl[0] + 10)
    head = [l for l in lines[:tl[0]] if l.strip()]
    window = lines[a:b + 1]
    if a > tl[0]:
        window = [f"   … {a - tl[0]} quiet seconds …"] + window
    if b < tl[-1]:
        window = window + [f"   … {tl[-1] - b} quiet seconds (all ok) …"]
    tail = [l for l in lines[tl[-1] + 1:] if l.strip()]
    return "\n".join(head + window + tail)


NARRATION = {
    "arch": (
        "This project is about losing a region on purpose and measuring what it costs. The same Go service, a small money-transfer ledger, runs in two regions on Cloud Run, "
        "Northern Virginia and South Carolina, behind one anycast IP on the global load balancer. Underneath there is one multi-region Cloud Spanner database: "
        "both regions hold a synchronously committed read-write replica and a witness in a third region breaks ties. "
        "So a regional outage changes where requests are served, never what the ledger says: the recovery point is zero by construction, "
        "and the recovery time is the load balancer's outlier detection evicting the dead region, which we measure rather than estimate. "
        "Transfers are serializable Spanner transactions keyed by a client idempotency key, reads come strong, stale or as of a past timestamp, "
        "and everything is Terraform with a keyless pipeline that rolls one region at a time."
    ),
    "edge": (
        "One IP, two regions, one ledger. Every response carries the region that served it; from where I am, the load balancer picks the nearest healthy one, "
        "and both regions answer the same question with the same numbers. Calling each region's Cloud Run URL directly shows the two deployments are identical, "
        "down to the revision, and the ledger summary is the invariant we will keep checking: twenty accounts, twenty thousand in total."
    ),
    "load": (
        "Consistency under concurrency. Twenty workers fire keyed transfers through the edge for twenty seconds; some land in one region, some in the other, "
        "and all of them are serializable transactions on the same database. Afterwards the total balance is exactly what it was and the transfer count grew by exactly "
        "the number of successful requests. Money moved, none was created, none was lost, with two regions writing at once."
    ),
    "reads": (
        "Three ways to read, and one way to retry. A strong read goes to the leader and returns the freshest value. A bounded-stale read is allowed to be up to fifteen seconds old "
        "and is served by the nearest replica, which is what a dashboard should use. And a transfer retried with the same idempotency key, say after a failover cut the first "
        "response off, comes back as a duplicate: nothing moves twice."
    ),
    "spanner": (
        "The database in the console: instance configuration nam3, Enterprise Plus, a hundred processing units, which is a tenth of a node and plenty for this. "
        "Two read-write replicas, one per serving region, plus the witness. The default leader sits in Northern Virginia; we will move it later with a single statement."
    ),
    "outage": (
        "Drill one: a region goes dark. A probe hits the edge four times a second and a writer commits one keyed transfer per second. Then I flip the outage switch on "
        "Northern Virginia, so every request there answers five-oh-three. The edge fails for a few seconds, outlier detection ejects the region, and South Carolina takes all of it. "
        "That window is the measured recovery time. Then the region heals and traffic flows back. The recovery point: every keyed write is in the ledger exactly once and the total "
        "balance did not move. That is what one database under two regions buys you."
    ),
    "leader": (
        "Drill two: where do writes commit? Spanner keeps the leader replicas in one region, and a write from the other region pays a cross-region round trip. "
        "Write latency from each region, then one DDL statement moves the default leader to South Carolina, and the numbers swap. "
        "In a real failover Spanner elects a new leader on its own within seconds; this is the dial for when you want to choose."
    ),
    "timetravel": (
        "Drill three is the one replication cannot save you from. An operator runs an update that zeroes every balance, and the replicas faithfully copy the mistake in milliseconds. "
        "Spanner's version history does what replication cannot: a read as of a timestamp before the mistake still shows the right ledger, and the restore endpoint writes that "
        "state back in a single commit. Seconds, not a backup restore; the daily backup schedule stays as the second line."
    ),
    "observe": (
        "The dashboard splits the edge by serving region: requests and five-hundreds per region, p95 per region, Cloud Run instances, Spanner CPU and API latency. "
        "The outage shows up as a short burst of errors in one region and the other region's line taking the load. The SLOs are measured at the edge, the way a user would: "
        "ninety-nine point nine percent non-five-hundred, and ninety-five percent under five hundred milliseconds, each with burn-rate alerts and an uptime check from three continents."
    ),
    "ci": (
        "Delivery is keyless and region-aware: GitHub Actions tests, builds, pushes by digest, and rolls that digest to South Carolina first, then Northern Virginia, one at a time, "
        "so a bad build can never take both regions down in the same minute. Terraform owns everything around the revisions and deliberately ignores the image and the outage knob."
    ),
    "wrap": (
        "Everything shown is in the repository: the Go service with its three read modes and idempotent transfers, Terraform for Spanner, Cloud Run, the global load balancer with its "
        "eviction policy, SLOs, alerts and dashboard, the three drill scripts, the load generator and the keyless workflow. The only idle cost is the Spanner instance, and the teardown "
        "script removes it all. Thanks for watching."
    ),
}


async def main() -> None:
    use_cdp = cdp_available()
    demo = Demo(out_dir=HERE, cdp_url=CDP_URL if use_cdp else None, max_silence=5.0, tail=4.0)
    await demo.prepare(*NARRATION.values())
    alen = {k: (await demo._tts(v))[1] for k, v in NARRATION.items()}

    t0 = time.time()
    api = wsl("terraform -chdir=terraform output -raw api")
    urls = json.loads(wsl("terraform -chdir=terraform output -json run_urls") or "{}")
    dash_url = wsl("terraform -chdir=terraform output -raw dashboard_url")
    slo_url = wsl("terraform -chdir=terraform output -raw slo_url")
    spanner_url = f"https://console.cloud.google.com/spanner/instances/ledger/details/databases?project={PROJECT}"
    print(f"pre-computed in {time.time() - t0:.0f}s; api={api}")

    page = await demo.start()
    spanner_tab = dash_tab = slo_tab = ci_tab = None
    if use_cdp:
        spanner_tab = await demo.new_tab(spanner_url)
        dash_tab = await demo.new_tab(dash_url)
        slo_tab = await demo.new_tab(slo_url)
        if CI_URL:
            ci_tab = await demo.new_tab(CI_URL)
        await demo.capture(page)

    # ---- 1 architecture ----
    async def s1():
        await page.bring_to_front()
        await page.goto((ROOT / "docs" / "architecture.html").as_uri(), wait_until="commit")
        await page.wait_for_selector(".canvas", timeout=15000)
        width = 0.0
        for _ in range(6):
            width = await page.evaluate(
                "() => { if (!document.getElementById('demo-still')) { const st = document.createElement('style'); st.id = 'demo-still'; st.textContent = '*{animation:none!important}'; document.head.appendChild(st); }"
                " document.body.style.zoom = '1.33'; document.body.style.margin = '0';"
                " return document.querySelector('.canvas').getBoundingClientRect().width; }")
            if width > 1800:
                break
            await asyncio.sleep(0.5)
        print(f"  architecture canvas width after zoom: {width:.0f}px")
    await demo.scene("Architecture", NARRATION["arch"], s1)

    # ---- 2 one IP, two regions ----
    steps2 = await precapture([
        ("curl -s $API/version", lambda: wsl(f"curl -s {api}/version")),
        ("for i in $(seq 1 10); do curl -s -o /dev/null -D - $API/healthz | grep -i x-served-by-region; done | sort | uniq -c",
         lambda: wsl(f"for i in $(seq 1 10); do curl -s -o /dev/null -D - {api}/healthz | grep -i x-served-by-region | tr -d '\\r'; done | sort | uniq -c")),
        ("for R in us-east4 us-east1; do curl -s -w ' (%{time_total}s)\\n' $(terraform output -raw run_url_$R)/version; done",
         lambda: wsl(" ; ".join(f"curl -s -w ' ({r}: %{{time_total}}s)\\n' {u}/version" for r, u in urls.items()))),
        ("curl -s $API/ledger/summary", lambda: wsl(f"curl -s {api}/ledger/summary")),
    ])
    await demo.terminal("One IP, two regions, one ledger", [])
    await asyncio.sleep(0.8)

    async def s2():
        await replay(page, steps2, spread=alen["edge"] * 0.6)
    await demo.scene("One IP two regions", NARRATION["edge"], s2, hold=1.0)

    # ---- 3 concurrency ----
    steps3 = await precapture([
        ("python3 loadgen/load.py $API --workers 20 --seconds 20",
         lambda: retry_nonempty(lambda: wsl(f"python3 loadgen/load.py {api} --workers 20 --seconds 20 2>&1", timeout=180))),
    ])
    await demo.terminal("Consistency under concurrency: 20 workers, two regions, one invariant", [])
    await asyncio.sleep(0.8)

    async def s3():
        await replay(page, steps3, spread=4.0, hold=3.0)
    await demo.scene("Concurrency", NARRATION["load"], s3, hold=1.0)

    # ---- 4 reads + idempotency ----
    key = f"demo-{int(time.time())}"
    steps4 = await precapture([
        ("curl -s $API/accounts/acc-000   # strong", lambda: wsl(f"curl -s {api}/accounts/acc-000")),
        ("curl -s '$API/accounts/acc-000?staleness=15s'   # bounded-stale, nearest replica", lambda: wsl(f"curl -s '{api}/accounts/acc-000?staleness=15s'")),
        (f"curl -s -X POST $API/transfers -d '{{\"key\":\"{key}\",\"from\":\"acc-000\",\"to\":\"acc-001\",\"amount\":25}}'",
         lambda: wsl(f"curl -s -X POST {api}/transfers -H 'content-type: application/json' -d '{{\"key\":\"{key}\",\"from\":\"acc-000\",\"to\":\"acc-001\",\"amount\":25}}'")),
        (f"curl -s -X POST $API/transfers -d '{{\"key\":\"{key}\",…}}'   # the retry after a failover",
         lambda: wsl(f"curl -s -X POST {api}/transfers -H 'content-type: application/json' -d '{{\"key\":\"{key}\",\"from\":\"acc-000\",\"to\":\"acc-001\",\"amount\":25}}'")),
        ("curl -s $API/accounts/acc-000 | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"account\"][\"balance\"])'",
         lambda: wsl(f"curl -s {api}/accounts/acc-000 | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"account\"][\"balance\"])'")),
    ])
    await demo.terminal("Strong, stale and idempotent", [])
    await asyncio.sleep(0.8)

    async def s4():
        await replay(page, steps4, spread=alen["reads"] * 0.6)
    await demo.scene("Reads and idempotency", NARRATION["reads"], s4, hold=1.0)

    # ---- 5 Spanner console ----
    if use_cdp:
        await console_ready(spanner_tab, "nam3")

        async def s5():
            await demo.capture(spanner_tab)
        await demo.scene("Spanner", NARRATION["spanner"], s5, hold=1.5)
        await demo.capture(page)

    # ---- 6 drill 1: region outage (runs now, ~2 min) ----
    steps6 = await precapture([
        ("drills/region-outage.sh us-east4 90", lambda: squeeze_timeline(wsl("drills/region-outage.sh us-east4 90 2>&1", timeout=400))),
    ])
    await demo.terminal("Drill 1: Northern Virginia goes dark (OUTAGE=1) while a probe and a writer run", [])
    await asyncio.sleep(0.8)

    async def s6():
        await replay(page, steps6, spread=4.0, hold=3.0)
    await demo.scene("Region outage drill", NARRATION["outage"], s6, hold=1.5)

    # ---- 7 drill 2: leader ----
    steps7 = await precapture([
        ("drills/leader.sh us-east1", lambda: wsl("drills/leader.sh us-east1 2>&1", timeout=300)),
    ])
    await demo.terminal("Drill 2: move the write leader with one DDL statement", [])
    await asyncio.sleep(0.8)

    async def s7():
        await replay(page, steps7, spread=4.0, hold=3.0)
    await demo.scene("Leader drill", NARRATION["leader"], s7, hold=1.0)

    # ---- 8 drill 3: time travel ----
    steps8 = await precapture([
        ("drills/time-travel.sh", lambda: wsl("drills/time-travel.sh 2>&1", timeout=300)),
    ])
    await demo.terminal("Drill 3: a bad UPDATE, undone from Spanner's version history", [])
    await asyncio.sleep(0.8)

    async def s8():
        await replay(page, steps8, spread=4.0, hold=3.0)
    await demo.scene("Time travel drill", NARRATION["timetravel"], s8, hold=1.0)
    # leader back to us-east4 for the next run (outside any scene)
    asyncio.ensure_future(asyncio.to_thread(wsl, "drills/leader.sh us-east4 >/dev/null 2>&1; true", 300))

    # ---- 9 dashboard + SLOs ----
    if use_cdp:
        await console_ready(dash_tab, "Requests/s")
        await console_ready(slo_tab, "non-5xx")

        async def s9():
            await demo.capture(dash_tab)
            await asyncio.sleep(alen["observe"] * 0.6)
            await demo.capture(slo_tab)
        await demo.scene("Dashboard and SLOs", NARRATION["observe"], s9, hold=1.5)
        await demo.capture(page)

    # ---- 10 CI ----
    if use_cdp and ci_tab is not None:
        await console_ready(ci_tab, "release", reload=False)

        async def s10():
            await demo.capture(ci_tab)
        await demo.scene("Keyless CI", NARRATION["ci"], s10, hold=1.0)
        await demo.capture(page)
    else:
        steps10 = await precapture([
            ("gcloud run revisions list --service ledger-api --region us-east1 --format='table(name,active,creationTimestamp.date())' --limit 3",
             lambda: wsl(f"gcloud run revisions list --service ledger-api --region us-east1 --project {PROJECT} --format='table(name,active,creationTimestamp.date())' --limit 3 2>&1")),
            ("sed -n '1,12p' .github/workflows/release.yml", lambda: wsl("sed -n '1,12p' .github/workflows/release.yml")),
        ])
        await demo.terminal("Keyless CI: the same digest to both regions, one at a time", [])
        await asyncio.sleep(0.8)

        async def s10():
            await replay(page, steps10, spread=alen["ci"] * 0.5)
        await demo.scene("Keyless CI", NARRATION["ci"], s10, hold=1.0)

    # ---- 11 wrap ----
    steps11 = await precapture([
        ("terraform -chdir=terraform state list | wc -l", lambda: wsl("terraform -chdir=terraform state list | wc -l")),
        ("terraform -chdir=terraform output", lambda: wsl("terraform -chdir=terraform output -no-color | grep -v admin_token")),
        ("# when done: ./teardown.sh", "terraform destroy → Spanner / Cloud Run / bucket leftovers → destroy again → billing audit"),
    ])
    await demo.terminal("Infrastructure as code + cleanup", [])
    await asyncio.sleep(0.8)

    async def s11():
        await replay(page, steps11, spread=alen["wrap"] * 0.5)
    await demo.scene("Wrap-up", NARRATION["wrap"], s11, hold=1.5)

    await demo.finish("demo")


if __name__ == "__main__":
    asyncio.run(main())
