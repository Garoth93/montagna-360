#!/usr/bin/env python3
"""Downloads named peaks (natural=peak) from OpenStreetMap via the Overpass
API and writes the offline file bundled in the app:

    osmId \t lat \t lon \t ele \t name

Used by CI before building the .ipa. Area: Alps and Italian Apennines.
Data © OpenStreetMap contributors, ODbL.
"""
import sys
import time
import urllib.parse
import urllib.request

ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
]
# (south, west, north, east) tiles; small enough for Overpass timeouts.
TILES = [
    (43.5, 5.0, 45.0, 8.0), (45.0, 5.0, 46.5, 8.0), (46.5, 5.0, 48.0, 8.0),
    (43.5, 8.0, 45.0, 11.0), (45.0, 8.0, 46.5, 11.0), (46.5, 8.0, 48.0, 11.0),
    (45.0, 11.0, 46.5, 14.0), (46.5, 11.0, 48.0, 14.0), (45.0, 14.0, 48.0, 17.0),
    (41.0, 11.0, 43.5, 15.5), (43.5, 10.0, 45.0, 13.5), (37.5, 13.0, 41.0, 17.0),
    (38.5, 8.0, 41.5, 10.0),
]


DEADLINE = time.time() + 18 * 60  # keep the CI job short


def query(tile):
    s, w, n, e = tile
    q = (f'[out:csv(::id,::lat,::lon,ele,name;false;"\\t")][timeout:180];'
         f'node["natural"="peak"]["name"]({s},{w},{n},{e});out;')
    body = urllib.parse.urlencode({"data": q}).encode()
    last = None
    for attempt in range(2):
        for ep in ENDPOINTS:
            if time.time() > DEADLINE:
                raise RuntimeError(f"tile {tile}: deadline reached")
            try:
                req = urllib.request.Request(ep, data=body, headers={"User-Agent": "cresta-build/1.0"})
                with urllib.request.urlopen(req, timeout=150) as r:
                    return r.read().decode("utf-8")
            except Exception as ex:  # noqa: BLE001
                last = ex
                print(f"{ep} {tile}: {ex}", file=sys.stderr)
                time.sleep(5)
    raise RuntimeError(f"tile {tile} failed: {last}")


def main(out_path):
    rows = {}
    failed = 0
    for t in TILES:
        try:
            text = query(t)
        except RuntimeError as ex:
            print(ex, file=sys.stderr)
            failed += 1
            continue
        for line in text.splitlines():
            f = line.split("\t")
            if len(f) == 5 and f[4].strip():
                rows[f[0]] = "\t".join(x.replace("\n", " ").strip() for x in f)
        print(f"tile {t}: total {len(rows)}", file=sys.stderr)
        time.sleep(2)
    if not rows:
        print("no peaks downloaded", file=sys.stderr)
        return 1
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(rows[k] for k in sorted(rows, key=int)) + "\n")
    print(f"wrote {len(rows)} peaks ({failed} tiles failed)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "peaks.tsv"))
