import AntennaHeadAPI
import SwiftUI

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
/// AirPlay, Settings, Info) — Tuner (manual frequency entry) and Settings
/// are form-heavy admin surfaces that fit a keyboard/mouse better than a
/// Siri Remote, and are left for a later pass rather than forced in here.
private enum SidebarSection: String, CaseIterable, Identifiable {
    case nowPlaying = "Now Playing"
    case favorites = "Favorites"
    case categories = "Categories"
    case devices = "Devices"
    case recordings = "Recordings"
    case controlBooth = "ControlBooth"
    case airPlay = "AirPlay"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .nowPlaying: "waveform"
        case .favorites: "star.fill"
        case .categories: "square.stack.3d.up.fill"
        case .devices: "mic.fill"
        case .recordings: "recordingtape"
        case .controlBooth: "slider.horizontal.3"
        case .airPlay: "airplayaudio"
        }
    }
}

/// Master-detail layout: `NavigationSplitView` gives the sidebar list on the
/// left and a large detail area on the right for free, including Siri Remote
/// focus navigation between the two columns.
private struct MainScreen: View {
    var viewModel: AntennaHeadViewModel
    @State private var selection: SidebarSection? = .nowPlaying

    var body: some View {
        NavigationSplitView {
            // A plain `List(data, selection:)` binding doesn't reliably commit
            // selection from a Siri Remote press on tvOS when the rows are
            // just `Label`s — that selection-commit mechanism is more an
            // iPadOS/macOS pattern. Setting `selection` directly from a
            // `Button` action matches how every other list in this app
            // already works (Favorites/Categories/Devices/Recordings all set
            // state from a Button, never from a List selection binding).
            List(SidebarSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    Label(section.rawValue, systemImage: section.systemImage)
                }
            }
            .navigationTitle("AntennaHead")
            .toolbar {
                Button("Disconnect") {
                    viewModel.disconnect()
                }
            }
        } detail: {
            switch selection ?? .nowPlaying {
            case .nowPlaying: NowPlayingDetail(viewModel: viewModel)
            case .favorites: FavoritesDetail(viewModel: viewModel)
            case .categories: CategoriesDetail(viewModel: viewModel)
            case .devices: DevicesDetail(viewModel: viewModel)
            case .recordings: RecordingsDetail(viewModel: viewModel)
            case .controlBooth: ControlBoothDetail(viewModel: viewModel)
            case .airPlay: AirPlayDetail(viewModel: viewModel)
            }
        }
    }
}

/// Now-playing status (live stream or a recording, see
/// `AntennaHeadViewModel.isPlayingRecording`) + Stop. Owns the periodic
/// now-playing poll — matches the web UI's own refresh cadence; a real push
/// channel (SSE/WebSocket) is the flagged follow-up once there's more than
/// one client depending on this.
private struct NowPlayingDetail: View {
    var viewModel: AntennaHeadViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let message = viewModel.errorMessage {
                Text(message)
                    .foregroundStyle(.red)
            }

            if viewModel.isPlayingRecording {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.nowPlayingRecordingName ?? "Recording")
                        .font(.title)
                    Text("Playing recording")
                        .foregroundStyle(.secondary)
                }
            } else if let status = viewModel.nowPlaying {
                VStack(alignment: .leading, spacing: 8) {
                    Text(status.stationName)
                        .font(.title)
                    if let frequency = status.formattedFrequency {
                        Text(frequency)
                            .foregroundStyle(.secondary)
                    }
                    Text(status.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Not playing")
                    .foregroundStyle(.secondary)
            }

            Button("Stop") {
                Task { await viewModel.stop() }
            }
            .disabled(!viewModel.isPlayingRecording && viewModel.nowPlaying?.taskMode == .stopped)
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

/// AirPlay Receiver status. There's deliberately no remote "enable" action
/// here, matching the web page — the capture pipeline is only toggled in
/// AntennaHead's own Configuration tab.
private struct AirPlayDetail: View {
    var viewModel: AntennaHeadViewModel

    var body: some View {
        Group {
            if let status = viewModel.airPlayStatus {
                VStack(alignment: .leading, spacing: 16) {
                    if status.isRunning {
                        Text("AirPlay Receiver is running.")
                        if let lastError = status.lastError {
                            Text(lastError)
                                .foregroundStyle(.red)
                        }
                        HStack(spacing: 16) {
                            Button("Listen") {
                                Task { await viewModel.airPlayListen() }
                            }
                            Button("Stop") {
                                Task { await viewModel.airPlayStop() }
                            }
                        }
                    } else {
                        Text("Enable AirPlay Receiver in AntennaHead's Configuration tab first.")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("AirPlay")
        .task { await viewModel.loadAirPlayStatus() }
    }
}

#Preview {
    ContentView()
}
