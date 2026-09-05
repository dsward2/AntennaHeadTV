import AntennaHeadAPI
import SwiftUI
import UIKit

/// Manual host entry (no Bonjour discovery yet — see the feasibility study's
/// open item on pairing) → a master-detail layout: a sidebar of sections on
/// the left, each section's content filling the right. See
/// `AntennaHeadAPI`'s README and the feasibility study for what's still
/// deferred (Tuner, Settings, Custom Tasks, Bonjour discovery, HTTPS/auth,
/// push-based status).
struct ContentView: View {
    @AppStorage("AntennaHeadTV.host") private var host = ""
    @State private var viewModel: AntennaHeadViewModel?

    var body: some View {
        if let viewModel, viewModel.isConnected {
            MainScreen(viewModel: viewModel)
        } else {
            ConnectScreen(host: $host, viewModel: viewModel) {
                let model = viewModel ?? AntennaHeadViewModel(host: host)
                model.host = host
                viewModel = model
                await model.connect()
            }
        }
    }
}

/// Host entry + Connect. Kept as a plain `TextField` rather than anything
/// fancier — tvOS's on-screen keyboard handles it fine, and this is meant to
/// be replaced by Bonjour discovery, not polished as a permanent UI.
private struct ConnectScreen: View {
    @Binding var host: String
    var viewModel: AntennaHeadViewModel?
    var connect: () async -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
            Text("Connect to AntennaHead")
                .font(.title)
            Text("Enter the Mac's address, e.g. 192.168.1.23:8090 — shown in AntennaHead's own window.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            TextField("host:port", text: $host)
                .frame(maxWidth: 480)

            Button {
                Task { await connect() }
            } label: {
                if viewModel?.isConnecting == true {
                    ProgressView()
                } else {
                    Text("Connect")
                }
            }
            .disabled(host.isEmpty || viewModel?.isConnecting == true)

            if let message = viewModel?.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
        }
        .padding(60)
    }
}

/// The sidebar's sections. Deliberately a subset of the web UI's own top
/// menu (Favorites, Categories, Tuner, Recordings, Devices, ControlBooth,
/// Settings, Info) — Tuner (manual frequency entry) and Settings
/// are form-heavy admin surfaces that fit a keyboard/mouse better than a
/// Siri Remote, and are left for a later pass rather than forced in here.
/// Not `private` — `AntennaHeadViewModel` owns `selectedSection` (so every
/// "start listening to X" action can jump the user to Now Playing from
/// wherever it's called) and needs the type visible too.
enum SidebarSection: String, CaseIterable, Identifiable {
    case nowPlaying = "Now Playing"
    case favorites = "Favorites"
    case categories = "Categories"
    case devices = "Devices"
    case recordings = "Recordings"
    case controlBooth = "ControlBooth"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .nowPlaying: "waveform"
        case .favorites: "star.fill"
        case .categories: "square.stack.3d.up.fill"
        case .devices: "mic.fill"
        case .recordings: "recordingtape"
        case .controlBooth: "slider.horizontal.3"
        }
    }
}

/// Top-level navigation as a persistent top tab bar, not `NavigationSplitView`'s
/// sidebar: that sidebar column dynamically resizes/slides based on which
/// column currently has Siri Remote focus (standard tvOS `NavigationSplitView`
/// behavior), which reads as distracting motion rather than stable chrome —
/// reported directly against this screen. `TabView` on tvOS renders as a
/// fixed top tab bar that doesn't move or hide based on focus, and is the
/// platform's own idiomatic top-level navigation (matching system apps like
/// Music and TV), not a workaround standing in for a sidebar.
///
/// Each tab wraps its content in its own `NavigationStack` so that content's
/// `.navigationTitle` (set independently by `NowPlayingDetail`,
/// `FavoritesDetail`, etc.) still renders, and carries its own "Disconnect"
/// toolbar item — there's no single sidebar column left to hang one
/// modifier on for all of them.
private struct MainScreen: View {
    var viewModel: AntennaHeadViewModel

    var body: some View {
        TabView(selection: Binding(
            get: { viewModel.selectedSection },
            set: { viewModel.selectedSection = $0 }
        )) {
            ForEach(SidebarSection.allCases) { section in
                NavigationStack {
                    detail(for: section)
                        .toolbar {
                            ToolbarItem {
                                Button("Disconnect") {
                                    viewModel.disconnect()
                                }
                            }
                        }
                }
                .tabItem {
                    Label(section.rawValue, systemImage: section.systemImage)
                }
                .tag(section)
            }
        }
    }

