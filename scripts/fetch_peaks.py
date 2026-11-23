#!/usr/bin/env python3
"""Downloads named places from OpenStreetMap via the Overpass API and writes
the offline files bundled in the app (one per kind):

    osmId \t lat \t lon \t ele \t name

    peaks     natural=peak
    passes    mountain_pass=yes
    skiareas  landuse=winter_sports (ways/relations, centre point)

Usage: fetch_peaks.py <out.tsv> [peaks|passes|skiareas]
Used by CI before building the app. Area: Alps and Italian Apennines.
Data © OpenStreetMap contributors, ODbL.
"""
import sys
import time
import urllib.parse
import urllib.request

ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
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


DEADLINE = time.time() + 18 * 60  # keep the CI job short (per kind)


SELECTORS = {
    "peaks": 'node["natural"="peak"]["name"]({b});out;',
    "passes": 'node["mountain_pass"="yes"]["name"]({b});out;',
    "skiareas": '(way["landuse"="winter_sports"]["name"]({b});relation["landuse"="winter_sports"]["name"]({b}););out center;',
}
KIND = "peaks"


def query(tile):
    s, w, n, e = tile
    sel = SELECTORS[KIND].replace("{b}", f"{s},{w},{n},{e}")
    q = f'[out:csv(::type,::id,::lat,::lon,ele,name;false;"\\t")][timeout:180];{sel}'

    body = urllib.parse.urlencode({"data": q}).encode()
    last = None
    for attempt in range(2):
        for ep in ENDPOINTS:
            if time.time() > DEADLINE:
                raise RuntimeError(f"tile {tile}: deadline reached")
            try:
                req = urllib.request.Request(ep, data=body, headers={"User-Agent": "cresta-build/1.0"})
                with urllib.request.urlopen(req, timeout=75) as r:
                    return r.read().decode("utf-8")
            except Exception as ex:  # noqa: BLE001
                last = ex
                print(f"{ep} {tile}: {ex}", file=sys.stderr)
                time.sleep(5)
    raise RuntimeError(f"tile {tile} failed: {last}")


def write(path, rows):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(rows[k] for k in sorted(rows, key=int)) + "\n")


def main(out_path):
    """Writes <out>.partial after every tile (so a CI timeout still leaves
    data to bundle) and <out> only when every tile succeeded (only complete
    files are cached by the workflow)."""
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
            if len(f) == 6 and f[5].strip() and f[2] and f[3]:
                # ways and relations get distinct ids from nodes (offset)
                oid = int(f[1]) + {"node": 0, "way": 10**12, "relation": 2 * 10**12}.get(f[0], 0)
                rows[str(oid)] = "\t".join([str(oid)] + [x.replace("\n", " ").strip() for x in f[2:]])
        print(f"tile {t}: total {len(rows)}", file=sys.stderr)
        if rows:
            write(out_path + ".partial", rows)
        time.sleep(2)
    if not rows:
        print("nothing downloaded", file=sys.stderr)
        return 1
    if failed:
        print(f"partial: {len(rows)} places, {failed} tiles failed", file=sys.stderr)
        return 1
    write(out_path, rows)
    print(f"wrote {len(rows)} places", file=sys.stderr)
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 2:
        KIND = sys.argv[2]
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "peaks.tsv"))
