import AntennaHeadAPI
import Foundation

/// Owns the connection to one AntennaHead Mac and the state `ContentView`
/// renders. Deliberately thin — this is a scaffold proving the
/// `/api/v1/...` round trip end to end (connect, list categories/favorites,
/// tune, stop), not a full port of the web UI's feature set. See the
/// feasibility study for what's intentionally still missing (scanning UI,
/// AirPlay/ControlBooth source switching, recordings, Bonjour discovery).
@MainActor
@Observable
final class AntennaHeadViewModel {
    var host: String
    private(set) var isConnecting = false
    private(set) var isConnected = false
    private(set) var nowPlaying: NowPlayingStatus?
    private(set) var favorites: [FrequencySummary] = []
    private(set) var categories: [CategorySummary] = []
    var errorMessage: String?

    private var client: AntennaHeadAPIClient

    init(host: String) {
        self.host = host
        self.client = AntennaHeadAPIClient(host: host)
    }

    /// Fetches now-playing, favorites, and categories concurrently and flips
    /// `isConnected` only if all three succeed — a client that's connected
    /// but missing part of its data isn't a state this scaffold tries to
    /// render.
    func connect() async {
        errorMessage = nil
        isConnecting = true
        defer { isConnecting = false }
        client = AntennaHeadAPIClient(host: host)
        do {
            async let np = client.nowPlaying()
            async let favs = client.favorites()
            async let cats = client.categories()
            nowPlaying = try await np
            favorites = try await favs
            categories = try await cats
            isConnected = true
        } catch {
            isConnected = false
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        isConnected = false
        nowPlaying = nil
        favorites = []
        categories = []
    }

    func refreshNowPlaying() async {
        do {
            nowPlaying = try await client.nowPlaying()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func tune(_ frequency: FrequencySummary) async {
        do {
            nowPlaying = try await client.tune(frequencyID: frequency.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startScan(_ category: CategorySummary) async {
        do {
            nowPlaying = try await client.startScan(categoryID: category.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() async {
        do {
            nowPlaying = try await client.stop()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
