import AntennaHeadAPI
import SwiftUI
import UIKit

/// Server picker (Bonjour discovery + manual host entry) → `MainScreen`: a
/// Now Playing strip across the top, a sidebar of sections on the left, and
/// the selected section's content filling the rest. See `AntennaHeadAPI`'s README and the feasibility study for
/// what's still deferred (Tuner, Settings, Custom Tasks, HTTPS,
/// push-based status).
struct ContentView: View {
    @AppStorage("AntennaHeadTV.host") private var host = ""
    @AppStorage("AntennaHeadTV.usesHTTPS") private var usesHTTPS = false
    /// Bonjour name of the server last picked from the discovered list, so
    /// the picker can put focus back on it next launch. Cleared by a manual
    /// connect, since the typed address may be a different Mac.
    @AppStorage("AntennaHeadTV.serverName") private var serverName = ""
    /// The web login's username; the password is in the Keychain (`WebLogin`).
    @AppStorage(WebLogin.usernameKey) private var username = ""
    @State private var password = WebLogin.savedPassword()
    @State private var viewModel: AntennaHeadViewModel?

    var body: some View {
        Group {
            if let viewModel, viewModel.isConnected {
                MainScreen(viewModel: viewModel)
            } else {
                ConnectScreen(host: $host, usesHTTPS: $usesHTTPS, username: $username, password: $password,
                              lastServerName: serverName, viewModel: viewModel) { pickedName in
                    serverName = pickedName ?? ""
                    await connect()
                }
            }
        }
        #if DEBUG
        // `-autoConnect YES` launch argument: connect with the saved
        // settings at launch, for testing in the simulator, where the
        // simulator panel can't press the remote's buttons.
        .task {
            if UserDefaults.standard.bool(forKey: "autoConnect"), viewModel == nil, !host.isEmpty {
                await connect()
            }
        }
        #endif
    }

    private func connect() async {
        WebLogin.savePassword(password)
        let login = username.isEmpty || password.isEmpty
            ? nil : WebLogin(username: username, password: password)
        let model = viewModel ?? AntennaHeadViewModel(host: host, usesHTTPS: usesHTTPS, login: login)
        model.host = host
        model.usesHTTPS = usesHTTPS
        model.login = login
        viewModel = model
        await model.connect()
    }
}

/// Discovered AntennaHead Macs (see `ServerBrowser`) as one button each,
/// with the manual host:port field and Connect button below as the fallback
/// for when Bonjour can't see the Mac. tvOS has no combo box; a focusable
/// list over a text field is its native equivalent, and picking a server
/// just fills in `host` and connects through the same path manual entry uses.
private struct ConnectScreen: View {
    @Binding var host: String
    @Binding var usesHTTPS: Bool
    @Binding var username: String
    @Binding var password: String
    var lastServerName: String
    var viewModel: AntennaHeadViewModel?
    /// Connects to `host`. The argument is the picked server's Bonjour name,
    /// or `nil` for a manually entered address.
    var connect: (String?) async -> Void

    @State private var browser = ServerBrowser()
    /// The server currently being resolved to an address, for its spinner.
    @State private var resolving: String?
    @State private var resolveError: String?
    @Namespace private var focusNamespace

