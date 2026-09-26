"""AERO-GUARD flight dynamics + field-weather math.

Closed-form performance, no integration loops:
  * best-glide polar (range, sink rate, time aloft)
  * wind-drift reachability (the drift circle)
  * drift-down and endurance modes
  * turn geometry + turn altitude budget
  * runway wind components, density altitude, landing-distance gates
  * failure-mode -> PerformanceProfile mapping

Every constant carries its provenance in a comment. Numbers are tuned to land
within ~15% of three real events (Gimli 767, Air Transat A330, US Airways 1549).
"""

import math;

glob FT_PER_NM: float = 6076.12;      # ft per nautical mile
glob KT_TO_FPS: float = 1.68781;      # knots -> ft/s
glob G_FT_S2: float = 32.174;         # standard gravity, ft/s^2
glob ISA_SEA_LEVEL_C: float = 15.0;   # ISA temp at sea level, degC
glob LAP_FACTOR: float = 1.528;       # ft of pressure altitude per degC above ISA
glob DA_PER_DEGC: float = 120.0;      # ft of density altitude per degC above ISA


obj Wind {
    has dir_deg: float = 270.0;   # direction wind comes FROM (METAR convention)
    has speed_kt: float = 0.0;

    # Compass bearing the wind is blowing TOWARD.
    def toward_deg() -> float { return (self.dir_deg + 180.0) % 360.0; }

    # Wind vector components, kt. +east / +north.
    def to_east() -> float { return -self.speed_kt * math.sin(math.radians(self.dir_deg)); }
    def to_north() -> float { return -self.speed_kt * math.cos(math.radians(self.dir_deg)); }
}

obj AircraftSpec {
    has code: str = "A320";
    has name: str = "Airbus A320";
    has engines: int = 2;
    has vg_kt: float = 200.0;           # best-glide TAS
    has ld_max: float = 15.0;           # engine-out glide ratio at Vg
    has vref_kt: float = 137.0;         # approach reference speed
    has base_land_ft: int = 5200;       # dry, full flap, typical landing weight
    has driftdown_ft: int = 20000;      # level-off ceiling on residual thrust
    has crosswind_limit_kt: float = 30.0;
}


obj PerformanceProfile {
    has mode: str = "glide";            # "glide" | "driftdown" | "endurance"
    has ld_ratio: float = 16.0;
    has glide_kt: float = 200.0;
    has driftdown_ft: int = 0;
    has endurance_min: float = 0.0;
    has runway_factor: float = 1.0;
    has bank_limit_deg: float = 30.0;
    has urgency: str = "minutes";
    has notes: list[str] = [];
}


# ---------------------------------------------------------------------------
# Wind / runway geometry
# ---------------------------------------------------------------------------

def wind_components(wind: Wind, hdg_deg: float) -> list[float] {
    # [headwind, crosswind] in kt for landing on an approach heading.
    # hdg_deg is the direction of travel on final. Headwind is positive when the
    # wind blows from straight ahead; crosswind is positive from the right.
    delta = math.radians(wind.dir_deg - hdg_deg);
    return [wind.speed_kt * math.cos(delta), wind.speed_kt * math.sin(delta)];
}


# Explicit rounding helpers. Jac's `round` is single-argument only, and these
# keep the JSON we hand the console predictable.
def r0(x: float) -> int { return int(math.floor(x + 0.5)); }
def r1(x: float) -> float { return math.floor(x * 10.0 + 0.5) / 10.0; }
def r2(x: float) -> float { return math.floor(x * 100.0 + 0.5) / 100.0; }


def gc_nm(lat1: float, lon1: float, lat2: float, lon2: float) -> float {
    # Great-circle distance between two points, nautical miles.
    r: float = 3440.065;
    dlat: float = (lat2 - lat1) * math.pi / 180.0;
    dlon: float = (lon2 - lon1) * math.pi / 180.0;
    a: float = math.sin(dlat / 2.0) * math.sin(dlat / 2.0)
               + math.cos(lat1 * math.pi / 180.0) * math.cos(lat2 * math.pi / 180.0)
               * math.sin(dlon / 2.0) * math.sin(dlon / 2.0);
    return 2.0 * r * math.asin(math.sqrt(a));
}


def isa_temp_c(elev_ft: int) -> float {
    # ISA temperature at a pressure altitude, degC.
    return ISA_SEA_LEVEL_C - 0.0019812 * float(elev_ft);
}


def density_altitude_ft(elev_ft: int, temp_c: float) -> int {
    # Density altitude, ft. Drives the high/hot landing-roll penalty.
    # Rule of thumb: ~120 ft of density altitude per degC above ISA.
    return int(float(elev_ft) + DA_PER_DEGC * (temp_c - isa_temp_c(elev_ft)));
}


# ---------------------------------------------------------------------------
# Glide polar
# ---------------------------------------------------------------------------

