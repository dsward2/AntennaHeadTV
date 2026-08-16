# AntennaHeadTV

A tvOS SwiftUI client for AntennaHead, talking to the Mac app's `/api/v1/...`
JSON API (see [AntennaHeadAPI](https://github.com/dsward2/AntennaHeadAPI))
instead of embedding the web UI — tvOS has no user-facing browser, and the
existing HTML/JS UI assumes a mouse/touch pointer the Siri Remote's focus
engine can't drive. See the feasibility study this implements the first
real client for.

This is a sibling repo in the `antennahead-umbrella` workspace, independent
of `AntennaHead` itself (own history/issues/PRs), coupled to it only through
the shared `AntennaHeadAPI` package — matching how `AntennaHead` and
`ControlBooth` are already independent repos tied together by shared
packages.

## Status: scaffolding

A minimal but working client: connect to a Mac by address, browse
favorites/categories, tune/scan/stop, see now-playing status. Verified via
`xcodebuild build` for the tvOS Simulator (Xcode's own toolchain, no
`xcodegen` or other generator — the `.xcodeproj` is hand-authored, mirroring
`AntennaHead.xcodeproj`'s own conventions).

**What's here:**

| File | Purpose |
|---|---|
| `AntennaHeadTVApp.swift` | App entry point. |
| `AntennaHeadAPIClient.swift` | Thin `URLSession` wrapper over `AntennaHeadAPI`'s types/endpoints. Plain HTTP, no auth yet — see below. |
| `AntennaHeadViewModel.swift` | `@Observable` state: connection, now-playing, favorites, categories. |
| `ContentView.swift` | `ConnectScreen` (manual host entry) → `NowPlayingScreen` (now-playing + Stop, tappable favorites/categories lists, `List` gets Siri Remote focus navigation for free). |

**Deliberately not built yet** (see the feasibility study for the full list):

- **Discovery.** No Bonjour pairing — the host is typed in manually
  (`host:port`, e.g. `192.168.1.23:8090`). AntennaHead already advertises
  itself as generic `_http._tcp`/`_https._tcp`; a dedicated service type for
  unambiguous discovery from this app is the natural next step.
- **HTTPS / Basic Auth.** The client only speaks plain HTTP with no
  credentials, unlike the web UI. Fine for getting the rest of the app built
  and tested; not fine to ship as-is if AntennaHead's HTTPS/auth is enabled.
- **Push updates.** `NowPlayingScreen` polls `/api/v1/now-playing` every 2
  seconds, matching the web UI's own cadence. An SSE/WebSocket channel is a
  flagged follow-up once there's a second client (watchOS) that would also
  benefit from it.
- **Everything beyond browse/tune/scan/stop** — recordings, AirPlay/
  ControlBooth source switching, device tuning, scanner category editing.
  Scope was deliberately kept to what proves the API contract end to end;
  see the feasibility study's note on tvOS aiming for a fuller feature set
  over time, not starting as a 1:1 port.

## Building

Open `AntennaHeadTV.xcodeproj` in Xcode (needs `AntennaHeadAPI` checked out
as a sibling directory — see `antennahead-workspace`'s bootstrap), or:

```bash
xcodebuild -scheme AntennaHeadTV -destination 'platform=tvOS Simulator,name=Apple TV' build
```