    private var isBusy: Bool {
        resolving != nil || viewModel?.isConnecting == true
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
            Text("Connect to AntennaHead")
                .font(.title)

            serverList

            Text("Or enter the Mac's address, e.g. 192.168.1.23:8090 — shown in AntennaHead's own window.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 720)

            TextField("host:port", text: $host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(maxWidth: 480)

            // HTTPS needs a certificate the Apple TV trusts, so the address
            // must then be the certificate's name, e.g. mac.example.com:8094,
            // not an IP address. AntennaHead's self-signed certificate won't do.
            Toggle("Use HTTPS", isOn: $usesHTTPS)
                .frame(maxWidth: 480)
            if usesHTTPS {
                Text("Use the name on the Mac's trusted certificate and its HTTPS port, e.g. mac.example.com:8094.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 720)
            }

            // Only needed when AntennaHead's web login is on (its Security
            // tab). No autocorrect: it turns usernames into words.
            HStack(spacing: 20) {
                TextField("Web login username (optional)", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }
            .frame(maxWidth: 720)

            Button {
                resolveError = nil
                Task { await connect(nil) }
            } label: {
                if viewModel?.isConnecting == true && resolving == nil {
                    ProgressView()
                } else {
                    Text("Connect")
                }
            }
            .disabled(host.isEmpty || isBusy)

            if let message = resolveError ?? viewModel?.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
        }
        .padding(60)
        .focusScope(focusNamespace)
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    @ViewBuilder
    private var serverList: some View {
        VStack(spacing: 12) {
            if browser.servers.isEmpty {
                HStack(spacing: 16) {
                    if browser.browseError == nil {
                        ProgressView()
                    }
                    Text(browser.browseError ?? "Looking for AntennaHead on your network…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 720, minHeight: 80)
            } else {
                ForEach(browser.servers) { server in
                    serverButton(server)
                }
            }
        }
    }

    private func serverButton(_ server: ServerBrowser.Server) -> some View {
        Button {
            Task { await pick(server) }
        } label: {
            HStack(spacing: 20) {
                Image(systemName: "desktopcomputer")
                VStack(alignment: .leading, spacing: 4) {
                    Text(server.name)
                    if let reason = server.unsupportedReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let note = note(for: server) {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if resolving == server.name {
                    ProgressView()
                }
            }
            .frame(maxWidth: 720)
        }
        .disabled(server.unsupportedReason != nil || isBusy)
        .prefersDefaultFocus(server.name == lastServerName, in: focusNamespace)
    }

    /// "Last used" and/or "Web login on", or `nil`.
    private func note(for server: ServerBrowser.Server) -> String? {
        var parts: [String] = []
        if server.name == lastServerName { parts.append("Last used") }
        if server.advertisement.requiresAuth {
            parts.append(password.isEmpty ? "Web login on: enter it below" : "Web login on")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func pick(_ server: ServerBrowser.Server) async {
        resolveError = nil
        resolving = server.name
        defer { resolving = nil }
        do {
            host = try await browser.resolve(server)
            // Discovery yields an IP address and the plain-HTTP port, which
            // a real certificate wouldn't cover; HTTPS needs its name typed in.
            usesHTTPS = false
        } catch {
            resolveError = error.localizedDescription
            return
        }
        await connect(server.name)
    }
}

/// Everything the detail area can show: the sidebar's sections, plus
/// Captions and Spatial Audio, which are opened from the Now Playing strip
/// instead because they only mean anything while something is playing.
///
/// A subset of the web UI's own menus — Tuner (manual frequency entry),
/// Settings, and the editing pages are form-heavy admin surfaces that fit a
/// keyboard/mouse better than a Siri Remote, and are left for a later pass.
enum Section: String, Identifiable {
    case captions = "Captions"
    case spatialAudio = "Spatial Audio"
    case favorites = "Favorites"
    case categories = "Categories"
    case devices = "Devices"
    case gqrx = "Listen to Gqrx"
    case airPlay = "AirPlay Receiver"
    case controlBooth = "ControlBooth"
    case recordings = "Recordings"
    case audioFiles = "Play Audio Files"
    case textToSpeech = "Text to Speech"
    case rssHeadlines = "Speak RSS Headlines"

    var id: String { rawValue }

    /// The sidebar's rows, in groups. Captions and Spatial Audio aren't here
    /// (see above).
    static let sidebarGroups: [(title: String, sections: [Section])] = [
        ("Radio", [.favorites, .categories]),
        ("Live Sources", [.devices, .gqrx, .airPlay, .controlBooth]),
        ("Files & Speech", [.recordings, .audioFiles, .textToSpeech, .rssHeadlines]),
    ]

    var systemImage: String {
        switch self {
        case .captions: "captions.bubble"
        case .spatialAudio: "hifispeaker.and.homepod"
        case .favorites: "star.fill"
        case .categories: "square.stack.3d.up.fill"
        case .devices: "mic.fill"
        case .gqrx: "dial.medium"
        case .airPlay: "airplayaudio"
        case .controlBooth: "slider.horizontal.3"
        case .recordings: "recordingtape"
        case .audioFiles: "music.note.list"
        case .textToSpeech: "text.bubble"
        case .rssHeadlines: "dot.radiowaves.up.forward"
        }
    }
}

/// A persistent Now Playing strip across the top, with a fixed sidebar and a
/// detail area below it.
///
/// The sidebar is a plain fixed-width column, not `NavigationSplitView`: that
/// sidebar resizes and slides as Siri Remote focus moves between columns
/// (standard tvOS behavior), which reads as distracting motion rather than
/// stable chrome. An earlier version used a top `TabView` for the same
/// reason, but it ran out of room once the list of sources grew.
///
/// Selecting a sidebar row takes a click, rather than following focus the
/// way the TV app's sidebar does, so scrolling past ControlBooth doesn't fire
/// an AppleEvents round trip to it just to render a page nobody stopped on.
private struct MainScreen: View {
    var viewModel: AntennaHeadViewModel
    @State private var selection: Section = .favorites
    @Namespace private var focusNamespace

    var body: some View {
        VStack(spacing: 0) {
            NowPlayingStrip(viewModel: viewModel, selection: $selection)
            Divider()
            HStack(spacing: 0) {
                sidebar
                    // Room for the focused row's enlarged highlight, which
                    // would otherwise spill over the divider.
                    .padding(.trailing, 30)
                    .frame(width: 500)
                    .focusSection()
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    if let message = viewModel.errorMessage {
                        Text(message)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 60)
                            .padding(.top, 20)
                    }
                    NavigationStack {
                        detail(for: selection)
                    }
                    // A fresh stack per section, so one section's toolbar
                    // and title never linger into the next.
                    .id(selection)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .focusSection()
            }
            // Down from the strip must always land somewhere. The strip's
            // buttons sit above the detail area only, so on a page with
            // nothing focusable (Captions, Spatial Audio Off) the detail
            // section alone gave the focus engine no target, and focus was
            // stuck in the strip. This outer section lets it fall back to
            // the sidebar.
            .focusSection()
        }
        .focusScope(focusNamespace)
        // Owns the now-playing poll, since the strip is always on screen.
        // Matches the web UI's own refresh cadence; a real push channel
        // (SSE/WebSocket) is the flagged follow-up.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await viewModel.refreshNowPlaying()
            }
        }
    }

    /// `List` rows made of `Button`s, not `List(selection:)`: that selection
    /// binding doesn't reliably fire from a Siri Remote press on tvOS.
    private var sidebar: some View {
        List {
            ForEach(Section.sidebarGroups, id: \.title) { group in
                SwiftUI.Section(group.title) {
                    ForEach(group.sections) { section in
                        sidebarRow(section)
                    }
                }
            }
            SwiftUI.Section {
                Button {
                    viewModel.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            }
        }
    }

    private func sidebarRow(_ section: Section) -> some View {
        let isSelected = section == selection
        return Button {
            selection = section
        } label: {
            HStack {
                Label(section.rawValue, systemImage: section.systemImage)
                    .fontWeight(isSelected ? .semibold : .regular)
                Spacer()
                if isSelected {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .prefersDefaultFocus(isSelected, in: focusNamespace)
    }

    @ViewBuilder
    private func detail(for section: Section) -> some View {
        switch section {
        case .captions: CaptionsDetail(viewModel: viewModel)
        case .spatialAudio: SpatialAudioDetail(viewModel: viewModel)
        case .favorites: FavoritesDetail(viewModel: viewModel)
        case .categories: CategoriesDetail(viewModel: viewModel)
        case .devices: DevicesDetail(viewModel: viewModel)
        case .gqrx: GqrxDetail(viewModel: viewModel)
        case .airPlay: AirPlayDetail(viewModel: viewModel)
        case .controlBooth: ControlBoothDetail(viewModel: viewModel)
        case .recordings: RecordingsDetail(viewModel: viewModel)
        case .audioFiles:
            FolderSourceDetail(title: "Play Audio Files", fileKind: "audio files",
                               listing: viewModel.audioFiles,
                               load: { await viewModel.loadAudioFiles() },
                               start: { names, sequence, repeatForever, playlist in
                                   await viewModel.startAudioFiles(StartAudioFilesRequest(
                                       fileNames: names, sequence: sequence,
                                       repeatForever: repeatForever, playlistName: playlist))
                               })
        case .textToSpeech:
            FolderSourceDetail(title: "Text to Speech", fileKind: ".txt files",
                               listing: viewModel.textToSpeechFiles,
                               load: { await viewModel.loadTextToSpeechFiles() },
                               start: { names, sequence, repeatForever, _ in
                                   await viewModel.startTextToSpeech(StartTextToSpeechRequest(
                                       fileNames: names, sequence: sequence, repeatForever: repeatForever))
                               })
        case .rssHeadlines: RSSHeadlinesDetail(viewModel: viewModel)
        }
    }
}

/// Station (or recording) name, frequency, and status on the left, with
/// Captions, Spatial Audio, and Stop on the right. The buttons keep their
/// full size and the text truncates instead: when a long station name used
/// to squeeze buttons like these, the focus engine skipped them entirely.
private struct NowPlayingStrip: View {
    var viewModel: AntennaHeadViewModel
    @Binding var selection: Section

    var body: some View {
        HStack(spacing: 32) {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 6) {
                header
                if let detail = statusLine {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 16) {
                ForEach([Section.captions, .spatialAudio]) { section in
                    Button {
                        selection = section
                    } label: {
                        Label(section.rawValue, systemImage: section.systemImage)
                    }
                    .buttonStyle(.bordered)
                    .tint(section == selection ? .accentColor : nil)
                }

                Button {
                    Task { await viewModel.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!viewModel.isPlayingRecording && viewModel.nowPlaying?.taskMode == .stopped)
            }
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 24)
        .focusSection()
    }

    @ViewBuilder
    private var header: some View {
        if viewModel.isPlayingRecording {
            Text(viewModel.nowPlayingRecordingName ?? "Recording")
                .font(.title3)
        } else if let status = viewModel.nowPlaying {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(status.stationName)
                    .font(.title3)
                if let frequency = status.formattedFrequency {
                    Text(frequency)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("Not playing")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    /// `nil` when it would only repeat the header, e.g. "Filler" under "Filler".
    private var statusLine: String? {
        if viewModel.isPlayingRecording { return "Playing recording" }
        guard let status = viewModel.nowPlaying, status.statusText != status.stationName else { return nil }
        return status.statusText
    }
}

/// Wraps `CaptionsSubview` as a detail page, and polls captions only while
/// it's showing — the poll ends when the user picks another section.
private struct CaptionsDetail: View {
    var viewModel: AntennaHeadViewModel

    var body: some View {
        CaptionsSubview(viewModel: viewModel)
            .padding(60)
            .navigationTitle("Captions")
            .task {
                while !Task.isCancelled {
                    await viewModel.refreshCaptions()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }
}

private struct SpatialAudioDetail: View {
    var viewModel: AntennaHeadViewModel

    var body: some View {
        SpatialPositionSubview(viewModel: viewModel)
            .padding(60)
            .navigationTitle("Spatial Audio")
    }
}

/// Live speech-to-text, polled from `/captions.json` — see
/// `CaptionsStatus`'s doc comment. Mirrors `captions.html`: finalized
/// segments as a scrolling transcript (with each retune's "Now playing …"
/// announcement line set off as a divider), the current in-progress
/// hypothesis (if any) below it in a dimmer, italic style.
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
                                if line.isAnnouncement {
                                    // The "Now playing …" marker AntennaHead inserts
                                    // on each retune — styled as a divider between
                                    // sources, like captions.html's
                                    // `.caption-announcement`.
                                    VStack(alignment: .leading, spacing: 12) {
                                        if index > 0 { Divider() }
                                        Text(line.text)
                                            .italic()
                                            .foregroundStyle(.secondary)
                                    }
                                    .id(index)
                                } else {
                                    Text(line.text)
                                        .id(index)
                                }
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
        // Fills the whole detail area — as much room as possible for the
        // transcript itself.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Reading captions involves no remote presses — exactly the kind of
        // idle tvOS otherwise (reasonably) reads as "nobody's watching" and
        // starts the screensaver over. Scoped to just this view's lifetime
        // (not the whole app) via onAppear/onDisappear, which fire reliably
        // here since picking another section removes this view from the
        // hierarchy rather than just hiding it.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

/// Live spatial-audio position (`PCMDistanceGain`/`PCMBinauralPanner`'s
/// azimuth, elevation, and distance) — opened from the Now Playing strip
/// alongside Captions, since this only means anything while something's
/// playing.
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

/// Listen to Gqrx: launch Gqrx on the Mac if it isn't running, listen to its
/// UDP audio, or pick one of Gqrx's own bookmarks to tune to and play. The
/// rest of Gqrx's remote control (frequency, mode, gains, squelch) stays on
/// the Mac or AntennaHead's web page.
private struct GqrxDetail: View {
    var viewModel: AntennaHeadViewModel

    var body: some View {
        Group {
            if let status = viewModel.gqrxStatus {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 24) {
                        if status.isRunning {
                            Button {
                                Task { await viewModel.startGqrx(channels: 2) }
                            } label: {
                                Label("Listen in Stereo", systemImage: "headphones")
                            }
                            Button {
                                Task { await viewModel.startGqrx(channels: 1) }
                            } label: {
                                Label("Listen in Mono", systemImage: "speaker.wave.1")
                            }
                        } else {
                            Button {
                                Task {
                                    await viewModel.launchGqrx()
                                    // Launching doesn't wait for Gqrx to finish
                                    // starting, so check again shortly.
                                    try? await Task.sleep(for: .seconds(3))
                                    await reload()
                                }
                            } label: {
                                Label("Launch Gqrx and Listen", systemImage: "play.fill")
                            }
                            Text("Gqrx isn't running.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)

                    Text("Set Gqrx's Audio \u{25B8} UDP output to port \(String(status.receivePort)). Pick Mono if Gqrx's Audio \u{25B8} Stereo box is unchecked.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 1000, alignment: .leading)

                    if status.isRunning {
                        bookmarks
                    }
                }
                .padding(.horizontal, 60)
                .padding(.top, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Listen to Gqrx")
        .toolbar {
            Button("Refresh") {
                Task { await reload() }
            }
        }
        .task { await reload() }
    }

    /// Gqrx's bookmarks, each a button that tunes to it and plays. Bookmarks
    /// can only be read from a running Gqrx, so this is hidden otherwise.
    @ViewBuilder
    private var bookmarks: some View {
        Text("Bookmarks")
            .font(.headline)
        if let bookmarks = viewModel.gqrxBookmarks {
            if bookmarks.isEmpty {
                Text("Gqrx has no bookmarks.")
                    .foregroundStyle(.secondary)
            } else {
                List(bookmarks) { bookmark in
                    Button {
                        Task { await viewModel.playGqrxBookmark(bookmark) }
                    } label: {
                        HStack(spacing: 24) {
                            Text(bookmark.name.isEmpty ? "Untitled" : bookmark.name)
                                .lineLimit(1)
                            Spacer()
                            Text(bookmark.modulation)
                                .foregroundStyle(.secondary)
                            Text(Self.megahertz(bookmark.frequencyHz))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 220, alignment: .trailing)
                        }
                    }
                }
            }
        } else if let message = viewModel.gqrxBookmarksMessage {
            Text(message)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 1000, alignment: .leading)
        } else {
            ProgressView()
        }
    }

    private func reload() async {
        await viewModel.loadGqrxStatus()
        if viewModel.gqrxStatus?.isRunning == true {
            await viewModel.loadGqrxBookmarks()
        }
    }

    /// Same format as the web page's bookmark list, e.g. "162.5500 MHz".
    private static func megahertz(_ hz: Int64) -> String {
        String(format: "%.4f MHz", Double(hz) / 1_000_000)
    }
}

/// ControlBooth's AirPlay Receiver: start or stop relaying its audio to
/// AntennaHead. Mirrors the AirPlay section of the web UI's ControlBooth page.
private struct AirPlayDetail: View {
    var viewModel: AntennaHeadViewModel

    var body: some View {
        Group {
            if let status = viewModel.controlBoothStatus {
                VStack(alignment: .leading, spacing: 32) {
                    if !status.isRunning {
                        Text("The AirPlay Receiver is part of ControlBooth, which isn't running.")
                            .foregroundStyle(.secondary)
                        Button("Launch ControlBooth") {
                            Task {
                                await viewModel.launchControlBooth()
                                try? await Task.sleep(for: .seconds(3))
                                await viewModel.loadControlBoothStatus()
                            }
                        }
                    } else {
                        Text("AirPlay: \(Self.statusText(status))")
                            .font(.headline)
                        if status.isListeningToAirPlay {
                            Button {
                                Task { await viewModel.stopAirPlay() }
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                        } else {
                            Button {
                                Task { await viewModel.startAirPlay() }
                            } label: {
                                Label("Listen", systemImage: "airplayaudio")
                            }
                        }
                        Text("Play to ControlBooth's AirPlay receiver from an iPhone, iPad, or Mac, and the audio comes through AntennaHead's live stream.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 1000, alignment: .leading)
                    }
                }
                .padding(60)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("AirPlay Receiver")
        .toolbar {
            Button("Refresh") {
                Task { await viewModel.loadControlBoothStatus() }
            }
        }
        .task { await viewModel.loadControlBoothStatus() }
    }

    /// Same wording as the web page's `controlBoothAirPlaySectionHTML()`.
    private static func statusText(_ status: ControlBoothStatus) -> String {
        guard let enabled = status.airPlayEnabled else { return "Unknown" }
        if !enabled { return "Not in use" }
        if status.airPlayReceivingAudio == true { return "Receiving AirPlay audio" }
        return "Idle \u{2014} advertising, no AirPlay client connected"
    }
}

private extension FileSequence {
    var label: String {
        switch self {
        case .chronological: "Oldest First"
        case .alphabetical: "Alphabetical"
        case .random: "Random"
        }
    }
}

/// Play Audio Files and Text to Speech — the same page shape as their web
/// forms: the files in the folder chosen in AntennaHead's Configuration tab,
/// each checked by default, plus play order, Repeat, and (Play Audio Files
/// only) a playlist, then Listen.
private struct FolderSourceDetail: View {
    let title: String
    /// For the empty-folder message, e.g. "audio files".
    let fileKind: String
    let listing: FolderListing?
    let load: () async -> Void
    /// `(fileNames, sequence, repeatForever, playlistName)`. `fileNames` is
    /// `nil` when every file is checked.
    let start: ([String]?, FileSequence, Bool, String?) async -> Void

    /// Tracks the *unchecked* files, so everything is checked by default and
    /// files that appear after a Refresh start out checked too.
    @State private var unchecked: Set<String> = []
    @State private var sequence: FileSequence = .chronological
    @State private var repeatForever = false
    @State private var playlist: String?
    @State private var isStarting = false

    var body: some View {
        Group {
            if let listing {
                if !listing.folderConfigured {
                    ContentUnavailableView("No Folder Selected", systemImage: "folder.badge.questionmark",
                                           description: Text("Choose a \(title) folder in AntennaHead's Configuration tab on the Mac."))
                } else if listing.files.isEmpty && listing.playlists.isEmpty {
                    ContentUnavailableView("No Files", systemImage: "folder",
                                           description: Text("There are no \(fileKind) in \(listing.folderPath ?? "the folder")."))
                } else {
                    content(listing)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .toolbar {
            Button("Refresh") {
                Task { await load() }
            }
        }
        .task { await load() }
    }

    private func content(_ listing: FolderListing) -> some View {
        let checkedNames = listing.files.map(\.name).filter { !unchecked.contains($0) }
        let usesPlaylist = playlist != nil
        return VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 20) {
                Button {
                    Task {
                        isStarting = true
                        defer { isStarting = false }
                        let names = unchecked.isEmpty ? nil : checkedNames
                        await start(names, sequence, repeatForever, playlist)
                    }
                } label: {
                    if isStarting {
                        ProgressView()
                    } else {
                        Label("Listen", systemImage: "play.fill")
                    }
                }
                .disabled(isStarting || (!usesPlaylist && checkedNames.isEmpty))

                Menu {
                    ForEach(FileSequence.allCases, id: \.self) { candidate in
                        Button(candidate.label) { sequence = candidate }
                    }
                } label: {
                    Label("Order: \(sequence.label)", systemImage: "arrow.up.arrow.down")
                }
                .disabled(usesPlaylist)

                Button {
                    repeatForever.toggle()
                } label: {
                    Label(repeatForever ? "Repeat: On" : "Repeat: Off", systemImage: "repeat")
                }
                .tint(repeatForever ? .accentColor : nil)

                if !listing.playlists.isEmpty {
                    Menu {
                        Button("None") { playlist = nil }
                        ForEach(listing.playlists, id: \.self) { name in
                            Button(name) { playlist = name }
                        }
                    } label: {
                        Label("Playlist: \(playlist ?? "None")", systemImage: "list.bullet")
                    }
                }
            }
            .lineLimit(1)

            if usesPlaylist {
                Text("Playing the playlist's own files in its own order.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // Not in the List's section header: tvOS doesn't focus
                // buttons there.
                SelectionBar(selectedCount: checkedNames.count, totalCount: listing.files.count,
                             selectAll: { unchecked = [] },
                             selectNone: { unchecked = Set(listing.files.map(\.name)) })
            }

            List(listing.files) { file in
                CheckRow(title: file.name,
                         detail: Self.dateFormatter.string(from: file.modifiedAt),
                         isChecked: !unchecked.contains(file.name)) {
                    if unchecked.contains(file.name) {
                        unchecked.remove(file.name)
                    } else {
                        unchecked.insert(file.name)
                    }
                }
            }
            .disabled(usesPlaylist)
        }
        .padding(.horizontal, 60)
        .padding(.top, 20)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// Speak RSS Headlines: pick feeds and how many headlines each, then Listen.
/// Always uses each feed's own voice; adding and editing feeds, and the
/// alternating co-anchor voices, stay on the web page.
private struct RSSHeadlinesDetail: View {
    var viewModel: AntennaHeadViewModel

    @State private var uncheckedIDs: Set<Int64> = []
    @State private var itemsPerFeed = 5
    @State private var repeatForever = false
    @State private var isStarting = false

    var body: some View {
        Group {
            if let feeds = viewModel.rssFeeds {
                if feeds.isEmpty {
                    ContentUnavailableView("No Feeds", systemImage: "dot.radiowaves.up.forward",
                                           description: Text("Add feeds on AntennaHead's Speak RSS Headlines web page."))
                } else {
                    content(feeds)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Speak RSS Headlines")
        .toolbar {
            Button("Refresh") {
                Task { await viewModel.loadRSSFeeds() }
            }
        }
        .task { await viewModel.loadRSSFeeds() }
    }

    private func content(_ feeds: [RSSFeedSummary]) -> some View {
        let checkedIDs = feeds.map(\.id).filter { !uncheckedIDs.contains($0) }
        return VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 20) {
                Button {
                    Task {
                        isStarting = true
                        defer { isStarting = false }
                        await viewModel.startRSSHeadlines(StartRSSHeadlinesRequest(
                            feedIDs: checkedIDs, itemsPerFeed: itemsPerFeed, repeatForever: repeatForever))
                    }
                } label: {
                    if isStarting {
                        ProgressView()
                    } else {
                        Label("Listen", systemImage: "play.fill")
                    }
                }
                .disabled(isStarting || checkedIDs.isEmpty)

                // `Stepper` isn't available on tvOS; a -/+ pair is.
                Text("\(itemsPerFeed) per feed")
                    .monospacedDigit()
                Button {
                    itemsPerFeed = max(1, itemsPerFeed - 1)
                } label: {
                    Image(systemName: "minus")
                }
                Button {
                    itemsPerFeed = min(20, itemsPerFeed + 1)
                } label: {
                    Image(systemName: "plus")
                }

                Button {
                    repeatForever.toggle()
                } label: {
                    Label(repeatForever ? "Repeat: On" : "Repeat: Off", systemImage: "repeat")
                }
                .tint(repeatForever ? .accentColor : nil)
            }
            .lineLimit(1)

            if isStarting {
                Text("Fetching the headlines and rendering speech\u{2026}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SelectionBar(selectedCount: checkedIDs.count, totalCount: feeds.count,
                         selectAll: { uncheckedIDs = [] },
                         selectNone: { uncheckedIDs = Set(feeds.map(\.id)) })

            List(feeds) { feed in
                CheckRow(title: feed.name, detail: nil, isChecked: !uncheckedIDs.contains(feed.id)) {
                    if uncheckedIDs.contains(feed.id) {
                        uncheckedIDs.remove(feed.id)
                    } else {
                        uncheckedIDs.insert(feed.id)
                    }
                }
            }
        }
        .padding(.horizontal, 60)
        .padding(.top, 20)
    }
}

/// "2 of 5 selected" with Select All / Select None, above a `CheckRow` list.
private struct SelectionBar: View {
    let selectedCount: Int
    let totalCount: Int
    let selectAll: () -> Void
    let selectNone: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            Text("\(selectedCount) of \(totalCount) selected")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Select All", action: selectAll)
            Button("Select None", action: selectNone)
        }
        .lineLimit(1)
    }
}

/// A list row that toggles a checkmark — tvOS's stand-in for the web forms'
/// checkboxes.
private struct CheckRow: View {
    let title: String
    let detail: String?
    let isChecked: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 20) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isChecked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(title)
                    .lineLimit(1)
                Spacer()
                if let detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
