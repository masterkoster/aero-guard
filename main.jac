# AERO-GUARD — emergency ATC decision support
# Spike: prove out the graph model + spatial queries + walker API serving.

import math;

node Airport {
    has ident: str;        # KDTW
    has name: str;         # Detroit Metropolitan Wayne County
    has kind: str;         # "large" | "medium" | "small" | "seaplane"
    has lat: float;
    has lon: float;
    has elev_ft: int = 0;

    # Great-circle distance to a point, in nautical miles (haversine).
    def distance_nm(lat2: float, lon2: float) -> float {
        r = 3440.065;  # earth radius in nm
        dlat = (lat2 - self.lat) * math.pi / 180;
        dlon = (lon2 - self.lon) * math.pi / 180;
        a = math.sin(dlat / 2) * math.sin(dlat / 2)
            + math.cos(self.lat * math.pi / 180) * math.cos(lat2 * math.pi / 180)
            * math.sin(dlon / 2) * math.sin(dlon / 2);
        return 2 * r * math.asin(math.sqrt(a));
    }
}

node Runway {
    has ident: str;        # 04L/22R
    has length_ft: int;
    has heading_deg: float;  # magnetic heading of the "low" end, reciprocal implied
    has width_ft: int = 0;
    has surface: str = "ASPH";
    has lighted: bool = False;
}

walker:pub find_long_runways {
    has min_length_ft: int = 8000;

    can start with Root entry {
        visit [root -->];
    }

    can check with Airport entry {
        # Spatial query: one bracketed path = the candidate filter.
        for rwy in [here -->][?:Runway] {
            if rwy.length_ft >= self.min_length_ft {
                report {
                    "airport": here.ident,
                    "name": here.name,
                    "runway": rwy.ident,
                    "length_ft": rwy.length_ft,
                    "hdg": rwy.heading_deg
                };
            }
        }
    }
}

with entry {
    dtw = Airport(ident="KDTW", name="Detroit Metropolitan Wayne County",
                  kind="large", lat=42.2124, lon=-83.3534, elev_ft=645);
    root ++> dtw;
    dtw ++> Runway(ident="04L/22R", length_ft=12000, heading_deg=40.0, width_ft=150, surface="ASPH", lighted=True);
    dtw ++> Runway(ident="04R/22L", length_ft=10000, heading_deg=40.0, width_ft=150, surface="ASPH", lighted=True);
    dtw ++> Runway(ident="03L/21R", length_ft=8500, heading_deg=30.0, width_ft=150, surface="ASPH", lighted=True);

    arb = Airport(ident="KARB", name="Ann Arbor Municipal", kind="small",
                  lat=42.2381, lon=-83.5311, elev_ft=840);
    root ++> arb;
    arb ++> Runway(ident="06L/24R", length_ft=6001, heading_deg=60.0, width_ft=100, surface="ASPH");
    arb ++> Runway(ident="06R/24L", length_ft=5000, heading_deg=60.0, width_ft=100, surface="ASPH");

    mkg = Airport(ident="KMKG", name="Muskegon County", kind="small",
                  lat=43.1653, lon=-86.2372, elev_ft=650);
    root ++> mkg;
    mkg ++> Runway(ident="14/32", length_ft=6101, heading_deg=140.0, width_ft=100, surface="ASPH", lighted=True);

    # Prove the haversine math + walk the graph.
    print(f"KARB is {arb.distance_nm(42.2124, -83.3534):.1f} nm from KDTW");

    result = root spawn find_long_runways(min_length_ft=8000);
    print(f"Runways >= 8000 ft found: {len(result.reports)}");
    for r in result.reports {
        print(f"  {r['airport']} {r['runway']}  {r['length_ft']} ft  hdg {r['hdg']}");
    }
}