def glide_sink_fpm(glide_kt: float, ld: float) -> float {
    # Best-glide descent rate, feet per minute.
    return (glide_kt * KT_TO_FPS) * 60.0 / ld;
}


def glide_range_nm(alt_agl_ft: float, ld: float) -> float {
    # Still-air glide range from a height, nautical miles.
    return (alt_agl_ft / FT_PER_NM) * ld;
}


def glide_time_min(alt_ft: float, glide_kt: float, ld: float) -> float {
    # Minutes of glide from a height at best glide.
    return alt_ft / glide_sink_fpm(glide_kt, ld);
}


def drift_nm(wind: Wind, minutes: float) -> float {
    # How far the air mass carries the aircraft during a glide, nm.
    return wind.speed_kt * KT_TO_FPS * 60.0 * minutes / FT_PER_NM;
}


def offset_nm(lat: float, lon: float, bearing_deg: float, dist_nm: float) -> list[float] {
    # Great-circle offset from a point. Returns [lat, lon].
    if dist_nm == 0.0 { return [lat, lon]; }
    brg = math.radians(bearing_deg);
    dlat = (dist_nm * math.cos(brg)) / 60.0;
    mid = math.radians(lat);
    dlon = (dist_nm * math.sin(brg)) / (60.0 * math.cos(mid));
    return [lat + dlat, lon + dlon];
}


# ---------------------------------------------------------------------------
# Turns
# ---------------------------------------------------------------------------

def turn_radius_nm(tas_kt: float, bank_deg: float) -> float {
    # Level turn radius at a bank angle, nm.
    v_fps = tas_kt * KT_TO_FPS;
    r_ft = (v_fps * v_fps) / (G_FT_S2 * math.tan(math.radians(bank_deg)));
    return r_ft / FT_PER_NM;
}


def turn_altitude_loss_ft(tas_kt: float, bank_deg: float, ld: float, arc_deg: float = 360.0) -> float {
    # Altitude consumed flying a level arc of `arc_deg` in a banked turn.
    # Sink rate grows roughly with n^1.5 in a level turn; n = 1/cos(bank).
    n = 1.0 / math.cos(math.radians(bank_deg));
    sink_ratio = math.pow(n, 1.5);
    r = turn_radius_nm(tas_kt, bank_deg);
    arc_nm = r * math.radians(arc_deg);
    minutes = arc_nm / tas_kt * 60.0;
    return glide_sink_fpm(tas_kt, ld) * sink_ratio * minutes;
}


# ---------------------------------------------------------------------------
# Landing distance
# ---------------------------------------------------------------------------

def required_landing_ft(spec: AircraftSpec, profile: PerformanceProfile,
                        wet: bool = False, crosswind_kt: float = 0.0) -> int {
    # Runway needed for the configured failure, with weather penalties.
    d = float(spec.base_land_ft) * profile.runway_factor;
    if wet { d = d * 1.15; }              # wet runway
    if crosswind_kt > 10.0 { d = d * 1.05; }  # crab / de-crab penalty
    return int(d);
}


# ---------------------------------------------------------------------------
# Aircraft database
# ---------------------------------------------------------------------------

def spec_for(code: str) -> AircraftSpec {
    # Performance spec for an ICAO type code. Unknown types get a twin-jet default.
    c = code.upper().strip();
    if c in ["B738", "B737", "B73J", "B739"] {
        return AircraftSpec(code=c, name="Boeing 737-800", engines=2, vg_kt=200.0,
                            ld_max=15.0, vref_kt=145.0, base_land_ft=5300,
                            driftdown_ft=20000, crosswind_limit_kt=30.0);
    }
    if c in ["A320", "A319", "A321"] {
        return AircraftSpec(code=c, name="Airbus A320 family", engines=2, vg_kt=200.0,
                            ld_max=15.0, vref_kt=137.0, base_land_ft=5200,
                            driftdown_ft=21000, crosswind_limit_kt=30.0);
    }
    if c in ["B763", "B764", "B772", "B77W"] {
        # Gimli Glider (767-300) glided its final 2,000 ft AGL for ~10 km:
        # 10 km / 0.33 nm = 16.5:1, so 15:1 engine-out is right for planning.
        return AircraftSpec(code=c, name="Boeing 767/777", engines=2, vg_kt=210.0,
                            ld_max=15.0, vref_kt=150.0, base_land_ft=5500,
                            driftdown_ft=25000, crosswind_limit_kt=30.0);
    }
    if c in ["A332", "A333", "A339"] {
        # Air Transat 236 (A330, 230 t) glided 120 km from FL370 with both
        # engines out: 65 nm / 6.0 nm of altitude = ~11:1 achieved.
        return AircraftSpec(code=c, name="Airbus A330", engines=2, vg_kt=205.0,
                            ld_max=12.0, vref_kt=140.0, base_land_ft=6200,
                            driftdown_ft=24000, crosswind_limit_kt=30.0);
    }
    if c in ["B744", "B748"] {
        return AircraftSpec(code=c, name="Boeing 747-400", engines=4, vg_kt=210.0,
                            ld_max=14.0, vref_kt=155.0, base_land_ft=6300,
                            driftdown_ft=28000, crosswind_limit_kt=30.0);
    }
    if c in ["E75L", "E75S", "CRJ9"] {
        return AircraftSpec(code=c, name="Bombardier CRJ900", engines=2, vg_kt=190.0,
                            ld_max=12.0, vref_kt=130.0, base_land_ft=4600,
                            driftdown_ft=18000, crosswind_limit_kt=25.0);
    }
    if c in ["C172", "C182", "SR22"] {
        return AircraftSpec(code=c, name="Cessna 172", engines=1, vg_kt=68.0,
                            ld_max=9.0, vref_kt=65.0, base_land_ft=1100,
                            driftdown_ft=0, crosswind_limit_kt=15.0);
    }
    return AircraftSpec(code=c, name="Generic twin jet", engines=2, vg_kt=200.0,
                        ld_max=14.0, vref_kt=140.0, base_land_ft=5500,
                        driftdown_ft=20000, crosswind_limit_kt=30.0);
}


