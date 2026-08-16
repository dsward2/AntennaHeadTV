import AntennaHeadAPI
import AVFoundation
import Foundation

/// Owns the connection to one AntennaHead Mac, the audio playback, and the
/// state `ContentView` renders.
///
/// Section data (devices, recordings, ControlBooth/AirPlay status) is loaded
/// lazily, one section at a time, rather than all upfront in `connect()` —
/// matches the web UI's own page-by-page loading, and avoids e.g. an
/// AppleEvents round trip to a ControlBooth that isn't even running just to
/// populate a sidebar the user hasn't opened yet.
@MainActor
@Observable
final class AntennaHeadViewModel {
    var host: String
    private(set) var isConnecting = false
    private(set) var isConnected = false
    private(set) var nowPlaying: NowPlayingStatus?
    private(set) var favorites: [FrequencySummary] = []
    private(set) var categories: [CategorySummary] = []
    private(set) var devices: [DeviceSummary] = []
    private(set) var recordings: [RecordingSummary] = []
    private(set) var controlBoothStatus: ControlBoothStatus?
    private(set) var airPlayStatus: AirPlayReceiverStatus?
    /// True while the shared player is pointed at a recording instead of the
    /// live stream — drives the "Now Playing" detail's own status line, since
    /// `nowPlaying` (server-side tuning state) doesn't know about local
    /// recording playback at all.
    private(set) var isPlayingRecording = false
    private(set) var nowPlayingRecordingName: String?
    var errorMessage: String?

    private var client: AntennaHeadAPIClient
    private var player: AVPlayer?
    private var liveURL: URL?

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
        devices = []
        recordings = []
        controlBoothStatus = nil
        airPlayStatus = nil
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
            resumeLivePlayback()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startScan(_ category: CategorySummary) async {
        do {
            nowPlaying = try await client.startScan(categoryID: category.id)
            resumeLivePlayback()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stops the tuning pipeline server-side, then pauses local playback too
    /// — LiveAudioServer keeps streaming filler silence after the pipeline
    /// tears down (same reasoning as AntennaHead's own Status tab "Stop
    /// Pipeline" button, `AntennaHead/Views/StatusView.swift`), so without
    /// this the player would keep "playing" silence instead of actually
    /// stopping. Pauses regardless of whether a recording or the live stream
    /// is currently loaded — Stop always means "go quiet".
    func stop() async {
        do {
            nowPlaying = try await client.stop()
            player?.pause()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Devices

    func loadDevices() async {
        do {
            devices = try await client.devices()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startDevice(_ device: DeviceSummary) async {
        do {
            nowPlaying = try await client.startDevice(name: device.name)
            resumeLivePlayback()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Recordings

    func loadRecordings() async {
        do {
            recordings = try await client.recordings()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Points the shared player at a recording via AntennaHead's Range-
    /// capable `/recordings-download/...` route instead of the live HLS
    /// mount — mirrors the web UI's "Download & Play" (real seek support,
    /// see `RecordingSummary.downloadPath`'s doc comment), not "Listen"
    /// (which would route it through the live pipeline). The live stream
    /// resumes the next time a Tune/Scan/Device/ControlBooth/AirPlay listen
    /// action runs — same as the web UI only restoring its live `<audio>`
    /// src from an explicit "start listening" action, not from mere
    /// navigation between pages.
    func playRecording(_ recording: RecordingSummary) {
        guard let player, let url = URL(string: "http://\(host)\(recording.downloadPath)") else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
        isPlayingRecording = true
        nowPlayingRecordingName = recording.fileName
    }

    // MARK: ControlBooth

    func loadControlBoothStatus() async {
        do {
            controlBoothStatus = try await client.controlBoothStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func launchControlBooth() async {
        do {
            controlBoothStatus = try await client.launchControlBooth()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startControlBoothPipeline(named name: String) async {
        do {
            nowPlaying = try await client.startControlBoothPipeline(named: name)
            resumeLivePlayback()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopControlBooth() async {
        do {
            nowPlaying = try await client.stopControlBooth()
            player?.pause()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: AirPlay

    func loadAirPlayStatus() async {
        do {
            airPlayStatus = try await client.airPlayStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func airPlayListen() async {
        do {
            nowPlaying = try await client.airPlayListen()
            resumeLivePlayback()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func airPlayStop() async {
        do {
            nowPlaying = try await client.airPlayStop()
            player?.pause()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Playback

    /// Points a fresh `AVPlayer` at AntennaHead's HLS mount (`/hls/index.m3u8`,
    /// served by AntennaHeadHTTPServer itself, proxied through to
    /// LiveAudioServer — see that server's `WebConfig.hlsMount` doc comment,
    /// which specifically calls out that AirPlay-style receivers fetching the
    /// audio URL directly, e.g. Apple TV, need this rather than the plain
    /// AAC/M4A mount). Same host:port as the JSON API — no separate stream
    /// server/port to configure.
    private func startPlayback() {
        guard let url = URL(string: "http://\(host)/hls/index.m3u8") else { return }
        liveURL = url
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        let newPlayer = AVPlayer(url: url)
        newPlayer.play()
        player = newPlayer
        isPlayingRecording = false
        nowPlayingRecordingName = nil
    }

    private func stopPlayback() {
        player?.pause()
        player = nil
        liveURL = nil
        isPlayingRecording = false
        nowPlayingRecordingName = nil
    }

    /// Switches the shared player back to the live stream if a recording was
    /// playing, then resumes — called from every "start listening to X"
    /// action (tune, scan, device, ControlBooth, AirPlay), matching the web
    /// UI's `startAudioPlayer()` restoring `liveStreamAudioSrc` after
    /// fast-download playback (see `AntennaHead/Web/index.html`).
    private func resumeLivePlayback() {
        if isPlayingRecording, let liveURL {
            player?.replaceCurrentItem(with: AVPlayerItem(url: liveURL))
            isPlayingRecording = false
            nowPlayingRecordingName = nil
        }
        player?.play()
    }
}
