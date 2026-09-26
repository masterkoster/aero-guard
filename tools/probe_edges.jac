"""Probe: are the runway edges actually being created?

Run with:  jac run tools/probe_edges.jac
"""

import from src.archetypes { Airport, Runway, HasRunway }
import from src.data_loader { load_airports, airport_count, runway_count, airports_in_box }


with entry:__main__ {
    n: int = load_airports();
    print(f"airports={n}  typed-edge runway count={runway_count()}");

    apts: list[Airport] = [root -->][?:Airport];
    print(f"[root -->] gives {len(apts)} nodes");

    # Does one airport have runway neighbours?
    dtw: Airport | None = None;
    for a in apts {
        if a.ident == "KDTW" { dtw = a; }
    }
    if dtw is None {
        for a in apts {
            if a.longest_ft() > 8000 { dtw = a; break; }
        }
    }
    if dtw is not None {
        let: Airport = dtw as Airport;
        rws: list[Runway] = let.runways();
        print(f"{let.ident}: runways()={len(rws)} longest={let.longest_ft()} ft");
        for r in rws { print(f"   {r.ident} {r.length_ft} ft hdg {r.hdg_a}/{r.hdg_b} {r.surface}"); }
    } else {
        print("no airport with a long runway found");
    }

    # Alternate query shapes for the typed edge.
    typed: int = len([root->:HasRunway:->]);
    untyped: int = len([root-->[?:Runway]]);
    print(f"typed edge traversal = {typed}");
    print(f"untyped Runway filter = {untyped}");
}
