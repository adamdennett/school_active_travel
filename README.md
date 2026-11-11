# School active travel: walking and cycling routes to every school in England

Origin–destination matrices from every Census 2021 Output Area in England to every
mainstream school within 120 minutes' walk. They are inputs for estimating how many
children could walk, wheel or cycle to school, and where, alongside an individual-level
model from the National Travel Survey. Every route has its walking and cycling times,
its distance, a full height profile and its climb each way.

## What is produced (`data/out`, not committed)

| Output | What it holds |
|---|---|
| `origins.parquet` | 178,605 Output Areas: population-weighted centroid, LSOA, MSOA, local authority, rural–urban class, children by age band (0–4, 5–9, 10–14, 15–19), households by cars or vans, household deprivation, 2021 OAC, and the routing tile |
| `schools.parquet` | 21,834 open mainstream schools from GIAS: phase, age range, `serves_primary`/`serves_secondary`, state or independent, selective, faith, gender, pupils, capacity, % FSM, trust |
| `oa_nearest.parquet` | each Output Area's three nearest primary and secondary schools in a straight line, at any distance, so places with nothing walkable are still described |
| `od/la=*/` | one row per Output Area and school within 120 minutes' walk (see columns below) |
| `profiles/la=*/` | `elev_dm`: ground height in decimetres every 50 m along the walking route, from home to school |
| `routes/la=*/` | the walking route line as WKB, British National Grid (EPSG:27700), simplified to 5 m |
| `tile_summary.csv` | pairs, routed pairs and cycling coverage for each tile |

The three route outputs are filed by the local authority (district or unitary, 2025
boundaries) of the home Output Area, one folder each, named by code and name, e.g.
`od/la=E06000043_brighton_and_hove/`. An authority that spans two routing tiles has one
file from each in its folder. `arrow::open_dataset("data/out/od")` reads all of England
as one table, and filtering on `la` opens only that authority's files.
`R/read_helpers.R` has functions to read an authority, a route's height profile and its
line; `R/example_profile.R` draws one (`docs/example_profile.png`).

To rebuild a profile's distances: point *i* (from 0) is *50·i* metres from home, and
the last point is the school, at `route_m`.

### Columns of `od`

| Column | Meaning |
|---|---|
| `oa21cd`, `urn` | Output Area and school |
| `straight_m`, `route_m`, `circuity` | straight-line distance, walking-route distance, and their ratio |
| `walk_min_r5` | walking time at 4.8 km/h on the flat (r5r travel-time matrix); this sets who is in reach |
| `walk_min_route` | the same from the routed path (r5r detailed itinerary) |
| `tobler_min_to_school`, `tobler_min_to_home` | walking time each way allowing for slope (Tobler's hiking function, scaled so the flat is 4.8 km/h) |
| `bike_min_lts2`, `bike_min_lts4` | cycling time at 12 km/h on quiet streets only (level of traffic stress 2) and on any street a bike may use (LTS 4); empty where there is no such route within 120 minutes |
| `z_home`, `z_school`, `z_max` | ground height at each end and the highest point (metres) |
| `climb_to_school_m`, `climb_to_home_m` | total ascent each way (metres) |
| `max_grad_to_school`, `max_grad_to_home` | steepest 50 m going uphill each way (rise over run) |
| `steep5_*_m`, `steep8_*_m` | metres of route steeper than 5% and 8% uphill, each way |
| `r5_route_m` | route length as r5r reports it (a check on `route_m`) |

Times at another walking speed scale linearly: at 3.6 km/h, multiply the flat times by 4.8 / 3.6.

## Running it

```bash
DEADLINE="2026-11-12 07:00" ./run.sh     # first night: stops cleanly at 07:00
DEADLINE="2026-11-13 07:00" ./run.sh     # second night: carries on where it stopped
touch data/PAUSE                           # or stop at the next chunk, at any time (delete it to restart)
```

The whole of England is about 23–28 million pairs. On the test machine (16 cores,
64 GB) that is roughly 11–14 hours: a few minutes clipping streets, 1–2 hours building
networks, about 8 hours of routes and profiles, 2–3 hours of cycling times. The machine
must not sleep while it runs.

`run.sh` builds the frame if it is missing (`R/01_frame.R`), clips the streets for each
tile (`R/02_osm.R`), routes each tile in its own process (`R/03_route.R`), and gathers each
finished tile into `data/out` (`R/04_assemble.R`). Everything is saved as it goes, so a
stop loses at most one chunk of 20,000 routes. Logs are in `logs/`.

Needs R 4.5 with r5r, sf, terra, data.table, arrow, dplyr, nabor and blob; Java 21 for r5r;
Osmosis 0.49 for clipping. The large inputs are read from the sibling `school_value_added`
project (set `SVA_DIR` if it is elsewhere).

## Method and sources

**Origins.** ONS population-weighted centroids of 2021 Output Areas (England, 178,605).
Census 2021 topic summaries at Output Area level: TS007a (age), TS045 (cars or vans),
TS011 (household deprivation). ONS lookups for LSOA, MSOA, local authority (2023) and
the 2021 rural–urban classification; the 2021 Output Area Classification.

**Schools.** Get Information about Schools, all establishments, 10 June 2026. Open schools
in England in the academy, free school, local-authority-maintained and independent groups,
excluding special schools, alternative provision, studio schools and 16–19 schools. A
school counts as teaching primary ages if its lowest age is 10 or under and its highest 7
or over, and secondary if its lowest is 14 or under and its highest 12 or over (all-through
and middle schools count as both where their ages say so). Location is GIAS's easting and
northing.

**Reach.** A school is in reach of an Output Area if r5r finds a walking route of at most
120 minutes at 4.8 km/h, that is about 9.6 km. The fixed 4.8 km/h keeps the set generous;
reach at a slower pace, or by slope-adjusted time, is a filter on the columns.

**Streets.** OpenStreetMap, Geofabrik England extract, clipped by Osmosis to each tile.
England is cut into 60 km tiles on the National Grid; a tile routes its own Output Areas
to schools within 10 km of it, on streets within 12 km of it. A 9.6 km route cannot leave
a 9.6 km circle round its start, so no route is cut off at a tile edge.

**Routing.** r5r 2.5.0 with R5 7.6, no public transport. (On the Brighton tile, R5 7.6
gave the same walking time as R5 7.4 for 98% of pairs, and cycling times 0.2 minutes
longer on average, with cycling 3.5 times faster to compute.) `walk_min_r5` sets reach;
for analysis, `route_m` with a chosen speed, or the Tobler times, describe the route
itself (r5r's matrix times run about 0.6 minutes shorter than `route_m` at 4.8 km/h). Walking: the travel-time matrix sets the
pairs, then a shortest-path itinerary for each pair gives the line. Cycling: travel-time
matrices at 12 km/h with the maximum level of traffic stress at 2 and at 4. The cycling
times are on R5's cycling network, but their climb is described by the walking route,
which on most journeys follows the same streets.

**Height.** OS Terrain 50 (50 m grid), interpolated bilinearly at points every 50 m along
each walking route. Climb, steepest 50 m and steep lengths come from that profile, each
way. The terrain is the ground, so bridges and underpasses show the valley or hill beneath
them. Tobler's hiking function, `v = 6·exp(−3.5·|s + 0.05|)` km/h, scaled so the flat is
4.8 km/h, gives slope-adjusted walking times.

This follows the routing in `school_value_added` (R/20, R/22, R/27), where the same
approach was used for 109 urban authorities.
