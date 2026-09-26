# AERO-GUARD — Emergency ATC Decision Support System

**JacHacks A2Tech 2026 · Sep 26–27 · Leinweber Building, U-M North Campus**
**Status: PLANNING MODE — no code until hacking hours begin (Sat 12:30 PM). Organizers check commit history.**

---

## 1. Mission (the 30-second pitch)

> When a flight declares an emergency, the controller has seconds and a head full of charts.
> AERO-GUARD is a decision-support copilot for **air traffic control**: the moment an aircraft
> declares mayday, loses engines, or squawks 7700, the system ingests the live position,
> models what the aircraft can physically still do, scans every airport, field, and water
> surface it can reach, and hands the controller a **ranked set of options with a ready-to-read
> radio transmission** — turn-by-turn, runway-by-runway, second-by-second.

**The hook for judges:** In 2009, Sully had 208 seconds and ATC improvised over the radio.
AERO-GUARD does that computation in under a second — every time, for any flight, anywhere.

**Why Jac is the story, not the constraint:** The airspace *is* a graph — airports, runways,
failure modes, procedures, options. In Jac the whiteboard diagram **is the data model**: the
emergency decision engine is a `walker` that travels a knowledge graph of failure modes and
candidate landing sites, scoring and ranking via accumulate-then-deliver. That's a shot at
the **Best Jaclang** special award, not just a compliance checkbox.

---

## 2. Hackathon rules & submission requirements (from jachacks.org/a2tech-guide/)

| # | Requirement | How we satisfy it |
|---|---|---|
| 1 | **≥40% of code in Jac** | Entire backend — engine, physics, graph, API — in Jac. Python only for data prep scripts + tests. Target 60–70% Jac to be safe. Measure with a line-count script. |
| 2 | All code written during hacking hours (Sat 12:30 PM → Sun 12:00 PM), commit history checked | Initialize git repo **at hacking start**. This PLAN.md is brainstorming (allowed) — commit it with the first commit at 12:30 PM. No code before. |
| 3 | Team ≤ 4, registered + checked in | **Solo build** — max 4 satisfied |
| 4 | Devpost submission: repo link, demo video, written description incl. **how we used Jac** | Milestoned below (Sun 9:30 AM partial, Sun 12:00 PM HARD deadline) |
| 5 | Host on **Jac Hammer** (jachammer.ai), coupon `JACHACKS-UMICH` or "sandbox" | Deploy milestone Sat evening, so Sunday is polish not panic |
| 6 | Tracks: Agentic AI, Developer Tools, Local Impact (skip — needs an Ann Arbor-specific user + Baz) | **Enter: Developer Tools, Agentic AI, Best Jaclang, Best of ElevenLabs (stretch)** |
| 7 | "Working demos beat slide decks" | Rehearsed live demo with real live traffic, 3 canned scenarios, fallback replay |

**Judging is Sunday 12:30–2:00 PM, live. Sunday morning is demo rehearsal, not feature work.**

---

## 3. System overview

```
                         ┌─────────────────────────────────────────────┐
                         │                 ATC CONSOLE (browser)        │
                         │  radar map · envelope · countdown · advisory│
                         └────────────────────┬────────────────────────┘
                                              │ HTTP
┌───────────────────────┐            ┌────────▼─────────────────────────┐
│ OpenSky Network API   │  live AC   │        JAC BACKEND  (≥60% code)   │
│  (position, squawk,   ├───────────►│  · main.jac   — API walkers       │
│   altitude, velocity, │            │  · archetypes.jac — graph schema  │
│   heading, vspeed)    │            │  · physics.jac — flight dynamics  │
│                       │            │  · weather.jac — field wx, XW/    │
│                       │            │    wet/VMC/DA + winds-aloft feed  │
├───────────────────────┤            │  · advisor.jac — EmergencyAdvisor│
│ Open-Meteo API        │ winds at   │    walker (the decision engine)    │
│  (wind aloft, ground, │ altitude + │  · data_loader.jac — airports→    │
│   elevation/terrain)  │  terrain   │    Airport/Runway graph nodes     │
├───────────────────────┤            │  · advisory.jac — phraseology +   │
│ OurAirports CSVs      │ airports + │    checklist generation           │
│  (public domain)      │  runways   │  · scenarios.jac — replay + inject│
└───────────────────────┘            └────────┬─────────────────────────┘
                                              │ graph persists in .jac/
                                     Airport nodes ++> Runway nodes
                                     SituationChain nodes ++> Procedure nodes
                                     EmergencyAdvisor walker traverses them
```

