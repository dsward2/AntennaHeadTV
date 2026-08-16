import AntennaHeadAPI
import AVFoundation
import Foundation

/// Owns the connection to one AntennaHead Mac, the audio playback, and the
/// state `ContentView` renders. Deliberately thin — this is a scaffold
/// proving the `/api/v1/...` round trip end to end (connect, list
/// categories/favorites, tune, stop), not a full port of the web UI's
/// feature set. See the feasibility study for what's intentionally still
/// missing (scanning UI, AirPlay/ControlBooth source switching, recordings,
/// Bonjour discovery).
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
    private var player: AVPlayer?

    init(host: String) {
        self.host = host
        self.client = AntennaHeadAPIClient(host: host)
    }

    /// Fetches now-playing, favorites, and categories concurrently and flips
    /// `isConnected` only if all three succeed — a client that's connected
    /// but missing part of its data isn't a state this scaffold tries to
    /// render. Starts audio once connected: AntennaHead's live stream is one
    /// continuous HLS mount reflecting whatever's currently tuned on the
    /// Mac, not a per-frequency URL, so there's one player for the whole
    /// session rather than one per tune.
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
            startPlayback()
        } catch {
            isConnected = false
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        stopPlayback()
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
            player?.play() // resume in case a prior Stop paused it
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startScan(_ category: CategorySummary) async {
        do {
            nowPlaying = try await client.startScan(categoryID: category.id)
            player?.play() // resume in case a prior Stop paused it
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stops the tuning pipeline server-side, then pauses local playback too
    /// — LiveAudioServer keeps streaming filler silence after the pipeline
    /// tears down (same reasoning as AntennaHead's own Status tab "Stop
    /// Pipeline" button, `AntennaHead/Views/StatusView.swift`), so without
    /// this the player would keep "playing" silence instead of actually
    /// stopping.
    func stop() async {
        do {
            nowPlaying = try await client.stop()
            player?.pause()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Points a fresh `AVPlayer` at AntennaHead's HLS mount (`/hls/index.m3u8`,
    /// served by AntennaHeadHTTPServer itself, proxied through to
    /// LiveAudioServer — see that server's `WebConfig.hlsMount` doc comment,
    /// which specifically calls out that AirPlay-style receivers fetching the
    /// audio URL directly, e.g. Apple TV, need this rather than the plain
    /// AAC/M4A mount). Same host:port as the JSON API — no separate stream
    /// server/port to configure.
    private func startPlayback() {
        guard let url = URL(string: "http://\(host)/hls/index.m3u8") else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        let newPlayer = AVPlayer(url: url)
        newPlayer.play()
        player = newPlayer
    }

    private func stopPlayback() {
        player?.pause()
        player = nil
    }
}