    @ViewBuilder
    private func detail(for section: SidebarSection) -> some View {
        switch section {
        case .nowPlaying: NowPlayingDetail(viewModel: viewModel)
        case .favorites: FavoritesDetail(viewModel: viewModel)
        case .categories: CategoriesDetail(viewModel: viewModel)
        case .devices: DevicesDetail(viewModel: viewModel)
        case .recordings: RecordingsDetail(viewModel: viewModel)
        case .controlBooth: ControlBoothDetail(viewModel: viewModel)
        }
    }
}

/// Which of Now Playing's two sub-views is showing. Kept as local `@State`
/// (not on the view model) — unlike `SidebarSection`, nothing outside this
/// screen needs to switch it.
private enum NowPlayingTab: String, CaseIterable, Identifiable {
    case status = "Status"
    case captions = "Captions"
    case spatialAudio = "Spatial Audio"

    var id: String { rawValue }
}

/// Now-playing status (live stream or a recording, see
/// `AntennaHeadViewModel.isPlayingRecording`) + Stop, with Live Captions
/// (mirrors the web UI's `captions.html`) as a second tab rather than its own
/// sidebar entry — captions only mean anything while something's playing, so
/// they belong alongside Now Playing rather than beside it.
///
/// Owns the periodic now-playing poll — matches the web UI's own refresh
/// cadence; a real push channel (SSE/WebSocket) is the flagged follow-up once
/// there's more than one client depending on this.
private struct NowPlayingDetail: View {
    var viewModel: AntennaHeadViewModel
    @State private var tab: NowPlayingTab = .status

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let message = viewModel.errorMessage {
                Text(message)
                    .foregroundStyle(.red)
            }

            controlBar

