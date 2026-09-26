"""Runtime smoke test: load the graph, then sanity-check the physics.

Run with:  jac run tools/smoke.jac
"""

import math;
import from src.data_loader { load_airports, airport_count, runway_count, airports_in_box }
import from src.physics { AircraftSpec, PerformanceProfile, Wind, spec_for, profile_for,
                          glide_range_nm, glide_sink_fpm, glide_time_min, drift_nm,
                          turn_radius_nm, turn_altitude_loss_ft, required_landing_ft,
                          wind_components, density_altitude_ft }


with entry:__main__ {
    n: int = load_airports();
    print(f"[graph] {n} airports, {runway_count()} runways");

    box: list[any] = airports_in_box(41.5, 43.5, -85.0, -82.0);
    print(f"[query] airports in the Detroit bbox: {len(box)}");

    # --- physics sanity, all against published numbers -------------------
    a320: AircraftSpec = spec_for("A320");
    b77: AircraftSpec = spec_for("B77W");
    print(f"[spec] A320 L/D {a320.ld_max}  B77W L/D {b77.ld_max}");

    # Gimli Glider: 767-300, gear down + some flaps, ~17:1.
    r: float = glide_range_nm(41000.0, b77.ld_max);
    print(f"[glide] 41,000 ft at {b77.ld_max}:1 -> {r:.0f} nm ({r * 1.852:.0f} km), "
          f"vs Gimli's ~10 km to first touchdown");

    # Air Transat 236: A330 at FL370 -> ~120 km of glide.
    a330: AircraftSpec = spec_for("A332");
    r2: float = glide_range_nm(37000.0, a330.ld_max);
    print(f"[glide] FL370 A330 at {a330.ld_max}:1 -> {r2 * 1.852:.0f} km "
          f"vs Air Transat's 120 km");

    sink: float = glide_sink_fpm(210.0, 17.0);
    mins: float = glide_time_min(35000.0, 210.0, 17.0);
    print(f"[glide] sink {sink:.0f} fpm, time aloft from FL350 {mins:.0f} min");

    # Drift: 30 kt for 20 min = 10 nm.
    w: Wind = Wind(dir_deg=270.0, speed_kt=30.0);
    print(f"[drift] 30 kt / 20 min -> {drift_nm(w, 20.0):.1f} nm (expect 10.0)");

    # Turn: 210 kt at 30 deg bank -> ~1.1 nm radius.
    rad: float = turn_radius_nm(210.0, 30.0);
    loss: float = turn_altitude_loss_ft(210.0, 30.0, 17.0);
    print(f"[turn] 210 kt @30deg bank -> r={rad:.2f} nm, 360 costs {loss:.0f} ft");

    # Runway wind: wind from 220 at 20 kt, landing on runway 22.
    comp: list[float] = wind_components(Wind(dir_deg=220.0, speed_kt=20.0), 220.0);
    print(f"[wind] rwy 22, wind 220/20 -> headwind {comp[0]:.1f} kt, crosswind {comp[1]:.1f} kt");
    comp2: list[float] = wind_components(Wind(dir_deg=240.0, speed_kt=20.0), 220.0);
    print(f"[wind] rwy 22, wind 240/20 -> headwind {comp2[0]:.1f} kt, crosswind {comp2[1]:.1f} kt (from right)");

    # Landing gate: A320 dual-engine failure, no flaps.
    prof: PerformanceProfile = profile_for(["ENGINE_OUT", "ENGINE_OUT"], a320);
    need: int = required_landing_ft(a320, prof, True, 12.0);
    print(f"[gate] A320 all-out glide: mode={prof.mode} L/D={prof.ld_ratio} "
          f"need={need} ft wet+crosswind");

    # Single-engine failure -> drift-down.
    prof2: PerformanceProfile = profile_for(["ENGINE_OUT"], b77, 120.0);
    print(f"[profile] 1 of 2 out -> mode={prof2.mode} ceiling={prof2.driftdown_ft} ft "
          f"endurance={prof2.endurance_min:.0f} min");

    # Density altitude on a hot summer afternoon at KDTW.
    print(f"[density] DTW 645 ft, 32 C -> {density_altitude_ft(645, 32.0)} ft");
}
