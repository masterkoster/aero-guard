"""AERO-GUARD graph schema — the airspace as a topology.

Airport nodes carry their Runway nodes over a typed edge, so the candidate
filter in the decision engine is a single spatial query over the graph rather
than a table scan:

    [root-->[?:Airport, lat > 41.0, lat < 44.0]][?:Runway, length_ft >= 6000]
"""

import math;
import from src.physics { Wind, wind_components, gc_nm }


obj RunwayEnd {
    has hdg: float = 0.0;            # approach heading, degrees true
    has headwind_kt: float = 0.0;
    has crosswind_kt: float = 0.0;
    has ident: str = "";
}


node Runway {
    has ident: str;                  # "04L/22R"
    has length_ft: int;
    has hdg_a: float;                # heading of end A
    has hdg_b: float;                # heading of end B (reciprocal)
    has surface: str = "ASPH";
    has lighted: bool = False;

    def is_paved() -> bool {
        # OurAirports surface codes, with a condition suffix: ASP/ASPH-G,
        # CON/CONC-E, PEM (PEMEX concrete), COP/COM (composite). Grass and dirt
        # fields (GRS, GRE, TURF, DIRT, SAND, SNOW, ICE, WAT) do not.
        paved: list[str] = ["ASP", "CON", "PEM", "COP", "COM"];
        s: str = self.surface.upper();
        for prefix in paved {
            if s.startswith(prefix) { return True; }
        }
        return False;
    }

    # The into-wind end for a given surface wind.
    def best_end(wind: Wind) -> RunwayEnd {
        ca: list[float] = wind_components(wind, self.hdg_a);
        cb: list[float] = wind_components(wind, self.hdg_b);
        if ca[0] >= cb[0] {
            return RunwayEnd(hdg=self.hdg_a, headwind_kt=ca[0],
                             crosswind_kt=ca[1], ident=self.ident);
        }
        return RunwayEnd(hdg=self.hdg_b, headwind_kt=cb[0],
                         crosswind_kt=cb[1], ident=self.ident);
    }
}


node Airport {
    has ident: str;                  # KDTW / KDNN
    has name: str;
    has kind: str = "small";         # large | medium | small | seaplane
    has lat: float = 0.0;
    has lon: float = 0.0;
    has elev_ft: int = 0;
    has ctry: str = "";
    has mun: str = "";
    has sched: bool = False;
    has iata: str = "";

    def distance_nm(lat2: float, lon2: float) -> float {
        # Great-circle distance to a point, nautical miles.
        return gc_nm(self.lat, self.lon, lat2, lon2);
    }

    def runways() -> list[Runway] {
        found: list[Runway] = [self -->][?:Runway];
        return found;
    }

    def longest_ft() -> int {
        best: int = 0;
        rws: list[Runway] = self.runways();
        for r in rws {
            if r.length_ft > best { best = r.length_ft; }
        }
        return best;
    }

    # A runway long enough for this aircraft, preferring into-wind ends.
    def pick_runway(min_ft: int, wind: Wind) -> Runway | None {
        best: Runway | None = None;
        best_score: float = -999.0;
        rws: list[Runway] = self.runways();
        for r in rws {
            if r.length_ft < min_ft { continue; }
            e: RunwayEnd = r.best_end(wind);
            score: float = (float(r.length_ft) / 1000.0)
                           + e.headwind_kt
                           - (math.fabs(e.crosswind_kt) * 1.5);
            if not r.is_paved() { score = score - 3.0; }
            if not e.ident { score = score - 0.1; }
            if score > best_score {
                best_score = score;
                best = r;
            }
        }
        return best;
    }

    # Every runway that could accept an aircraft needing min_ft.
    def runways_over(min_ft: int) -> list[Runway] {
        out: list[Runway] = [];
        rws: list[Runway] = self.runways();
        for r in rws {
            if r.length_ft >= min_ft { out.append(r); }
        }
        return out;
    }
}


# Typed edge: the runway is a facility OF the airport, so the graph states the
# relationship instead of implying it through node adjacency.
edge HasRunway: Airport --> Runway {
    has usable: bool = True;
}