            Group {
                switch tab {
                case .status: statusDetailContent
                case .captions: CaptionsSubview(viewModel: viewModel)
                case .spatialAudio: SpatialPositionSubview(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Now Playing")
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await viewModel.refreshNowPlaying()
            }
        }
        // Separate from the status poll above and only runs while the
        // Captions tab is showing — `.task(id:)` cancels and restarts this
        // loop whenever `tab` changes, so switching away from Captions stops
        // the extra polling rather than leaving it running unseen.
        .task(id: tab) {
            guard tab == .captions else { return }
            while !Task.isCancelled {
                await viewModel.refreshCaptions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Station name (or recording name) + frequency, the Status/Captions/
    /// Spatial Audio tab switcher, and Stop, all in one compact row instead
    /// of stacked as separate lines — frees up the vertical space below for
    /// whichever tab's content is showing (most visibly the Captions
    /// transcript, which now gets most of the screen instead of a fixed
    /// minimum height). The name/frequency stays visible no matter which tab
    /// is selected, same as before this consolidation.
    private var controlBar: some View {
        HStack(alignment: .center, spacing: 32) {
            nowPlayingHeader
                .layoutPriority(1)

            Spacer(minLength: 24)

            HStack(spacing: 16) {
                ForEach(NowPlayingTab.allCases) { candidate in
                    Button(candidate.rawValue) {
                        tab = candidate
                    }
                    .buttonStyle(.bordered)
                    .tint(candidate == tab ? .accentColor : nil)
                }
            }

            Button("Stop") {
                Task { await viewModel.stop() }
            }
            .disabled(!viewModel.isPlayingRecording && viewModel.nowPlaying?.taskMode == .stopped)
        }
    }

    @ViewBuilder
    private var nowPlayingHeader: some View {
        if viewModel.isPlayingRecording {
            Text(viewModel.nowPlayingRecordingName ?? "Recording")
                .font(.title2)
                .lineLimit(1)
        } else if let status = viewModel.nowPlaying {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(status.stationName)
                    .font(.title2)
                    .lineLimit(1)
                if let frequency = status.formattedFrequency {
                    Text(frequency)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            Text("Not playing")
                .foregroundStyle(.secondary)
        }
    }

    /// The Status tab's own content — just the extra status line now that
    /// name/frequency/recording-name live in `nowPlayingHeader` above,
    /// visible regardless of which tab is selected.
    @ViewBuilder
    private var statusDetailContent: some View {
        if viewModel.isPlayingRecording {
            Text("Playing recording")
                .foregroundStyle(.secondary)
        } else if let status = viewModel.nowPlaying {
            Text(status.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Live speech-to-text, polled from `/captions.json` — see
/// `CaptionsStatus`'s doc comment. Mirrors `captions.html`: finalized
/// segments as a scrolling transcript, the current in-progress hypothesis
/// (if any) below it in a dimmer, italic style.
private struct CaptionsSubview: View {
    var viewModel: AntennaHeadViewModel

    var body: some View {
        Group {
            if viewModel.captions?.enabled != true {
                ContentUnavailableView("Captions Off", systemImage: "captions.bubble",
                                       description: Text("Turn on speech-to-text in AntennaHead under Configuration › Speech-to-Text, then start a station."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            let finals = viewModel.captions?.final ?? []
                            if finals.isEmpty && (viewModel.captions?.live ?? "").isEmpty {
                                Text("Waiting for speech…")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(Array(finals.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .id(index)
                            }
                            if let live = viewModel.captions?.live, !live.isEmpty {
                                Text(live)
                                    .foregroundStyle(.secondary)
                                    .italic()
                                    .id("live")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: viewModel.captions?.seq) {
                        proxy.scrollTo("live", anchor: .bottom)
                    }
                }
            }
        }
        // Fills whatever vertical space NowPlayingDetail's now-compact
        // controlBar leaves free, rather than the old fixed minHeight —
        // this is the whole point of the row-consolidation above: more
        // room for the transcript itself.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Reading captions involves no remote presses — exactly the kind of
        // idle tvOS otherwise (reasonably) reads as "nobody's watching" and
        // starts the screensaver over. Scoped to just this view's lifetime
        // (not the whole app) via onAppear/onDisappear, which fire reliably
        // here since NowPlayingDetail's tab switch actually removes this
        // view from the hierarchy rather than just hiding it.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

/// Live spatial-audio position (`PCMDistanceGain`/`PCMBinauralPanner`'s
/// azimuth, elevation, and distance) — a third Now Playing tab alongside
/// Status and Captions, same reasoning as Captions' own doc comment: this
/// only means anything while something's playing.
///
/// Plain +/- buttons, not a slider or a stepper: SwiftUI's `Slider` *and*
/// `Stepper` are both unavailable on tvOS entirely (confirmed by the
/// compiler, not assumed — both were tried first and both failed to build)
/// — a focus-navigable button pair is the actual available primitive here,
/// the same one every other action in this file already uses.
///
/// Local `@State`, seeded once from the server's current values via `.task`
/// rather than kept in sync afterward — the same design AntennaHead's own
/// web-UI sliders and its (unreachable) SwiftUI SpatialPositionView both
/// settled on: a control a background poll could silently reset mid-adjust
/// is worse than one that's simply optimistic about its own state. Each
/// press sends its own request immediately — a discrete tap isn't a
/// continuous gesture to batch, unlike a slider drag.
private struct SpatialPositionSubview: View {
    var viewModel: AntennaHeadViewModel
    @State private var azimuth: Double = 0
    @State private var elevation: Double = 0
    @State private var distance: Double = 1.0
    @State private var loaded = false

    var body: some View {
        Group {
            if !loaded {
                ProgressView()
            } else if viewModel.spatialAudio?.enabled != true {
                ContentUnavailableView("Spatial Audio Off", systemImage: "hifispeaker.and.homepod",
                                       description: Text("Turn on spatial audio in AntennaHead under Configuration \u{203A} Spatial Audio, then start a station."))
            } else {
                VStack(alignment: .leading, spacing: 32) {
                    positionRow("Azimuth", value: $azimuth, range: -180...180, step: 5, format: "%.0f\u{00B0}") {
                        Task { await viewModel.setSpatialAudio(azimuth: azimuth) }
                    }
                    positionRow("Elevation", value: $elevation, range: -90...90, step: 5, format: "%.0f\u{00B0}") {
                        Task { await viewModel.setSpatialAudio(elevation: elevation) }
                    }
                    positionRow("Distance", value: $distance, range: 0.1...4, step: 0.1, format: "%.2f") {
                        Task { await viewModel.setSpatialAudio(distance: distance) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await viewModel.refreshSpatialAudio()
            if let status = viewModel.spatialAudio {
                azimuth = status.azimuth
                elevation = status.elevation
                distance = status.distance
            }
            loaded = true
        }
    }

    private func positionRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                             step: Double, format: String, onCommit: @escaping () -> Void) -> some View {
        HStack(spacing: 24) {
            Text("\(label): \(String(format: format, value.wrappedValue))")
                .font(.headline)
                .frame(minWidth: 240, alignment: .leading)
            Button {
                value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
                onCommit()
            } label: {
                Image(systemName: "minus.circle")
            }
            Button {
                value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
                onCommit()
            } label: {
                Image(systemName: "plus.circle")
            }
        }
    }
}

private struct FavoritesDetail: View {
    var viewModel: AntennaHeadViewModel

    var body: some View {
        List(viewModel.favorites) { frequency in
            Button {
                Task { await viewModel.tune(frequency) }
            } label: {
                HStack {
                    Text(frequency.stationName)
                    Spacer()
                    Text(frequency.formattedFrequency)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Favorites")
    }
}

private struct CategoriesDetail: View {
    var viewModel: AntennaHeadViewModel

    var body: some View {
        List(viewModel.categories) { category in
            Button {
                Task { await viewModel.startScan(category) }
            } label: {
                HStack {
                    Text(category.categoryName)
                    Spacer()
                    Text("\(category.frequencyCount)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Categories")
    }
}

/// Core Audio input devices on the Mac (e.g. "Built-in Microphone") — tap to
/// listen. The web UI also lets you type a Sox output filter per listen;
/// left out here in favor of `StartDeviceRequest`'s `"vol 1"` default, since
/// typing Sox filter syntax on a Siri Remote keyboard is a poor fit.
private struct DevicesDetail: View {
    var viewModel: AntennaHeadViewModel

    var body: some View {
        Group {
            if viewModel.devices.isEmpty {
                ContentUnavailableView("No Input Devices", systemImage: "mic.slash",
                                       description: Text("No Core Audio input devices were found on the Mac."))
            } else {
                List(viewModel.devices) { device in
                    Button(device.name) {
                        Task { await viewModel.startDevice(device) }
                    }
                }
            }
        }
        .navigationTitle("Devices")
        .task { await viewModel.loadDevices() }
    }
}

/// Files in AntennaHead's shared Recordings folder — tap to play via the
/// Range-capable download route (real seek support; see
/// `AntennaHeadViewModel.playRecording`'s doc comment).
private struct RecordingsDetail: View {
    var viewModel: AntennaHeadViewModel

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        Group {
            if viewModel.recordings.isEmpty {
                ContentUnavailableView("No Recordings", systemImage: "recordingtape",
                                       description: Text("No recordings were found in AntennaHead's shared Recordings folder."))
            } else {
                List(viewModel.recordings) { recording in
                    Button {
                        viewModel.playRecording(recording)
                    } label: {
                        HStack {
                            Text(recording.fileName)
                            Spacer()
                            Text(Self.dateFormatter.string(from: recording.modifiedAt))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Recordings")
        .task { await viewModel.loadRecordings() }
    }
}

/// ControlBooth remote control — launch it if it isn't running, or pick a
/// pipeline to listen to if it is.
private struct ControlBoothDetail: View {
    var viewModel: AntennaHeadViewModel

    var body: some View {
        Group {
            if let status = viewModel.controlBoothStatus {
                if !status.isRunning {
                    VStack(spacing: 16) {
                        Text("ControlBooth isn't running.")
                            .foregroundStyle(.secondary)
                        Button("Launch ControlBooth") {
                            Task { await viewModel.launchControlBooth() }
                        }
                    }
                    .padding(60)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if status.pipelineNames.isEmpty {
                    ContentUnavailableView("No Pipelines", systemImage: "slider.horizontal.3",
                                           description: Text("No pipelines are configured in ControlBooth."))
                } else {
                    List(status.pipelineNames, id: \.self) { name in
                        Button(name) {
                            Task { await viewModel.startControlBoothPipeline(named: name) }
                        }
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("ControlBooth")
        .toolbar {
            Button("Refresh") {
                Task { await viewModel.loadControlBoothStatus() }
            }
        }
        .task { await viewModel.loadControlBoothStatus() }
    }
}

#Preview {
    ContentView()
}