### The Jac graph (the centerpiece)

- **`Airport` nodes** (from OurAirports, filtered to region) connected to **`Runway` nodes**
  via typed edges. A spatial query `[airport -->][?:Runway, length_ft >= self.min_length]`
  *is* the candidate filter — no SQL, no join, one bracketed path.
- **`Situation` subgraph** — failure modes, their effects, and procedures chained by typed
  edges (`FailureMode ++> Effect ++> Phase ++> Procedure`). Built once at startup from the
  failure taxonomy table.
- **`EmergencyAdvisor` walker** — carries the live flight state (position, altitude, speed,
  heading, failure list, wind). It:
  1. spawns at the root, runs the situation chain → produces a `PerformanceProfile`
     (glide ratio, drift-down ceiling, endurance, urgency, landing-distance multipliers),
  2. visits the Airport shortlist (pre-filtered to the reachable envelope by plain math —
     we never walk 30k nodes; we walk the ~dozens that matter),
  3. scores each candidate in an **entry ability** (`here` = the airport, `self` = the
     walker accumulating results),
  4. ranks and **reports the advisory from a `with Root exit` ability** — the textbook
     Jac accumulate-then-deliver idiom.
- **Live loop**: every OpenSky poll re-spawns the walker with fresh state → the graph
  recomputes the world in milliseconds.

### Python's (small) role