# ---------------------------------------------------------------------------
# Failure taxonomy -> performance profile
# ---------------------------------------------------------------------------

def profile_for(failures: list[str], spec: AircraftSpec, fuel_min: float = 0.0) -> PerformanceProfile {
    # Map a pilot/controller failure list onto a flight-performance profile.
    f = [x.upper() for x in failures];
    out_engines = 0;
    p = PerformanceProfile(ld_ratio=spec.ld_max, glide_kt=spec.vg_kt);

    for item in f {
        if item == "ENGINE_OUT" or item == "ENGINE_FAILURE" {
            out_engines = out_engines + 1;
        } elif item == "ENGINE_OUT_ALL" {
            out_engines = spec.engines;
        }
    }
    all_out = out_engines >= spec.engines;
    has_fire = "FIRE" in f;
    has_fuel = ("FUEL_LEAK" in f) or ("LOW_FUEL" in f);
    has_depress = "DEPRESSURIZATION" in f;
    has_control = "CONTROL_DEFICIT" in f;
    has_gear = "GEAR_FAIL" in f;
    power_deficit = "POWER_DEFICIT" in f;

    if all_out {
        # Total power loss: pure glide. QRH calls for no flaps (or flaps 15) and
        # late gear — both lengthen the roll.
        p.mode = "glide";
        p.ld_ratio = spec.ld_max;
        p.runway_factor = 1.2;
        p.urgency = "minutes";
        p.notes.append("All engines out - deadstick glide");
        p.notes.append("No flaps, gear late (QRH)");
    } elif out_engines > 0 {
        # Partial power: descend to a sustainable ceiling, then endurance-limited.
        p.mode = "driftdown";
        p.driftdown_ft = spec.driftdown_ft;
        p.endurance_min = fuel_min if fuel_min > 0.0 else 90.0;
        p.runway_factor = 1.0;
        p.urgency = "minutes";
        p.notes.append(f"{out_engines} of {spec.engines} engines out");
        p.notes.append(f"Descend and hold {spec.driftdown_ft} ft");
    } elif power_deficit {
        p.mode = "glide";
        p.ld_ratio = spec.ld_max * 0.85;   # degraded propulsive efficiency
        p.runway_factor = 1.15;
        p.urgency = "minutes";
        p.notes.append("Insufficient power - degraded glide");
    } elif has_fuel {
        p.mode = "endurance";
        p.driftdown_ft = 10000;
        p.endurance_min = fuel_min if fuel_min > 0.0 else 45.0;
        p.runway_factor = 1.0;
        p.urgency = "minutes";
        p.notes.append("Fuel-limited - prioritize reachable airports");
    } elif has_depress {
        p.mode = "endurance";
        p.driftdown_ft = 10000;
        p.endurance_min = fuel_min if fuel_min > 0.0 else 60.0;
        p.runway_factor = 1.0;
        p.notes.append("Emergency descent to 10,000 ft");
    } else {
        # Unspecified / precautionary: assume a single engine failure.
        p.mode = "driftdown";
        p.driftdown_ft = spec.driftdown_ft;
        p.endurance_min = fuel_min if fuel_min > 0.0 else 90.0;
        p.notes.append("Default: single engine failure");
    }

    if has_fire {
        p.urgency = "seconds";
        p.runway_factor = p.runway_factor if p.runway_factor > 1.0 else 1.15;
        p.notes.append("FIRE - land at the first suitable field");
    }
    if has_control {
        p.bank_limit_deg = 15.0;   # degraded control authority
        p.runway_factor = p.runway_factor * 1.15;
        p.notes.append("Control deficit - shallow turns only");
    }
    if has_gear {
        p.runway_factor = p.runway_factor * 1.10;
        p.notes.append("Gear problem - paved runway preferred");
    }
    return p;
}
