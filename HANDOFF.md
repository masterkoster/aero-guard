# HANDOFF

State of AERO-GUARD for whoever picks this up next. Written by the instance
that built the decision engine. Read this before touching code — a lot of it
records mistakes that already cost debug cycles.

**Verify anything here that matters.** This file was written from one machine's
session; numbers marked *verified* were run, the rest are intent.

---

## Mission

AERO-GUARD is emergency ATC decision support for [JacHacks](https://jachacks.tech)
A2Tech 2026. Given an aircraft in trouble, it answers *where does this land?*
with a physics model plus a graph walk over 1,740 real airports.

**Solo build.** Demo region is Michigan / DTW.

### Non-negotiable rules

1. **All code must be committed during hacking hours.** Organizers read commit
   history. Commit early, commit often, never leave the tree dirty.
2. **≥40% of the code must be Jac.** Currently 75.5%. Recompute with
   `python3 scripts/jac_ratio.py` after any change that adds Python.
3. **Keep the physics honest.** Every constant carries its provenance in a
   comment. When a number is tuned to match a real accident, say which one. Do
   not claim a validation the model does not actually pass (see Issue 1 — I did
   exactly that, and it had to be walked back).

### Deadlines

| When | What |
|---|---|
| Sat 23:30 | Deploy to Jac Hammer as insurance (coupon `JACHACKS-UMICH`, or `sandbox`) |
| Sun 00:30–06:30 | **Sleep.** Non-negotiable; do not start anything you can't finish tonight |
| Sun 09:30 | Devpost draft committed as a checkpoint |
| Sun 12:00 | Devpost final submission — hard deadline |
| Sun 12:30–14:00 | Judging |

### Tracks

Developer Tools, Agentic AI, Best Jaclang, Best of ElevenLabs (stretch).
Skip Local Impact.

Best Jaclang angle: the `EmergencyAdvisor` walker accumulates per-node and
delivers once via `with Root exit`. That is a real, explainable graph-walker
idiom — worth writing up properly rather than leaving as an implementation
detail.

---

## Where things are

```
main.jac              API service; :pub walkers are HTTP endpoints
src/physics.jac       flight dynamics + the aircraft performance database
src/archetypes.jac    graph schema: node Airport, node Runway, edge HasRunway
src/data_loader.jac   JSON boundary casts, bbox query, graph load
src/advisor.jac       EmergencyAdvisor -- the walker that decides
tools/engine_test.jac 4 end-to-end scenarios with rejection reasons
tools/smoke.jac       physics unit checks
tools/probe_edges.jac graph query shape probes
tools/probe_walk.jac  isolates the disengage-vs-return behaviour
scripts/prep_airports.py  OurAirports CSVs -> data/airports.json
scripts/serve.py      launches the API server detached
scripts/jac_ratio.py  the >=40% checker
```

Dataset: `data/airports.json`, 1,740 airports / 2,322 runways, committed.
bbox `-98 36 -52 52`.

---

## What works (verified)

`jac run tools/engine_test.jac`, all four scenarios, ~5.9s total:

| Scenario | Result |
|---|---|
| Air Canada 143 (Gimli) | **CYGM** Gimli, 2.4 nm, rwy 15/33 6,800 ft vs 6,600 needed, +200 ft |
| A330 North Atlantic | **CYDF** Deer Lake, 54.3 nm, 8,005 ft vs 7,812 needed, +193 ft |
| US Airways 1549 | **KTEB** Teterboro, 6.0 nm, 6,997 ft vs 6,240 needed, +757 ft |
| Michigan 737-800 | **KGRR** 36.6 nm +3,641 ft, then KLAN, KBTL, KMBS |

Gimli and US Airways 1549 are genuine validations: the model picks the same
field the crew actually used. Both are conservative (less margin than the crew
had), which is the safe direction.

The Michigan case visits 160 airports, 11 usable, 104 rejected, in 4.9s. That
is the realistic workload and the realistic latency.

**Envelope radii (verified after the ceiling fix):** Gimli 30.9 nm, A330 73.1 nm,
US Airways 7.7 nm, Michigan 86.4 nm. Drift is applied as an offset of the
circle's centre, not a symmetric inflation.

---

## Open issues, highest value first

### 1. The Air Transat validation is wrong. Decide what to do.

The scenario is labelled Air Transat 236, but the real flight does not match
what the code claims:

- It is **24 August 2001**, not 1999.
- Cause was **fuel exhaustion from a fuel-line fracture**, not a fire. Not
  `FIRE`; it is `FUEL_LEAK`.
- It landed at **Lajes Air Base, Azores (38.76 N, 27.09 W)** after a **65 nm
  (120 km)** glide from FL390 — *not* Gander, and not "3h26m".
- Lajes is **outside the dataset bbox** (`-52` is the eastern limit; Lajes is
  at `-27`), so the real destination is not in the graph.
- The scenario is placed at 48.6 / -58.5, which is **157 nm** from Gander, not
  the ~60 nm previously assumed. At a 73 nm glide radius nothing near Gander is
  reachable from there, which is why the model returns Deer Lake.

I have already relabelled the scenario to "A330 over the North Atlantic —
fuel exhaustion" and changed `FIRE` → `FUEL_LEAK`, so nothing false is
asserted any more. But it is **not** a historical validation.

Two ways forward, pick one:

- **(a) Extend the bbox east to about -25 and replay the real flight.** Highest
  credibility — the Azores Glider is a great demo story and a 65 nm glide is a
  beautiful physics test. Cost: the dataset grows well past 1,740 airports and
  the cold graph build gets worse (see Issue 4). This is the expensive option.
- **(b) Replace it with a real accident inside the current bbox.** Cheap and
  safe. **United Airlines 232** (19 Jul 1991) fits: DC-9, all three engines lost
  to bird ingestion at FL37,000, glided to Sioux Gateway (SUX) at 42.5 N,
  96.4 W — comfortably inside the bbox. ~46 nm glide. A DC-9 is not in the
  aircraft DB yet, so it needs a `spec_for` entry.

**Recommend (b) for the remaining time**, and mention (a) as future work. A
third *correct* validation is worth more than a famous wrong one.

Either way, the A330's `ld_max=12.0` is **~15% optimistic**: the real aircraft
achieved about 10:1. If you keep the A330, drop it to `11.0`.

### 2. VMC/IMC was never implemented

The ceiling bug is fixed — a cloud ceiling no longer caps how high you can
glide from (it was clipping the A330 to 23.7 nm; it is now 73.1 nm, correct).
But the intended replacement never landed: there is **no VMC/IMC flag and no
low-ceiling scoring penalty**. `ceiling_ft` is currently only echoed into the
output. `grep -ri "vmc\|imc" src/` returns nothing.

To do: flag `ceiling_ft < 1500` as IMC, penalise it in scoring, surface it in
the UI conditions strip.

### 3. The test and the API disagree about the same scenarios

`tools/engine_test.jac` hardcodes `tas_kt=210.0, track_deg=250.0, fuel_min=0.0,
ceiling_ft=12000, max_candidates=4` inside `show()`. The scenarios in
`main.jac` have different values — e.g. the API's Gimli has `ceiling_ft: 8000`
and its A330 has `tas_kt: 290 / track_deg: 265`.

So a green `engine_test.jac` does **not** mean the demo scenario looks like the
test. Either give `show()` the same parameter list, or better, have the test
read the same scenario table the API uses. Worth fixing before a judge notices
the demo behaving differently from the tests.

### 4. Cold graph build takes ~110s

1,740 airports / 2,322 runways. Warm reload is 0.4s (*verified* — the
`[load] 1740 airports, 2322 runways in 0.4s` line). `jac run <file>` reuses the
persisted graph in `.jac/`; `jac run --serve` appears to use a different
workspace and rebuilds.

Untested idea: untyped `++>` edges may build faster than the typed `HasRunway`
edge. Not worth much time.

Practical answer: start the server long before you need it. Do not let a judge
watch a cold start.

### 5. The server has never actually stayed up

`scripts/serve.py` implements a double-fork daemon so the process reparents to
init. Everything simpler failed on this machine — `&`, `nohup`, `screen`, and
`start_new_session=True` were all reaped when the launching shell exited, and
`launchctl submit` is blocked by macOS TCC on `~/Documents`.

**The double-fork is the only approach not yet proven to survive**, because
every attempt to verify it crossed a shell boundary. If the server dies on
arrival there, that is probably why. Test it first; it gates the frontend and
the deploy.

---

## Jac gotchas

These each cost a debug cycle. All still true on jaclang 0.16.7.

### Syntax

- `return` needs a trailing semicolon. Brace imports (`import from x { y }`)
  take **no** semicolon.
- No backslash line continuations.
- `elif`, not `else if`.
- **In-body docstrings break the parser.** Use `#` comments inside a body.
- `True` / `False` / `None` are capitalised.
- In an `obj`/walker, non-default `has` fields must precede defaulted ones.
- A `:` inside an f-string breaks parsing. Hoist the value to a variable first.
- `as` casts inside a comprehension's iterable do not parse. Hoist to a variable.

### Typing

- `any` will not flow into a typed destination. At untyped boundaries (JSON,
  walker reports) use `value as Type`.
- `round(x, n)` has no overload. Use the `r0` / `r1` / `r2` helpers in
  `src/physics.jac`.
- `abs()` is untyped — use `math.fabs`.
- `sort(key=...)` is unsupported. Sort `[score, index]` float pairs in natural
  order instead; that type-checks and is stable.

### Walker semantics

- **`disengage` in a walker ability terminates the entire walk**, including
  `Root exit` abilities. For per-node early exit use `return;`.
  `tools/probe_walk.jac` isolates this.
- Multi-hop queries are chained arrows with a per-hop filter:
  `[root-->[?:Airport]-->]` returns all Runway nodes (2,322).
  `-->>` is a **parse error**.
  `[root->:HasRunway:->]` returns 0 — the edges are Airport→Runway, not
  root→Runway.

### Toolchain

- `jac check <file>` type-checks. **`jac run <file>` does not** — always `check`
  first or you will ship a type error.
- `jac create --kind api-service` scaffolds `jac.toml`.
- `jac guide <name>` ships reference guides. Read them.
- `jac start main.jac --no_client` (underscore) — but see Issue 5.
- `jac clean --all` prompts interactively and aborts non-interactively.
  Use `rm -rf .jac` for a forced clean rebuild (required after changing
  `airports.json`, or the stale graph is reused).

---

## Commands that work

```bash
# type-check (do this before every run)
.venv/bin/jac check src/advisor.jac

# run the engine end to end
.venv/bin/jac run tools/engine_test.jac
.venv/bin/jac run tools/smoke.jac

# serve the API, detached; polls until actually ready
python3 scripts/serve.py
python3 scripts/serve.py --stop

# the >=40% check
python3 scripts/jac_ratio.py --verbose

# rebuild the dataset from the OurAirports CSVs in data/raw/
python3 scripts/prep_airports.py
```

`walker:pub` endpoints need no auth — anonymous callers share a guest graph.
Swagger is at `/docs`, graph view at `/graph`.

---

## Recommended order of work

1. **Verify the server stays up** (Issue 5). Everything else needs it.
2. **Fix Issue 3** — make the test and the API share scenarios.
3. **Fix Issue 2** — VMC/IMC flag and low-ceiling penalty. Small, and it is
   explicitly in the project scope.
4. **Decide Issue 1.** Recommend option (b), United 232.
5. **Build the console** — single-file HTML + Leaflet from CDN, no build
   tooling. Shows the envelope polygon, the aircraft, and the ranked fields
   with their numbers. This is the demo, and it is currently the single
   biggest gap.
6. **`src/weather.jac`** — Open-Meteo, 15-minute cache, a `FieldConditions` obj
   per candidate site feeding headwind/crosswind per runway, crosswind gate,
   gust spread, wet runway, density altitude, VMC/IMC, winds aloft.
7. **OpenSky poller** with a REPLAY fallback. Anonymous OpenSky is heavily
   rate-limited — register OAuth2 client credentials early, poll a single
   aircraft, cache it, and make sure the demo survives with the network off.
8. **Deploy to Jac Hammer** before sleeping Saturday.
9. **Devpost** draft Sunday 09:30.

---

## OpenSky setup

Anonymous OpenSky is too rate-limited to rely on. Register OAuth2 client
credentials early — it is a web form and may need manual approval. Then poll a
single aircraft rather than a bounding box, cache aggressively, and keep the
REPLAY path working so an offline demo still runs.

The `scan_live` walker currently just reports graph state and the string
`"source": "replay"`. That is the seam the live feed attaches to.

---

## Rescue resources

- `jac-gpt.jaseci.org` — Jac language assistant
- Discord `#ninjaclaw-yap-room`
- On-site mentors; check-in was Sat 17:30
