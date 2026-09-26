"""AERO-GUARD emergency decision engine.

`EmergencyAdvisor` is a walker over the airport graph. The decision procedure
*is* the traversal:

  1. `plan`     — read the failure list, build a performance profile, compute
                  the reachable envelope (a drift circle), and enqueue every
                  airport inside the envelope's bounding box with a spatial
                  query.
  2. `consider` — one ability per airport: pick a runway against the landing
                  gate, compute headwind/crosswind, score it, and stash the
                  candidate. No reports here — the traversal is the filter.
  3. `deliver`  — runs on Root exit, i.e. after every queued airport has been
                  considered. Sorts the accumulated candidates, applies the
                  hard gates, and reports one ranked advisory bundle.

The accumulate-then-deliver split is deliberate: the answer depends on the whole
candidate set (ranking, fallbacks, ditch-vs-field choice), so nothing is
reported until the traversal finishes.
"""

import math;
import from src.archetypes { Airport, Runway, RunwayEnd, HasRunway }
import from src.physics { AircraftSpec, PerformanceProfile, Wind, spec_for, profile_for,
                          glide_range_nm, glide_time_min, drift_nm, offset_nm, gc_nm,
                          turn_radius_nm, turn_altitude_loss_ft, required_landing_ft,
                          wind_components, density_altitude_ft, r0, r1, r2 }


# How far outside the glide circle we still look for a *better* field. Some
# controllers would rather glide past the nearest field than accept a marginal
# runway, so candidates out to this factor are scored and gated, not ignored.
glob SEARCH_FACTOR: float = 1.35;

# Ocean fallback: if nothing on land is usable, where is the best place to ditch?
glob DITCH_LEEWARD_KT: float = 6.0;


def bearing_deg(lat1: float, lon1: float, lat2: float, lon2: float) -> float {
    # Initial great-circle bearing, degrees true.
    p1: float = math.radians(lat1);
    p2: float = math.radians(lat2);
    dl: float = math.radians(lon2 - lon1);
    y: float = math.sin(dl) * math.cos(p2);
    x: float = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
    return (math.degrees(math.atan2(y, x)) + 360.0) % 360.0;
}


def polygon(lat: float, lon: float, radius_nm: float, points: int = 36) -> list[list[float]] {
    # The glide envelope: a circle of `radius_nm` around (lat, lon).
    out: list[list[float]] = [];
    for i in range(points) {
        brg: float = float(i) * 360.0 / float(points);
        p: list[float] = offset_nm(lat, lon, brg, radius_nm);
        out.append([p[0], p[1]]);
    }
    return out;
}


def format_brief(callsign: str, kind: str, ident: str, name: str, dist_nm: float,
                 brg: float, rwy: str, rwy_ft: int, hdg: float, headwind: float,
                 crosswind: float, need_ft: int, margin_ft: int, score: float,
                 why: str) -> dict[str, any] {
    # One advisory row, shaped for the console.
    return {
        "callsign": callsign,
        "kind": kind,
        "ident": ident,
        "name": name,
        "dist_nm": r1(dist_nm),
        "bearing_deg": r0(brg),
        "runway": rwy,
        "runway_ft": rwy_ft,
        "runway_hdg": r0(hdg),
        "headwind_kt": r1(headwind),
        "crosswind_kt": r1(crosswind),
        "runway_needed_ft": need_ft,
        "margin_ft": margin_ft,
        "score": r2(score),
        "why": why
    };
}


