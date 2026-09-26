#!/usr/bin/env python3
"""AERO-GUARD data prep: OurAirports CSVs -> filtered airports.json.

Filters the global OurAirports dataset down to a demo region with usable runways,
emitting a compact JSON consumed by src/data_loader.jac at graph build time.

Usage:
    python3 scripts/prep_airports.py [--bbox MINLON MINLAT MAXLON MAXLAT]
                                    [--min-runway-ft N] [--out PATH] [--all]
    --all builds the full globe (no bbox filter).
"""

import argparse
import csv
import json
import os
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RAW = os.path.join(ROOT, "data", "raw")

# Demo default: Great Lakes region (covers DTW, Michigan, Chicago, Toronto, etc.)
DEFAULT_BBOX = (-98.0, 38.0, -70.0, 52.0)  # min_lon, min_lat, max_lon, max_lat

# Airport types we can land on (exclude 'closed' and 'heliport')
KEEP_TYPES = {"small_airport", "medium_airport", "large_airport", "seaplane_base"}

# Runway surfaces we treat as landable pavement/compared at runtime; keep all, tag surface
SURFACE_OK = {"ASPH", "ASPH-G", "ASPH-F", "CONC", "CONC-G", "ASPH-CONC", "GRVL", "TURF", "GRAS", "GRASS"}


def fnum(value, default=0.0):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def inum(value, default=0):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def load_airports(bbox, keep_all):
    min_lon, min_lat, max_lon, max_lat = bbox
    airports = {}
    path = os.path.join(RAW, "airports.csv")
    with open(path, newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            if row["type"] not in KEEP_TYPES:
                continue
            lat = fnum(row["latitude_deg"])
            lon = fnum(row["longitude_deg"])
            if not keep_all and not (min_lat <= lat <= max_lat and min_lon <= lon <= max_lon):
                continue
            airports[row["id"]] = {
                "id": row["id"],
                "ident": row["ident"],
                "type": row["type"],
                "name": row["name"],
                "lat": lat,
                "lon": lon,
                "elev_ft": inum(row["elevation_ft"]),
                "ctry": row["iso_country"],
                "mun": row["municipality"],
                "sched": row["scheduled_service"] == "yes",
                "iata": row.get("iata_code") or "",
            }
    return airports


def attach_runways(airports, min_runway_ft):
    path = os.path.join(RAW, "runways.csv")
    with open(path, newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            ref = row["airport_ref"]
            if ref not in airports:
                continue
            if row["closed"] == "1":
                continue
            length_ft = inum(row["length_ft"])
            if length_ft < min_runway_ft:
                continue
            surface = (row["surface"] or "").strip()
            ends = []
            for prefix in ("le", "he"):
                ident = row.get(f"{prefix}_ident") or ""
                hdg = row.get(f"{prefix}_heading_degT") or ""
                if not ident or not hdg:
                    continue
                ends.append({
                    "id": ident,
                    "hdg": fnum(hdg),
                    "lat": fnum(row.get(f"{prefix}_latitude_deg"), airports[ref]["lat"]),
                    "lon": fnum(row.get(f"{prefix}_longitude_deg"), airports[ref]["lon"]),
                    "elev_ft": inum(row.get(f"{prefix}_elevation_ft"), airports[ref]["elev_ft"]),
                })
            if not ends:
                continue
            airports[ref].setdefault("runways", []).append({
                "len_ft": length_ft,
                "surface": surface,
                "lighted": row["lighted"] == "1",
                "ends": ends,
            })


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bbox", nargs=4, type=float, metavar=("MINLON", "MINLAT", "MAXLON", "MAXLAT"),
                    default=DEFAULT_BBOX)
    ap.add_argument("--min-runway-ft", type=int, default=3000)
    ap.add_argument("--out", default=os.path.join(ROOT, "data", "airports.json"))
    ap.add_argument("--all", action="store_true", help="no bbox filter (full globe)")
    args = ap.parse_args()

    print(f"[1/3] loading airports (bbox={None if args.all else args.bbox}) ...")
    airports = load_airports(args.bbox, keep_all=args.all)
    print(f"      {len(airports)} airports in region")

    print(f"[2/3] attaching runways >= {args.min_runway_ft} ft ...")
    attach_runways(airports, args.min_runway_ft)

    # Drop airports with no qualifying runway
    out_airports = [a for a in airports.values() if a.get("runways")]
    out_airports.sort(key=lambda a: a["ident"])

    types = Counter(a["type"] for a in out_airports)
    n_rwys = sum(len(a["runways"]) for a in out_airports)
    longest = max((r["len_ft"] for a in out_airports for r in a["runways"]), default=0)

    print(f"[3/3] writing {len(out_airports)} airports ({n_rwys} runways) -> {args.out}")
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump({"airports": out_airports}, fh, separators=(",", ":"))
    size_mb = os.path.getsize(args.out) / 1e6
    print(f"""
Done. Stats:
  airports kept : {len(out_airports)}
  by type       : {dict(types)}
  runways       : {n_rwys} (longest {longest} ft)
  output size   : {size_mb:.1f} MB
""")


if __name__ == "__main__":
    sys.exit(main())
