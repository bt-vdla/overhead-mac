# Overhead

A menu bar app for macOS 26. When an aircraft passes visibly overhead, a panel drops out of the notch and shows the flight live.

## Architecture

```
Overhead/
├─ Core/                     Swift package, pure Foundation, no UI. `swift test` runs on any Mac or Linux.
│  ├─ Sources/OverheadCore/
│  │  ├─ Sky.swift           Geometry and decisions: look angles (WGS84 ENU), dead reckoning, the
│  │  │                      1.5 s correction blend, the overhead trigger, the panel's phase machine.
│  │  └─ Feed.swift          Wire formats (adsb.lol point, adsbdb callsign), replay recorder and player,
│  │                         synthetic flyover.
│  └─ Tests/OverheadCoreTests/
└─ App/                      The macOS target (XcodeGen, project.yml)
   ├─ OverheadApp.swift      MenuBarExtra, Settings, SwiftData history model, the "thop"
   ├─ Tracker.swift          Poll loop (power, screen sleep), location, route cache, history logging
   └─ Panel.swift            Borderless NSPanel over the notch, expanded view, compact pill, map, sky dome
```

How data flows on each poll:

1. **Source** gives raw JSON: live adsb.lol, live plus recording to disk, a recorded replay, or a synthetic flyover. Replays carry their own spoofed observer.
2. **Ingest**: each aircraft becomes a `Fix`, timestamped as the time it arrived minus `seen_pos`. That means replays never depend on server clocks. Each aircraft's `Motion` takes the new fix and blends from where it was being drawn, so nothing teleports.
3. **Decide**: `Pass.triggers` checks elevation ≥ 25° and slant range ≤ 25 km, now or at any second in the next 20 s along the dead-reckoned path. `Presenter` picks the highest aircraft. It runs hidden → expanded (60 s) → compact, and stays shown until the shown aircraft drops below 15°.
4. **Show**: the panel reads `Tracker` (an `@Observable`). Only the aircraft glyph and the numbers redraw at display refresh, inside a `TimelineView`. The map itself stays still.
5. **Log**: one SwiftData `Passover` per triggering aircraft per pass, with its peak elevation. Its route fills in when adsbdb answers.

Polling: every 10 s on power and 30 s on battery (60 s in Low Power Mode). It stops while the screen sleeps and polls straight away on wake.

## Endpoints

Not yet verified live from this repo's build environment, because the network was blocked. Check them once:

```bash
curl -s https://api.adsb.lol/v2/point/51.47/-0.45/50 | head -c 600
curl -s https://api.adsbdb.com/v0/callsign/BAW117
```

What the decoders expect:
- **adsb.lol**: `{"ac":[{"hex","flight","t","desc","r","lat","lon","alt_baro":<ft or "ground">,"alt_geom","gs","track","baro_rate","geom_rate","seen_pos"}],"now":<ms>}`. Every field except `hex` is optional.
- **adsbdb**: `{"response":{"flightroute":{"callsign","airline":{"name"},"origin":{…},"destination":{…}}}}`. An unknown callsign returns HTTP 404 with `{"response":"unknown callsign"}`.

If either API differs, record a session in Overhead (Source → Record) and fix the matching `Decodable` in `Feed.swift`. Then add a test.

## Develop

- **Replay first.** In the menu, Source → Synthetic Flyover needs no network and no location. It flies one aircraft straight over a spoofed observer, plus a second one nearby so the badge shows.
- **Record → Replay.** Recording saves every live response under `~/Library/Containers/com.btstd.overhead/Data/Library/Application Support/Overhead/Recordings/<date>/`, along with `meta.json` for the observer. Replay loops the newest recording.

```bash
cd Overhead/Core && swift test          # math, decoding, phase machine
cd Overhead && xcodegen && open Overhead.xcodeproj
```

Set `DEVELOPMENT_TEAM` in `project.yml` before building.
