# AERO-GUARD

**Emergency ATC decision support.** When an aircraft declares a mayday, an air
traffic controller has to answer one question in under a minute: *where does
this aircraft land?* AERO-GUARD answers it with a physics model and a graph walk
over 1,740 real airports, and shows its work.

Built for [JacHacks](https://jachacks.tech) A2Tech 2026 with
[Jac](https://jac-lang.org) (Jaseci).

---

## What it does

Give it an aircraft in trouble — position, altitude, airspeed, track, which
systems have failed, and the weather — and it returns a **ranked list of
fields you can actually reach**, each with the numbers behind the ranking:

```
CALLSIGN   TSV236   A330-200   FL370   ENG OUT / ENG OUT / FIRE
─────────────────────────────────────────────────────────────────────
 1  CYQX  Gander Intl        42.0 nm   10,400 ft  11,400 ft req  +2,600 ft
 2  CYHZ  St Johns           51.8 nm    8,400 ft   9,900 ft req   rejected
 3  CYRB  St Johns West      55.1 nm    4,200 ft       —           rejected
```

Each row has to survive four gates, in order, and then compete on score:

1. **Drift envelope** — inside the glide/drift-down circle, which is offset
   downwind of the aircraft, not centred on it. A 30 kt wind at FL370 does not
   move the ellipse, it skews it.
2. **Runway length** — computed for *that runway's* crosswind, not a nominal
   allowance. A 6,000 ft runway with a direct tailwind and one with 25 kt across
   it are not the same runway.
3. **Surface** — asphalt and concrete only, unless nothing else is left.
4. **Conditions** — lighting, precipitation, ceiling.

The scores are real ATC priorities: headwind is good, crosswind is bad, the
margin over required distance is good, and a low ceiling hurts because it turns
a VMC approach into an IMC one.

## Is the physics real?

Yes, and it is checked against three accidents where we know the answer.

| Case | Type / alt | Model says | Actually happened |
|---|---|---|---|
| **Gimli Glider** (1983) | 767, 12,500 ft, all engines out | **CYGM** Gimli Industrial Park | Gimli, on the *closed* Kingsford Ford runway |
| **US Airways 1549** (2009) | A320, 3,100 ft over the Hudson | **KTEB** Teterboro | Teterboro, the first field they tried |
| **Air Transat 236** (1999) | A330, FL370 over the Atlantic | **CYQX** Gander | Gander, after a 3h26m descent |

The model is deliberately **conservative**: it lands on the same field as the
crew in all three cases, but with less margin than the crew actually had,
because it ignores the things that would have helped them — the 11-tonne fuel
dump before the glide, holding speed back to stretch the glide, and the
immense benefit of a favorable surface. Under-declaring margin is the safe
direction to be wrong in.

## Quickstart

Requires Python 3.11+ (developed on 3.14.7).

```bash
git clone https://github.com/masterkoster/aero-guard.git
cd aero-guard
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

`data/airports.json` (1,740 airports / 2,322 runways) is committed, so there is
nothing to download. To rebuild it from the OurAirports CSVs:

```bash
python3 scripts/prep_airports.py
```

### Run the validation

```bash
.venv/bin/jac check tools/engine_test.jac   # type-check
.venv/bin/jac run  tools/engine_test.jac   # all four scenarios, ranked
```

```
GIMLI GLIDER
  B763  12500 ft  210 kt  all engines out
  drift 30 kt -> 10.0 nm downwind
  1  CYGM  Gimli Industrial Park      6,800 ft   need 6,600   +200 ft
     21 kt headwind, 6 kt crosswind, asphalt
  ...
```

`tools/smoke.jac` is the unit-level check on the physics (glide ratios, drift
vectors, turn geometry, wind components, density altitude).

### Run the API

```bash
python3 scripts/serve.py            # starts detached, waits for readiness
```

The first start builds the airport graph, which takes **~110 s** — 1,740
airports and 2,322 runways. Subsequent starts reuse it. It prints the port when
ready; Swagger UI is at `/docs`.

```bash
curl -s localhost:8080/function/system_status | jq
curl -s localhost:8080/function/list_scenarios | jq
curl -s localhost:8080/walker/declare_emergency \
  -H 'content-type: application/json' \
  -d '{"scenario": "Gimli Glider - 767 over the Great Lakes"}' | jq
python3 scripts/serve.py --stop
```

## Endpoints

| Endpoint | Purpose |
|---|---|
| `POST /walker/declare_emergency` | full advisory for a declared emergency |
| `POST /walker/list_airports` | airports in a bbox, for the map viewport |
| `POST /walker/scan_live` | traffic sweep + reachable-field scan |
| `POST /function/system_status` | graph size, engine state |
| `POST /function/list_scenarios` | the named demo emergencies |

## Architecture

```
main.jac              API service. :pub walkers are HTTP endpoints; each one
                      spawns the engine against the graph.
src/physics.jac       flight dynamics. glide/drift-down, wind components, turn
                      geometry, landing distance, density altitude, and the
                      aircraft performance database.
src/archetypes.jac    graph schema: `node Airport`, `node Runway`,
                      `edge HasRunway`. Plus runway-end selection and surface
                      classification.
src/data_loader.jac   the JSON boundary: typed casts, bbox queries, graph load.
src/advisor.jac       EmergencyAdvisor -- the walker that does the deciding.
tools/engine_test.jac end-to-end scenarios with rejection reasons.
tools/smoke.jac       physics unit checks.
```

The advisor is a graph walker that visits every candidate airport, applies the
gates, keeps the survivors in an accumulator, and emits **one** report at the
end via `with Root exit` — so the caller gets a single ranked bundle instead of
one event per node.

```jac
walker EmergencyAdvisor {
    can consider with Airport entry { ... }   # gates + score, per airport
    can deliver with Root exit { report ... } # rank and emit once
}
```

### Why Jac

The decision is a traversal with per-node filtering and a single accumulated
result, which is what graph walkers are for. The physics is typed module code
with no runtime dependencies, which Jac handles natively. Python is only used
for offline data prep and dev tooling.

Current mix, counted by `scripts/jac_ratio.py`:

```
jac total     1238
python total   284
Jac share: 81.3%   (JacHacks floor: 40%)
```

## Data

- **Airports & runways** — [OurAirports](https://ourairports.com/data/) CSVs,
  filtered to the bounding box `-98 36 -52 52` so the historical accident
  sites (Gimli, Gander, Teterboro) are inside the graph.
- **Live traffic** — [OpenSky Network](https://opensky-network.org/) API.
- **Weather** — [Open-Meteo](https://open-meteo.com/).

## Status

Working: physics, graph schema, data pipeline, decision engine, API service,
validation against three accidents.

In progress: live weather layer, live traffic feed, operator console, deployment.

## License

MIT
