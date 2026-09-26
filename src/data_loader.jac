"""Load the filtered OurAirports dataset into the graph.

Idempotent: `jac` persists graph state in .jac/, so we check the graph itself
before loading instead of trusting a process-local flag (a server restart would
otherwise duplicate every node).
"""

import json;
import os;
import from src.archetypes { Airport, Runway, HasRunway }


# --- typed accessors for the untyped JSON boundary -------------------------
# json.loads() hands back `any`; these narrow it once, in one place, so the
# rest of the loader stays strictly typed.

def as_str(v: any) -> str { return v as str; }
def as_flt(v: any) -> float { return v as float; }
def as_int(v: any) -> int { return v as int; }
def as_bool(v: any) -> bool { return v as bool; }


def kind_of(v: any) -> str {
    # OurAirports type -> AERO-GUARD facility class.
    t: str = as_str(v);
    if t == "large_airport" { return "large"; }
    if t == "medium_airport" { return "medium"; }
    if t == "seaplane_base" { return "seaplane"; }
    if t == "heliport" { return "heliport"; }
    return "small";
}


def pad_dir(hdg: float) -> str {
    # 41.7 -> "22" (runway designators are magnetic/10, rounded to nearest 10).
    d: int = int(round((hdg % 360.0) / 10.0)) % 36;
    if d == 0 { d = 36; }
    if d < 10 { return "0" + str(d); }
    return str(d);
}


def data_path() -> str {
    # Locate data/airports.json relative to the project root.
    env: str = os.environ.get("AERO_DATA", "");
    if env { return env; }
    candidates: list[str] = ["data/airports.json", "../data/airports.json",
                             "../../data/airports.json"];
    for candidate in candidates {
        if os.path.exists(candidate) { return candidate; }
    }
    return "data/airports.json";
}


def read_json(path: str) -> dict[str, any] {
    fh = open(path);
    raw: str = fh.read();
    fh.close();
    return json.loads(raw) as dict[str, any];
}


def airports_loaded() -> bool {
    return len([root -->][?:Airport]) > 0;
}


def airport_count() -> int {
    return len([root -->][?:Airport]);
}


def runway_count() -> int {
    # Two hops: root -> Airport -> Runway, filtering the first hop.
    return len([root-->[?:Airport]-->]);
}


def load_airports() -> int {
    # Build Airport/Runway nodes from the dataset. Returns airports in the graph.
    if airports_loaded() { return airport_count(); }

    payload: dict[str, any] = read_json(data_path());
    rows: list[any] = payload["airports"] as list[any];

    count: int = 0;
    for row in rows {
        apt: Airport = Airport(ident=as_str(row["ident"]), name=as_str(row["name"]),
                               kind=kind_of(row["type"]), lat=as_flt(row["lat"]),
                               lon=as_flt(row["lon"]), elev_ft=as_int(row["elev_ft"]),
                               ctry=as_str(row["ctry"]), mun=as_str(row["mun"]),
                               sched=as_bool(row["sched"]), iata=as_str(row["iata"]));
        root ++> apt;

        for rw in row["runways"] {
            ends: list[any] = rw["ends"] as list[any];
            hdg_a: float = as_flt(ends[0]["hdg"]);
            hdg_b: float = hdg_a + 180.0;
            end_a_id: str = as_str(ends[0]["id"]);
            ident: str = end_a_id + "/" + pad_dir(hdg_a + 180.0);
            if len(ends) > 1 {
                hdg_b = as_flt(ends[1]["hdg"]);
                ident = end_a_id + "/" + as_str(ends[1]["id"]);
            }
            rwy: Runway = Runway(ident=ident, length_ft=as_int(rw["len_ft"]),
                                hdg_a=hdg_a, hdg_b=hdg_b, surface=as_str(rw["surface"]),
                                lighted=as_bool(rw["lighted"]));
            apt +>:HasRunway:+> rwy;
        }
        count = count + 1;
    }
    return count;
}


def airports_in_box(min_lat: float, max_lat: float, min_lon: float, max_lon: float) -> list[Airport] {
    # A spatial query, not a table scan: the bbox is a graph predicate.
    found: list[Airport] = [root-->[?:Airport, lat > min_lat, lat < max_lat,
                                       lon > min_lon, lon < max_lon]];
    return found;
}
