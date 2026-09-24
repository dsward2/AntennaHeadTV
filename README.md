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

## Status: working, growing toward parity

Verified end to end on real hardware (Apple TV 4K): connect to a Mac by
address, browse favorites/categories, tune/scan/stop, hear the live stream,
and — as of this pass — use Devices, Recordings, and ControlBooth
source switching too. Also verified via `xcodebuild build` for the tvOS
Simulator (Xcode's own toolchain, no `xcodegen` or other generator — the
`.xcodeproj` is hand-authored, mirroring `AntennaHead.xcodeproj`'s own
conventions).

**Layout:** a persistent Now Playing strip across the top (station,
frequency, status, plus Captions, Spatial Audio, and Stop), with a fixed
sidebar of sections on the left and the selected section filling the rest.
The sidebar groups Radio (Favorites, Categories), Live Sources (Devices,
Listen to Gqrx, AirPlay Receiver, ControlBooth), and Files & Speech
(Recordings, Play Audio Files, Text to Speech, Speak RSS Headlines).

**tvOS gotchas hit and fixed:**

- The sidebar is a plain fixed-width column, not `NavigationSplitView`:
  that sidebar resizes and slides as Siri Remote focus moves between
  columns. A top `TabView` avoided that, but ran out of room as sources
  were added.
- Sidebar rows are `Button`s that set the selection, not
  `List(data, selection:)`: that selection binding doesn't reliably fire
  from a Siri Remote press on tvOS.
- Buttons inside a `List` section header aren't focusable, so Select All /
  Select None sit in their own row above the list.

**What's here:**

| File | Purpose |
|---|---|
| `AntennaHeadTVApp.swift` | App entry point. |
| `AntennaHeadAPIClient.swift` | Thin `URLSession` wrapper over `AntennaHeadAPI`'s types/endpoints. Plain HTTP; sends AntennaHead's web login (Basic Auth) when one is entered. Also holds `WebLogin` and the Keychain helper for its password. |
| `AntennaHeadViewModel.swift` | `@Observable` state for the connection and every section (now-playing, favorites, categories, devices, recordings, ControlBooth/AirPlay status, Gqrx status, the Play Audio Files and Text to Speech folder listings, RSS feeds), loaded lazily per section rather than all upfront. Also owns the shared `AVPlayer`: normally pointed at AntennaHead's HLS mount (`/hls/index.m3u8`, same host:port as the JSON API, since the live stream reflects whatever's currently tuned rather than being per-frequency), but swappable to a recording's Range-capable download URL for real seek support, then back to live the next time a listen action runs — mirrors the web UI's own live/download-mode `<audio>` element switching (`Web/index.html`). |
| `ContentView.swift` | `ConnectScreen` (Bonjour list + manual host entry) → `MainScreen`: the Now Playing strip, the sidebar, and one detail view per section. |

**Deliberately not built yet** (see the feasibility study for the full list):

- **Discovery.** No Bonjour pairing — the host is typed in manually
  (`host:port`, e.g. `192.168.1.23:8090`). AntennaHead already advertises
  itself as generic `_http._tcp`/`_https._tcp`; a dedicated service type for
  unambiguous discovery from this app is the natural next step.
- **Self-signed HTTPS.** **Use HTTPS** on the connect screen works with a
  certificate the Apple TV already trusts (e.g. Tailscale or Let's Encrypt,
  loaded into AntennaHead as a user-supplied `.p12`). Enter the certificate's
  name and AntennaHead's HTTPS port, e.g. `mac.example.com:8094`. AntennaHead's
  own self-signed certificate isn't trusted, and AVPlayer can't be told to
  trust it. AntennaHead's web login (Basic Auth) is supported over HTTP or
  HTTPS: enter the username and password on the connect screen (the password
  is kept in the Keychain), and they're sent with API calls, the live stream,
  and recording playback.
- **Push updates.** Now Playing polls `/api/v1/now-playing` every 2 seconds,
  matching the web UI's own cadence. An SSE/WebSocket channel is a flagged
  follow-up once there's a second client (watchOS) that would also benefit
  from it.
- **Tuner, Settings, Custom Tasks, Scanner category editing.** Form-heavy
  admin surfaces (typing a frequency, Sox filter strings, streaming bitrate)
  that fit a keyboard/mouse better than a Siri Remote — left for a later
  pass, not forced into this UI. Devices' Sox output-filter field is
  similarly skipped in favor of `StartDeviceRequest`'s `"vol 1"` default.

## Building

Open `AntennaHeadTV.xcodeproj` in Xcode (needs `AntennaHeadAPI` checked out
as a sibling directory — see `antennahead-workspace`'s bootstrap), or:

```bash
xcodebuild -scheme AntennaHeadTV -destination 'platform=tvOS Simulator,name=Apple TV' build
```
