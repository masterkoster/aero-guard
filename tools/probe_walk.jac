"""Probe: why does the advisor return no report when it visits airports?

Mirrors the advisor's consider/deliver steps with prints, plus tests the
query shapes and disengage behaviour.

Run with:  jac run tools/probe_walk.jac
"""

import math;
import from src.archetypes { Airport, Runway, RunwayEnd, HasRunway }
import from src.data_loader { load_airports, airport_count }
import from src.physics { Wind, spec_for, profile_for, required_landing_ft, gc_nm,
                          glide_range_nm, glide_time_min, drift_nm, offset_nm, r0, r1 }


walker DebugAdvisor {
    has lat: float = 42.9;
    has lon: float = -84.9;
    has alt_ft: int = 35000;
    has failures: list[str] = ["ENGINE_OUT_ALL"];
    has wind_dir_deg: float = 250.0;
    has wind_kt: float = 22.0;
    has seen: int = 0;
    has hits: int = 0;
    has usable: list[dict[str, any]] = [];
    has need_ft: int = 0;
    has wind: Wind = Wind();
    has use_disengage: bool = True;

    can plan with Root entry {
        self.wind = Wind(dir_deg=self.wind_dir_deg, speed_kt=self.wind_kt);
        spec = spec_for("B738");
        prof = profile_for(self.failures, spec, 0.0);
        self.need_ft = required_landing_ft(spec, prof, False, 12.0);
        radius = glide_range_nm(float(self.alt_ft), prof.ld_ratio);
        mins = glide_time_min(float(self.alt_ft), prof.glide_kt, prof.ld_ratio);
        drift = drift_nm(self.wind, mins);
        c = offset_nm(self.lat, self.lon, self.wind.toward_deg(), drift);
        clat = c[0];
        clon = c[1];
        search = radius * 1.35 + 10.0;
        min_lat = clat - search / 60.0;
        max_lat = clat + search / 60.0;
        mid = (min_lat + max_lat) / 2.0;
        dlon = search / (60.0 * math.cos(math.radians(mid)));
        print(f"[plan] need={self.need_ft} ft radius={radius:.1f} nm center=({clat:.3f},{clon:.3f})");
        print(f"[plan] bbox lat {min_lat:.3f}..{max_lat:.3f} lon {clon - dlon:.3f}..{clon + dlon:.3f}");
        visit [root-->[?:Airport, lat > min_lat, lat < max_lat,
                       lon > clon - dlon, lon > clon - dlon]];
    }

    can consider with Airport entry {
        self.seen = self.seen + 1;
        if self.seen == 1 { print(f"[consider] first node {here.ident}"); }
        d = gc_nm(self.lat, self.lon, here.lat, here.lon);
        rwy = here.pick_runway(self.need_ft, self.wind);
        if rwy is None {
            disengage;
        }
        self.hits = self.hits + 1;
        chosen = rwy as Runway;
        end = chosen.best_end(self.wind);
        self.usable.append({"ident": here.ident, "dist": r1(d), "rwy": chosen.ident,
                            "len": chosen.length_ft, "hw": r1(end.headwind_kt),
                            "xw": r1(end.crosswind_kt)});
        if self.use_disengage { disengage; }
    }

    can deliver with Root exit {
        print(f"[deliver] seen={self.seen} with-runway={self.hits} usable={len(self.usable)}");
        report {"seen": self.seen, "hits": self.hits, "usable": self.usable};
    }
}


# Same walker, no disengage at all.
walker DebugAdvisorNoDisengage {
    has lat: float = 42.9;
    has lon: float = -84.9;
    has alt_ft: int = 35000;
    has failures: list[str] = ["ENGINE_OUT_ALL"];
    has wind_dir_deg: float = 250.0;
    has wind_kt: float = 22.0;
    has seen: int = 0;
    has hits: int = 0;
    has need_ft: int = 0;
    has wind: Wind = Wind();
    has box: list[float] = [];

    can plan with Root entry {
        self.wind = Wind(dir_deg=self.wind_dir_deg, speed_kt=self.wind_kt);
        spec = spec_for("B738");
        prof = profile_for(self.failures, spec, 0.0);
        self.need_ft = required_landing_ft(spec, prof, False, 12.0);
        radius = glide_range_nm(float(self.alt_ft), prof.ld_ratio);
        mins = glide_time_min(float(self.alt_ft), prof.glide_kt, prof.ld_ratio);
        drift = drift_nm(self.wind, mins);
        c = offset_nm(self.lat, self.lon, self.wind.toward_deg(), drift);
        clat = c[0];
        clon = c[1];
        search = radius * 1.35 + 10.0;
        min_lat = clat - search / 60.0;
        max_lat = clat + search / 60.0;
        mid = (min_lat + max_lat) / 2.0;
        dlon = search / (60.0 * math.cos(math.radians(mid)));
        self.box = [min_lat, max_lat, clon - dlon, clon + dlon];
        print(f"[plan2] bbox lat {min_lat:.3f}..{max_lat:.3f} lon {clon - dlon:.3f}..{clon + dlon:.3f}");
        visit [root-->[?:Airport, lat > min_lat, lat < max_lat,
                       lon > clon - dlon, lon < clon + dlon]];
    }

    can consider with Airport entry {
        self.seen = self.seen + 1;
        rwy = here.pick_runway(self.need_ft, self.wind);
        if rwy is not None { self.hits = self.hits + 1; }
    }

    can deliver with Root exit {
        print(f"[deliver2] seen={self.seen} with-runway={self.hits}");
        report {"seen": self.seen, "hits": self.hits};
    }
}


with entry:__main__ {
    load_airports();

    # query shapes
    two_hop: int = len([root --> -->]);
    nested: int = len([root-->[?:Airport]-->]);
    print(f"[q] [root --> -->] = {two_hop}");
    print(f"[q] [root-->[?:Airport]-->] = {nested}");

    # disengage semantics
    w1 = root spawn DebugAdvisor();
    print(f"[walker-with-disengage] reports={len(w1.reports)}");
    for r in w1.reports { print(f"   seen={r['seen']} hits={r['hits']}"); }

    w2 = root spawn DebugAdvisorNoDisengage();
    print(f"[walker-no-disengage] reports={len(w2.reports)}");
    for r in w2.reports { print(f"   seen={r['seen']} hits={r['hits']}"); }
}