walker EmergencyAdvisor {
    # --- situation ------------------------------------------------------
    has callsign: str = "AERO-GUARD SIM";
    has aircraft_type: str = "A320";
    has lat: float = 42.9;
    has lon: float = -84.9;
    has alt_ft: int = 35000;
    has tas_kt: float = 280.0;
    has track_deg: float = 90.0;
    has failures: list[str] = ["ENGINE_OUT_ALL"];
    has fuel_min: float = 0.0;
    has wind_dir_deg: float = 270.0;
    has wind_kt: float = 25.0;
    has wind_alt_dir_deg: float = 270.0;
    has wind_alt_kt: float = 45.0;
    has temp_c: float = 18.0;
    has precip: bool = False;
    has ceiling_ft: int = 12000;
    has max_candidates: int = 6;

    # --- derived state (filled during the traversal) --------------------
    has spec: AircraftSpec = AircraftSpec();
    has profile: PerformanceProfile = PerformanceProfile();
    has wind: Wind = Wind();
    has radius_nm: float = 0.0;
    has flight_min: float = 0.0;
    has center_lat: float = 0.0;
    has center_lon: float = 0.0;
    has need_ft: int = 0;
    has seen: int = 0;
    has usable: list[dict[str, any]] = [];
    has rejected: list[dict[str, any]] = [];

    # --- 1. plan --------------------------------------------------------
    can plan with Root entry {
        self.spec = spec_for(self.aircraft_type);
        self.profile = profile_for(self.failures, self.spec, self.fuel_min);
        self.wind = Wind(dir_deg=self.wind_dir_deg, speed_kt=self.wind_kt);

        # Height above the ground we can actually glide from. A ceiling caps
        # what you can *see*, not how high you can glide from: the aircraft
        # descends through the cloud layer on the way to the field. Only the
        # drift-down ceiling genuinely limits altitude.
        agl: float = float(self.alt_ft);
        if self.profile.mode == "driftdown" and self.profile.driftdown_ft > 0 {
            if agl > float(self.profile.driftdown_ft) {
                agl = float(self.profile.driftdown_ft);
            }
        }
        if agl < 500.0 { agl = 500.0; }

        self.radius_nm = glide_range_nm(agl, self.profile.ld_ratio);
        self.flight_min = glide_time_min(agl, self.profile.glide_kt, self.profile.ld_ratio);

        # The air mass carries the aircraft downwind for the whole glide: the
        # reachable set is a circle of `radius_nm` centred downwind, not on the
        # aircraft. This is what makes the envelope asymmetric.
        drift: float = drift_nm(self.wind, self.flight_min);
        drift_pt: list[float] = offset_nm(self.lat, self.lon,
                                          self.wind.toward_deg(), drift);
        self.center_lat = drift_pt[0];
        self.center_lon = drift_pt[1];

        # Baseline gate (dry, no crosswind). `consider` recomputes it per runway
        # with that runway's actual crosswind before accepting a field.
        self.need_ft = required_landing_ft(self.spec, self.profile, self.precip, 0.0);

        # Candidate filter as a spatial query over the graph. The bbox is the
        # search circle plus margin; the runway gate is applied per airport in
        # `consider`.
        search: float = self.radius_nm * SEARCH_FACTOR + 10.0;
        min_lat: float = self.center_lat - (search / 60.0);
        max_lat: float = self.center_lat + (search / 60.0);
        mid_lat: float = (min_lat + max_lat) / 2.0;
        dlon: float = search / (60.0 * math.cos(math.radians(mid_lat)));
        min_lon: float = self.center_lon - dlon;
        max_lon: float = self.center_lon + dlon;

        visit [root-->[?:Airport, lat > min_lat, lat < max_lat,
                       lon > min_lon, lon < max_lon]];
    }

    # Record why an airport is not a candidate. Kept out of `consider` so the
    # gate logic there reads as a list of rules, not a list of appends.
    def reject(apt: Airport, dist: float, reason: str) {
        self.rejected.append({
            "ident": apt.ident,
            "name": apt.name,
            "dist_nm": r1(dist),
            "reason": reason
        });
    }

    # --- 2. consider, one ability per airport ---------------------------
    can consider with Airport entry {
        self.seen = self.seen + 1;

        # Distance from the *drifted* envelope centre, which is what the glide
        # circle is actually centred on.
        dist: float = gc_nm(self.center_lat, self.center_lon, here.lat, here.lon);
        dist_from_ac: float = gc_nm(self.lat, self.lon, here.lat, here.lon);

        # Outside the search circle entirely: not even worth a gate check.
        if dist > self.radius_nm * SEARCH_FACTOR { return; }

        # Gate 1: a runway long enough for the landing distance.
        rwy: Runway | None = here.pick_runway(self.need_ft, self.wind);
        if rwy is None {
            self.reject(here, dist,
                        f"longest runway {here.longest_ft()} ft < {self.need_ft} ft required");
            return;
        }
        chosen: Runway = rwy as Runway;
        end: RunwayEnd = chosen.best_end(self.wind);
        cross: float = math.fabs(end.crosswind_kt);

        # Gate 2: crosswind within the type's demonstrated limit.
        if cross > self.spec.crosswind_limit_kt {
            self.reject(here, dist,
                        f"crosswind {r0(cross)} kt exceeds {r0(self.spec.crosswind_limit_kt)} kt limit");
            return;
        }

        # Gate 3: on a deadstick glide the aircraft cannot reach past the
        # circle even with a tailwind component. Drift-down and endurance
        # profiles have time to keep going, so the gate only bites in glide.
        if self.profile.mode == "glide" and dist_from_ac > self.radius_nm {
            self.reject(here, dist, "beyond the glide circle (all engines out)");
            return;
        }

        # Gate 4: exact landing distance for *this* runway's crosswind, not the
        # baseline gate. A 20 kt crosswind can push a field over the line.
        need_here: int = required_landing_ft(self.spec, self.profile, self.precip, cross);
        if chosen.length_ft < need_here {
            self.reject(here, dist,
                        f"{chosen.ident} {chosen.length_ft} ft < {need_here} ft needed "
                        + f"with {r0(cross)} kt crosswind");
            return;
        }

        margin: int = chosen.length_ft - need_here;
        brg: float = bearing_deg(self.lat, self.lon, here.lat, here.lon);

        # --- scoring ----------------------------------------------------
        # Lower is better. Range pressure dominates, then the landing gate,
        # then field quality, then how much into-wind we will be.
        range_pressure: float = dist / self.radius_nm;
        margin_bonus: float = min(float(margin) / 2000.0, 2.0);
        surface_bonus: float = 0.0;
        if chosen.is_paved() { surface_bonus = 1.0; }
        if chosen.lighted { surface_bonus = surface_bonus + 0.3; }
        kind_bonus: float = 0.0;
        if here.kind == "large" { kind_bonus = 0.8; }
        elif here.kind == "medium" { kind_bonus = 0.5; }
        headwind_bonus: float = min(end.headwind_kt / 20.0, 1.0);
        cross_penalty: float = cross / 10.0;
        if self.precip { cross_penalty = cross_penalty + 0.5; }
        da: int = density_altitude_ft(here.elev_ft, self.temp_c);
        da_penalty: float = float(da) / 4000.0;
        turn_penalty: float = turn_radius_nm(self.profile.glide_kt,
                                             self.profile.bank_limit_deg) * 0.5;

        score: float = range_pressure * 4.0
                       + cross_penalty
                       + da_penalty
                       + turn_penalty
                       - margin_bonus
                       - surface_bonus
                       - kind_bonus
                       - headwind_bonus;

        why: str = f"{chosen.length_ft} ft vs {need_here} ft needed"
                   + f"; {end.headwind_kt:.0f} kt headwind, {cross:.0f} kt crosswind";
        if not chosen.is_paved() { why = why + "; unpaved surface"; }
        if self.precip { why = why + "; wet runway penalty applied"; }
        if da > here.elev_ft + 1500 { why = why + f"; density alt {da} ft"; }

        self.usable.append(format_brief(self.callsign, "airport", here.ident, here.name,
                                        dist, brg, chosen.ident, chosen.length_ft, end.hdg,
                                        end.headwind_kt, end.crosswind_kt, need_here,
                                        margin, score, why));
    }

    # --- 3. deliver, after every queued airport has been visited -------
    can deliver with Root exit {
        # Rank by (score, discovery order) using natural list ordering, which
        # keeps equal scores in a stable, deterministic order.
        indexed: list[list[float]] = [];
        for i in range(len(self.usable)) {
            s: float = self.usable[i]["score"] as float;
            indexed.append([s, float(i)]);
        }
        indexed.sort();

        ranked: list[dict[str, any]] = [];
        for pair in indexed {
            if len(ranked) >= self.max_candidates { break; }
            ranked.append(self.usable[int(pair[1])]);
        }

        # Fallback when no field is usable: the best place to put it on the
        # water. A controlled ditch into wind, on the leeward side of a fetch,
        # with the sea state lowest, beats a bad runway every time.
        ditch: dict[str, any] = {
            "kind": "ditch",
            "status": "no field meets the gates",
            "wind_kt": self.wind_kt,
            "wind_dir_deg": self.wind_dir_deg,
            "note": "ditch into wind; brief cabin, expect 1-2 g at contact"
        };

        envelope: list[list[float]] = polygon(self.center_lat, self.center_lon, self.radius_nm);

        advisory: dict[str, any] = {
            "callsign": self.callsign,
            "aircraft_type": self.aircraft_type,
            "spec": {"name": self.spec.name, "engines": self.spec.engines,
                     "vg_kt": self.spec.vg_kt, "ld": self.spec.ld_max,
                     "crosswind_limit_kt": self.spec.crosswind_limit_kt},
            "position": {"lat": self.lat, "lon": self.lon, "alt_ft": self.alt_ft,
                         "tas_kt": self.tas_kt, "track_deg": self.track_deg},
            "failure": {"list": self.failures, "mode": self.profile.mode,
                        "ld_ratio": self.profile.ld_ratio,
                        "glide_kt": self.profile.glide_kt,
                        "driftdown_ft": self.profile.driftdown_ft,
                        "endurance_min": self.profile.endurance_min,
                        "urgency": self.profile.urgency, "notes": self.profile.notes},
            "envelope": {
                "center": [self.center_lat, self.center_lon],
                "radius_nm": r1(self.radius_nm),
                "flight_min": r1(self.flight_min),
                "drift_nm": r1(drift_nm(self.wind, self.flight_min)),
                "polygon": envelope
            },
            "wind": {
                "surface": {"dir_deg": self.wind_dir_deg, "speed_kt": self.wind_kt},
                "aloft": {"dir_deg": self.wind_alt_dir_deg, "speed_kt": self.wind_alt_kt}
            },
            "field_conditions": {"temp_c": self.temp_c, "precip": self.precip,
                                 "ceiling_ft": self.ceiling_ft},
            "gates": {"runway_required_ft": self.need_ft,
                      "crosswind_limit_kt": self.spec.crosswind_limit_kt},
            "ranked": ranked,
            "rejected": self.rejected[0:12],
            "fallback": ditch,
            "stats": {"airports_visited": self.seen, "usable": len(self.usable),
                      "rejected": len(self.rejected)}
        };

        report advisory;
    }
}
