import AntennaHeadAPI
import SwiftUI

/// Scaffold screen: manual host entry (no Bonjour discovery yet — see the
/// feasibility study's open item on pairing), then now-playing status plus
/// tappable favorites/categories lists proving the `/api/v1/...` round trip
/// end to end. Intentionally not a port of the full web UI — see
/// `AntennaHeadAPI`'s README and the feasibility study for why tvOS scope is
/// meant to start smaller and grow, not begin as a 1:1 copy.
struct ContentView: View {
    @AppStorage("AntennaHeadTV.host") private var host = ""
    @State private var viewModel: AntennaHeadViewModel?

    var body: some View {
        if let viewModel, viewModel.isConnected {
            NowPlayingScreen(viewModel: viewModel)
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

/// Post-connect screen: now-playing status, a Stop button, and two lists
/// (favorites, categories) whose rows tune/scan on select. `List` gets
/// tvOS's focus-engine navigation for free — no extra work needed for Siri
/// Remote support here.
private struct NowPlayingScreen: View {
    var viewModel: AntennaHeadViewModel

    var body: some View {
        NavigationStack {
            List {
                if let message = viewModel.errorMessage {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }

                Section("Now Playing") {
                    NowPlayingRow(status: viewModel.nowPlaying)
                    Button("Stop") {
                        Task { await viewModel.stop() }
                    }
                    .disabled(viewModel.nowPlaying?.taskMode == .stopped)
                }

                Section("Favorites") {
                    ForEach(viewModel.favorites) { frequency in
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
                }

                Section("Categories") {
                    ForEach(viewModel.categories) { category in
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
                }
            }
            .navigationTitle("AntennaHead")
            .toolbar {
                Button("Disconnect") {
                    viewModel.disconnect()
                }
            }
            .task {
                // Lightweight poll, matching the web UI's own now-playing
                // refresh cadence — a real push channel (SSE/WebSocket) is
                // the flagged follow-up once there's more than one client
                // depending on this.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    await viewModel.refreshNowPlaying()
                }
            }
        }
    }
}

private struct NowPlayingRow: View {
    var status: NowPlayingStatus?

    var body: some View {
        if let status {
            VStack(alignment: .leading, spacing: 4) {
                Text(status.stationName)
                    .font(.headline)
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
    }
}

#Preview {
    ContentView()
}