Jac compiles to Python bytecode and imports Python libraries natively, so the split is a
spectrum. We keep Python for: data preprocessing (OurAirports CSV → filtered regional JSON),
the OpenSky poller if `requests` from Jac feels awkward (solo build — don't fight it), and
property tests. Everything user-visible and everything at demo time is Jac.

---

## 4. Failure taxonomy → performance model (the "full flight dynamics" layer)

### 4.1 Failure modes (inputs, one or more per emergency)

| Mode | Example input | Effect class |
|---|---|---|
| `ENGINE_OUT` ×1 | "engine 1 out" on A320 | **Drift-down**: partial thrust, endurance-limited |
| `ENGINE_OUT` ×N (all) | "both engines out" / "right bank engines out" on 747 | **Total power loss**: glide-limited |
| `POWER_DEFICIT` | "not making enough thrust", fuel contamination | Glide with penalty factor |
| `FIRE` | engine/cargo fire | Immediate landing; overweight allowed; urgency max |
| `FUEL_LEAK` / `LOW_FUEL` | fuel leak | Endurance countdown drives scoring |
| `DEPRESSURIZATION` | | Emergency descent to 10,000 ft, then endurance-limited |
| `CONTROL_DEFICIT` | jammed elevator, flaps stuck | Longer runway multiplier, limited bank |
| `GEAR_FAIL` | | Runway surface multiplier, foam preference |

Each failure maps to a `PerformanceProfile`:

```
obj PerformanceProfile {
    has mode: str;                 # "glide" | "driftdown" | "endurance"
    has glide_ratio: float;        # L/D at best-glide speed (total-loss case)
    has glide_speed_kt: float;     # Vg (TAS)
    has driftdown_alt_ft: float;   # level-off ceiling on residual thrust
    has endurance_min: float;      # time aloft (drift-down/endurance cases)
    has runway_factor: float;     # landing distance multiplier (no flaps, no T/R, wet...)
    has bank_limit_deg: float;     # turn performance limit
    has urgency: str;             # "minutes" | "seconds"
}
```

### 4.2 The physics (all in `physics.jac`, pure functions/objs, unit-testable)

**Aircraft DB** (curated constants w/ sources in comments — ~8 common types: B738, A320,
A321, B77W, B763, A332, E75L, C172):
- MTOW, typical landing weight, engine count/model
- Best-glide speed & ratio: B767 ≈ 17:1 (proven at Gimli), A320 ≈ 15–17:1, B747 ≈ 15:1,
  C172 ≈ 9:1
- Vref, dry full-flap landing distance at typical landing weight, drift-down ceiling
  (twin singles: ~FL200 at mid weights)

**Glide (total power loss):**
- Still-air range: `R = h_AGL × (L/D)`.
- **Wind-drift envelope** (the elegant version): the reachable set on the ground is a
  circle of radius `R` centered at `position + wind_vector × t_glide` — the classic drift
  circle. Any site inside is reachable *provided* an intercept solution exists (turn math
  below). This renders on the map as the "reachable footprint" polygon and is computed
  per-heading (36 sectors) so the envelope is wind-distorted, not a naive circle.
- Time aloft: `t = h / descent_rate`, descent rate = `Vg/(L/D)` (~1,200–1,500 fpm).
  Feeds the on-screen countdown.

**Drift-down (partial power):**
- Descend to `driftdown_alt_ft`, then range = `endurance × ground_speed`. The problem
  becomes fuel/endurance-limited → scoring ranks sites by "can I get there before fuel-out"
  plus margin. The countdown panel shows fuel time instead of altitude time.

**Turns & intercept (per candidate):**
- Bank φ at Vg → radius `r = V²/(g·tan φ)`; load factor `n = 1/cos φ` → increased sink
  rate in the turn → altitude budget for turn + final. Verify a feasible intercept exists
  (direct / base-turn) onto the best runway end; discard candidates that burn more turn
  altitude than available.
- Runway selection: pick the end with the best headwind component (surface wind from
  Open-Meteo); compute the intercept heading — this becomes the "turn left heading 090"
  in the advisory.

**Landing distance gate:**
- Required runway = `base_landing_distance × Σ factors` (no-flaps 1.4, no-reversers 1.2,
  wet 1.15, control deficit 1.15, flaps-15 1.25, no anti-skid 1.3 — curated table).
- Available = longest runway at candidate (from OurAirports). Hard gate + margin scoring.

**Terrain clearance gate:**
- Sample elevation along the track (Open-Meteo Elevation API, 90 m Copernicus DEM,
  ≤100 points/request — batch the samples). Glide profile must clear terrain + obstacle
  margin (1,000 ft day VFR-ish, we'll state the margin in the UI). Terrain conflicts mark
  a candidate "blocked" with the reason.

### 4.3 Fallback site classes (when no runway is reachable)

1. **Fields** — inside the glide envelope, grid-search flat, low-slope, unobstructed cells
   (elevation variance heuristic on the DEM grid + distance from built-up proxy). Label as
   "unprepared surface" with gear advice.
2. **Ditching** — max-range point into the wind sector, near coast/shipping if applicable;
   checklist: gear up, flaps full, into the swell, 1549 homage in the demo.

Priority: **major airport > regional > GA strip > field > water** — but the gate math
decides, and the advisory explains *why* (judges love the reasoning panel).

### 4.4 Weather layer — field conditions on the spot (`src/weather.jac`)

One Open-Meteo call per candidate site (15-min cache) → a `FieldConditions` obj, then
simple, defensible math — no forecaster degree required:

- **Per-runway wind components** — `HW = W·cos(Δθ)`, `XW = W·sin(Δθ)` for each runway end →
  drives runway-end selection AND a **crosswind hard gate** against the aircraft limit
  (curated: A320/B737 ≈ 33–38 kt demonstrated; GA types ≈ 15–17 kt).
- **Gust spread** (gusts − mean wind) → stability flag; breaks near-ties toward the
  steadier site.
- **Wet runway** — precipitation over the last hour > 0.2 mm → apply the wet
  landing-distance factor from §4.2. Data-driven, not assumed.
- **Density altitude** — field temperature vs ISA at field elevation → landing roll
  adjustment; hot/high fields get flagged ("DA +1,800 ft — expect a longer float").
- **VMC / IMC** — visibility + cloud cover → "visual approach available" flag. In IMC or
  at night: GA strips and *field* landings crater in score (the pilot can't see them);
  a major airport with an approach procedure gains. IMC also downgrades the
  field-fallback class.
- **Winds aloft** (already feeding the glide envelope, §4.2) render per-sector in the UI
  so the controller sees *why* the envelope is lopsided.

**Deliberately out of scope** (we say this on Devpost — judges respect a scoped model):
convection/storm cells, icing, sea state, METAR parsing. Every number above is one trig
call or one threshold — that's the "calculate on the spot" promise.

### 4.5 Scoring function (0–100, in the walker's entry ability)

- **Hard gates:** inside drift-circle envelope, feasible intercept, runway length ≥ required
  (or fallback class), terrain clear, crosswind within aircraft limit.
- **Score:** runway margin (25) · headwind (10) · crosswind margin (10) · distance inverse
  (10) · airport quality/ARFF (10) · approach simplicity (10) · weather (dry/paved,
  gust stability, DA penalty) (10) · lighting/day-VMC (5) · for ditch/field: rescue
  proximity + into-wind + surface (10).

### 4.6 Validation plan (this is what makes "full dynamics" defensible)

Property tests in `tests/` (Pytest driving Jac in library mode) asserting the model
reproduces famous real events within ~15%:
- **Gimli Glider** (B767, ~17:1, reached a dragstrip from ~8,500 m): expect our envelope
  to contain it.
- **Air Transat 236** (A330, ~120 km glide to Azores): expect envelope radius ≈ 120+ km.
- **US Airways 1549** (A320 from ~915 m after birdstrike): expect no runway in envelope →
  ditch recommendation. (This is literally our fallback-class test case.)

---

## 5. Data sources

| Source | What | Cost/risk | Notes |
|---|---|---|---|
| **OpenSky Network** `GET /api/states/all` | Live lat/lon, baro/geo altitude, TAS, heading, vertical rate, squawk, callsign, on-ground | Free; anonymous = low rate limits | **Register account + OAuth2 client** during hour 1 for 10× quota. Poll only the tracked aircraft (bbox query). Cache aggressively. |
| **Open-Meteo Forecast** | Winds aloft for the envelope (near-surface + pressure levels via GFS endpoint); per-candidate surface weather: wind speed/dir + gusts, precipitation, cloud cover, visibility, temperature | Free, no key, generous | One call per candidate, 15-min cache; verify exact hourly params in the hour-1 spike |
| **Open-Meteo Elevation** | 90 m terrain, ≤100 pts/request | Free, no key | Batch track sampling |
| **OurAirports** (airports.csv, runways.csv) | ~35k airports, lengths, surfaces, lat/lon, ICAO/FAA codes | Public domain | Pre-filter to region(s) at build time via a Python script → `data/airports.json` (~2–5 MB) |

**Fallback mode (demo insurance):** if OpenSky is down/rate-limited or no flight is in the
demo bbox, `scenarios.jac` replays a recorded state vector frame-by-frame (callsign,
position, altitude, track). The UI badge shows LIVE vs REPLAY. **The demo never dies.**

Auto-trigger showcase (stretch): watch a bbox; any aircraft squawking **7700** (OpenSky
exposes squawk) auto-locks the emergency flow. If none appears, inject a simulated 7700 —
same code path.

---

## 6. API design (every endpoint is a Jac walker / `def:pub`)

`jac start main.jac` → endpoints at `POST /walker/<name>` and `/function/<name>`,
Swagger at `/docs`, live graph at `/graph` (a judge-pleaser: show the actual graph).

| Endpoint | Body | Returns |
|---|---|---|
| `walker/scan_live` | `{bbox}` or none | list of live aircraft in region (id, callsign, type, pos, alt) |
| `walker/declare_emergency` | `{icao24 or position, failures: [...], weight?}` | full advisory bundle (below) |
| `walker/refresh_advisory` | `{session}` | recomputed with latest OpenSky poll + countdown |
| `walker/inject_7700` | `{icao24}` | triggers emergency flow (demo button) |
| `walker/list_airports` | `{lat, lon, radius}` | airports + runways in envelope (debug/fallback UI) |

**Advisory bundle (the product):**
```
{
  "performance": {mode, glide_ratio, envelope_km, minutes_aloft, ...},
  "envelope":  [...polygon lat/lons...],        // wind-distorted reachable footprint
  "candidates":[{icao, name, score, runway, headwind, crosswind, wet, vmc, margin, reasons[], blocked?}],
  "primary":   {...top candidate + FieldConditions summary...},
  "alternates":[...next two...],
  "fallback":  {type: "ditch"|"field", position, reasoning} | null,
  "radio":     "Delta 1234, emergency approved. Turn left heading 090, ...",
  "checklist": ["Best glide 210 kt", "RAT ... green", "Flaps late — gear late", ...],
  "countdown_s": 612,
  "why":       "KDTW 22R: 3,600 m vs 2,100 m required, 12 kt headwind, 18 km inside envelope, ARFF index E"
}
```

---

## 7. ATC console (frontend)

- **Map**: Leaflet + CARTO dark_matter tiles (free, dark radar aesthetic). Layers:
  - aircraft icon w/ velocity leader + track history
  - **wind-drifted envelope polygon** (the money shot — update every refresh)
  - candidate pins color-coded by score; primary site + runway centerline + intercept arc
  - fallback marker (field/ditch) with dashed track
- **Right panel**: the advisory — radio transmission (big, copyable — ElevenLabs voice
  playback reads it like a controller, stretch goal for Best of ElevenLabs), checklist,
  reasoning, candidate table (sortable).
- **Field-conditions strip** (on the selected site): wind arrow + speed/gusts, headwind /
  crosswind on the chosen runway, dry/wet, DA, VMC/IMC badge.
- **Top bar**: callsign, type, failures, **TIME TO IMPACT countdown** (altitude-limited or
  fuel-limited), LIVE/REPLAY badge.
- **Emergency bar**: pick a live flight from the radar → choose failure checkboxes
  ("both right engines", "not enough power", "fire", "fuel leak"...) → declare. Also
  "inject 7700" button.
- Serving: static assets mounted through the Jac server (confirm mechanism in the
  full-stack tutorial during hour 0–1; fallback: plain static server / GitHub Pages with
  CORS, since Jac Hammer is the deploy target).

---

## 8. Repo layout (to be created at hacking start)

```
aero-guard/
├── main.jac                 # API walkers + entry; served by `jac start`
├── src/
│   ├── archetypes.jac       # Airport, Runway, FailureMode, Effect, Procedure nodes + edges
│   ├── physics.jac         # Aircraft DB, PerformanceProfile, glide/drift/turn/landing math
│   ├── weather.jac         # FieldConditions: wind/XW/wet/DA/VMC per candidate + winds aloft
│   ├── advisor.jac         # EmergencyAdvisor walker (scoring, gates, ranking)
│   ├── data_loader.jac      # airports.json → graph nodes (startup)
│   ├── advisory.jac        # radio phraseology + checklist generation
│   ├── scenarios.jac       # replay fixtures + 7700 injection + fallback flight sim
│   └── opensky.jac         # OpenSky + Open-Meteo clients (try Jac-first; Python module if needed)
├── scripts/
│   ├── prep_airports.py    # OurAirports CSV → data/airports.json (region-filtered)
│   └── jac_ratio.py        # line-count by language → prints Jac % (submission evidence)
├── data/
│   ├── airports.json
│   └── aircraft_types.json # performance constants w/ source comments
├── tests/
│   ├── test_glide.jac      # Jac native tests (gimli/236/1549 sanity)
│   └── ...
├── frontend/ (or jac-client app)
├── README.md               # demo gif, how we used Jac (Devpost mirrors this)
└── PLAN.md                 # this file
```

**40% budget check:** every backend file is `.jac`. Python: 2 scripts + tests. If ratio
dips below ~50% mid-hackathon, port the poller or checklist tables into Jac — they're
natural fits. Track with `scripts/jac_ratio.py` at every milestone.

---

## 9. Timeline — SOLO CRITICAL PATH (hacking hours Sat 12:30 PM → Sun 12:00 PM)

Serial by design: engine → live data → minimal UI → deploy → weather polish → demo.
Frontend is a single HTML file with Leaflet from a CDN — zero build tooling.

| Clock | Hours in | Milestone | Exit criteria |
|---|---|---|---|
| Sat 12:30 | 0 | **Kickoff**: git init, repo skeleton, install Jac (`jac run` hello-walker), register OpenSky OAuth2 creds, download OurAirports CSVs | hello-walker runs |
| Sat 13:00 | 0.5 | **Jac spike** (crucial): 3 Airport nodes ++> Runway nodes; a walker queries `[?:Runway, length_ft >= x]` and reports; confirm static-file serving; pick plain HTML over jac-client | ranked runways via curl |
| Sat 14:00 | 1.5 | **Data**: `prep_airports.py` → `data/airports.json` (region-filtered); `data_loader.jac` builds the graph | `/graph` shows hundreds of airports |
| Sat 15:00 | 2.5 | **Physics core**: `physics.jac` — Aircraft DB, PerformanceProfile, glide + drift circle + wind + landing gates | still-air Gimli sanity test passes |
| Sat 17:30 | 5 | *Mentor check-in — demo the walker on canned data* | |
| Sat 18:00 | 5.5 | **Advisor end-to-end** on a canned flight state (hardcoded pos/alt): ranked candidates + advisory JSON | `walker/declare_emergency` works via curl |
| Sat 19:30 | 7 | **Live data**: OpenSky poller (bbox, cache) + winds aloft; `scenarios.jac` replay fallback | LIVE badge; envelope is wind-shaped |
| Sat 21:00 | 8.5 | **Console v1** (single HTML + Leaflet): map + aircraft + envelope + candidates + advisory panel + countdown | full demo path works on localhost |
| Sat 22:30 | 10 | **Weather layer**: `weather.jac` — per-site wind/XW/wet/VMC/DA + scoring gates + field-conditions strip | weather line appears in candidate "why" |
| Sat 23:30 | 11 | **Deploy to Jac Hammer EARLY** (solo insurance — deploy bugs at 2 AM alone are fatal) | public URL works |
| Sun 00:30 | 12 | **Sleep 6 h. Non-negotiable.** Alarm 06:30. (Deploy + localhost both up = safe stopping point) | 😴 |
| Sun 06:30 | 18 | **Fallback sites**: ditch first (1549 test), fields only if time; terrain sampling for top-3 candidates only | 1549 case → ditch advisory |
| Sun 08:00 | 19.5 | **Lock 3 demo scenarios** + record fixtures; tests green (Gimli/236/1549 ±15%) | each scenario < 90 s, deterministic |
| Sun 09:00 | 20.5 | README + Devpost write-up ("how we used Jac") + `jac_ratio.py` screenshot (≥50%) | docs done |
| Sun 09:30 | 21 | **Partial submission checkpoint — SUBMIT NOW** | Devpost draft in |
| Sun 10:00 | 21.5 | **Rehearse ×3** on live Michigan traffic; fix only demo-blocking bugs | one clean run |
| Sun 11:30 | 23 | Freeze, final commit, **final Devpost submission** (12:00 HARD) | submitted |
| Sun 12:30 | — | **Judging: live demo** (script in §10) | 🏆 |

Cut order if behind: 7700 auto-detect → ElevenLabs voice → fields/land-cover heuristics
(keep ditch) → terrain gate → turn-intersect refinement. **Never cut:** envelope +
airport ranking + map + **weather strip** + replay fallback + the 3 scenarios.

Solo rules: single-file frontend; deploy before sleep; every feature lands as a curl-able
endpoint first, UI second; stuck on Jac syntax > 20 min → ask Jac-GPT
(jac-gpt.jaseci.org) or the Discord bot instead of grinding.

---

## 10. Demo script (Sunday, ~3 min)

1. **Cold open** — radar live map, real traffic over Michigan (or replay badge if needed).
   "This is what a controller sees. Now it goes wrong." → click a real airliner at cruise
   → check *"both engines out"* → **DECLARE**.
2. **The compute** — envelope blossoms over the map, wind-distorted; countdown appears;
   candidates pop with scores in <1 s. Read the top line aloud: name, runway, margin, headwind.
3. **The weather line** — field-conditions strip: "22R: 12 kt headwind, 3 kt crosswind, dry,
   visual." — "The runway choice isn't just the closest one; it's the one the wind picks."
4. **The radio** — advisory panel shows the exact transmission to read. (If ElevenLabs
   stretch landed: it *speaks* as ATC.) Mention checklist.
5. **The switch** — same flight, change to *"fuel leak / not enough power"* → recompute:
   drift-down mode, fuel-limited countdown, different site choice. "Different physics,
   different advice."
6. **The fallback** — replay 1549-over-water-style case → no runway reachable → **ditch
   point + checklist**. "The system tells the truth when the truth is hard."
7. **Close on the graph** — open `/graph`: "Every option you just saw is a node. The decision
   was a walker walking it. That's why this is in Jac — the airspace is a graph, and Jac
   is a graph language." Show `jac_ratio.py` output ≥ 50%.

Devpost "How we used Jac" = section 3 + 4 of this plan, tightened to ~150 words.

---

## 11. Risks & mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| OpenSky rate limits / outage | Medium | OAuth2 creds (10× quota); poll one aircraft; 30 s cache; REPLAY fallback (demo never dies) |
| Jac learning curve burns hours 0–3 | Medium | Spike first (hour 1); lean on Jac-GPT (jac-gpt.jaseci.org), Discord #ninjaclaw-yap-room, on-site mentors + Sat 11:30 workshop |
| `requests`-in-Jac friction | Medium | Jac compiles to Python bytecode & imports Python libs; worst case the poller is a tiny Python module called from Jac |
| Static-serving via Jac unclear | Medium | Confirm in hour-1 spike; fallback static host + CORS |
| Full-dynamics rabbit hole | High 😅 | Physics is constants + closed-form math, no integration loop. Historical-trio tests keep us honest; gates and weights are tuned, not derived |
| Frontend time sink | High | Leaflet + vanilla JS only; no build tooling; dark tiles; ugly-but-working first |
| 40% measurement dispute | Low | Target 60%+; print evidence via `jac_ratio.py`; keep Python only where it's clearly tooling |
| Sleep-deprived demo | Certain | Rehearse 3× Sunday morning; freeze features Sat 23:00 |

---

## 12. Success criteria (self-judged before submission)

- [ ] Declare-emergency → advisory JSON on live OpenSky data in <1 s compute
- [ ] Wind-distorted envelope renders correctly (sanity: downwind lobe longer)
- [ ] Field conditions live per candidate: headwind/XW/wet/DA/VMC from Open-Meteo, crosswind gate enforced
- [ ] 3 scenarios run clean: airport / drift-down switch / ditch fallback
- [ ] Gimli, Air Transat 236, 1549 validation tests pass within 15%
- [ ] Jac ≥ 50% of code, measured and screenshotted
- [ ] Deployed on Jac Hammer, URL in Devpost
- [ ] Demo video recorded; Devpost + README complete
- [ ] `/graph` screenshot in README (the "whiteboard is the data model" proof)

**Next action (12:30 PM today):** git init, `jac run` hello-walker, OpenSky account
registration, OurAirports download — in parallel.
