"""End-to-end engine test: run the advisor on a real historical scenario.

Run with:  jac run tools/engine_test.jac
"""

import time;
import from src.data_loader { load_airports, airport_count, runway_count }
import from src.physics { r1 }
import from src.advisor { EmergencyAdvisor }


def show(title: str, callsign: str, ac_type: str, lat: float, lon: float, alt: int,
         failures: list[str], wdir: float, wkt: float, temp: float, precip: bool) {
    print(f"\n=== {title} ===");
    t0: float = time.time();
    res = root spawn EmergencyAdvisor(
        callsign=callsign, aircraft_type=ac_type, lat=lat, lon=lon, alt_ft=alt,
        tas_kt=210.0, track_deg=250.0, failures=failures, fuel_min=0.0,
        wind_dir_deg=wdir, wind_kt=wkt, wind_alt_dir_deg=wdir, wind_alt_kt=wkt * 1.8,
        temp_c=temp, precip=precip, ceiling_ft=12000, max_candidates=4
    );
    elapsed: float = time.time() - t0;
    if len(res.reports) == 0 {
        print("  NO REPORT");
        return;
    }
    a: any = res.reports[0];
    env: any = a["envelope"];
    fail: any = a["failure"];
    stats: any = a["stats"];
    print(f"  mode={fail['mode']}  L/D={fail['ld_ratio']}  urgency={fail['urgency']}");
    print(f"  envelope r={env['radius_nm']} nm, {env['flight_min']} min aloft, "
          f"drift {env['drift_nm']} nm");
    print(f"  visited {stats['airports_visited']} airports -> {stats['usable']} usable, "
          f"{stats['rejected']} rejected  ({elapsed:.2f}s)");
    for r in a["ranked"] {
        print(f"  {r['ident']:6s} {r['dist_nm']:6.1f}nm brg{r['bearing_deg']:3d}  "
              f"rwy {r['runway']:8s} {r['runway_ft']:6d}ft  hw {r['headwind_kt']:5.1f} "
              f"xw {r['crosswind_kt']:5.1f}  margin {r['margin_ft']:6d}  score {r['score']:6.2f}");
        print(f"         {r['name']} — {r['why']}");
    }
    for r in a["rejected"][0:3] {
        print(f"  x {r['ident']:6s} {r['dist_nm']:6.1f}nm  {r['reason']}");
    }
}


with entry:__main__ {
    t0: float = time.time();
    n: int = load_airports();
    print(f"[load] {n} airports, {runway_count()} runways in {time.time() - t0:.1f}s");

    # Gimli Glider, 29 May 1983: 767-300, both engines out at 41,000 ft.
    show("Gimli Glider (767-300, all engines out, 12,500 ft)",
         "AC8703", "B763", 50.65, -97.05, 12500, ["ENGINE_OUT_ALL"], 200.0, 8.0, 16.0, False);

    # Air Transat 236: A330, both engines out plus fire, high and heavy.
    show("Air Transat 236 (A330, dual engine out + fire, FL370)",
         "TSV236", "A332", 48.6, -58.5, 37000,
         ["ENGINE_OUT", "ENGINE_OUT", "FIRE"], 300.0, 28.0, -38.0, False);

    # US Airways 1549: A320, dual engine out, 3,100 ft over the Hudson.
    show("US Airways 1549 (A320, all engines out, 3,100 ft)",
         "N1549", "A320", 40.85, -74.2, 3100, ["ENGINE_OUT_ALL"], 290.0, 9.0, 14.0, False);

    # Michigan demo: 737 dual engine failure at FL350 in summer.
    show("Michigan demo (737-800, dual engine out, FL350, 22 kt)",
         "AAL1178", "B738", 42.9, -84.9, 35000,
         ["ENGINE_OUT", "ENGINE_OUT"], 250.0, 22.0, 19.0, False);
}
