import AntennaHeadAPI
import Foundation
import Security

/// AntennaHead's web login (HTTP Basic Auth), when it's turned on in
/// AntennaHead's Security tab. It covers every path: the JSON API, the HLS
/// stream, and recording downloads.
nonisolated struct WebLogin: Equatable, Sendable {
    var username: String
    var password: String

    /// The `Authorization` header value.
    var authorization: String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    /// Where `ContentView` keeps the username; the password is in the Keychain.
    static let usernameKey = "AntennaHeadTV.username"
    private static let keychainAccount = "weblogin"

    /// The saved login, or `nil` if there's no username or password.
    static func load() -> WebLogin? {
        let username = UserDefaults.standard.string(forKey: usernameKey) ?? ""
        guard !username.isEmpty, let password = Keychain.read(account: keychainAccount), !password.isEmpty else {
            return nil
        }
        return WebLogin(username: username, password: password)
    }

    static func savePassword(_ password: String) {
        if password.isEmpty {
            Keychain.delete(account: keychainAccount)
        } else {
            Keychain.write(password, account: keychainAccount)
        }
    }

    static func savedPassword() -> String {
        Keychain.read(account: keychainAccount) ?? ""
    }
}

/// Minimal generic-password Keychain wrapper for the web-login password.
nonisolated enum Keychain {
    private static let service = "com.dsward.AntennaHeadTV.weblogin"

    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String) -> String? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let data = Data(value.utf8)
        let base = query(account: account)
        let update = [kSecValueData as String: data]
        if SecItemUpdate(base as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}

/// Talks to one AntennaHead Mac's JSON API (`/api/v1/...`, see
/// `AntennaHeadAPI`'s README) over plain HTTP on the LAN.
///
/// `host` is a plain "host:port", either typed in or resolved from a Bonjour
/// result by `ServerBrowser`. Sends the web login (`WebLogin`) with every
/// request when one is given. No HTTPS support yet: this client uses
/// AntennaHead's plain HTTP listener.
actor AntennaHeadAPIClient {
    enum ClientError: Error, LocalizedError {
        case invalidHost
        /// A 401 with no login given.
        case loginNeeded
        /// A 401 with a login given: it's wrong.
        case loginRejected
        case badResponse(Int)
        /// The server's own `{"error": ...}` message (`APIError`).
        case server(String)
        case decoding(Error)

        var errorDescription: String? {
            switch self {
            case .invalidHost:
                return "Enter a valid host, e.g. 192.168.1.23:8090."
            case .loginNeeded:
                return "This server's web login is on. Enter its username and password below."
            case .loginRejected:
                return "The server rejected the web login. Check the username and password below."
            case .badResponse(let code):
                return "The server returned HTTP \(code)."
            case .server(let message):
                return message
            case .decoding(let error):
                return "Couldn't understand the server's response: \(error.localizedDescription)"
            }
        }
    }

    private let session: URLSession
    let host: String
    private let login: WebLogin?

    init(host: String, login: WebLogin?, session: URLSession = .shared) {
        self.host = host
        self.login = login
        self.session = session
    }

    private func url(for path: String) throws -> URL {
        guard !host.isEmpty, let url = URL(string: "http://\(host)\(path)") else {
            throw ClientError.invalidHost
        }
        return url
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        var request = request
        if let login {
            request.setValue(login.authorization, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            throw login == nil ? ClientError.loginNeeded : ClientError.loginRejected
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let apiError = try? JSONDecoder().decode(APIError.self, from: data) {
                throw ClientError.server(apiError.error)
            }
            throw ClientError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ClientError.decoding(error)
        }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await perform(URLRequest(url: try url(for: path)))
    }

    private func post<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = "POST"
        return try await perform(request)
    }

    private func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    func categories() async throws -> [CategorySummary] {
        try await get(APIEndpoint.categories)
    }

    func favorites() async throws -> [FrequencySummary] {
        try await get(APIEndpoint.favorites)
    }

    func nowPlaying() async throws -> NowPlayingStatus {
        try await get(APIEndpoint.nowPlaying)
    }

    @discardableResult
    func tune(frequencyID: Int64) async throws -> NowPlayingStatus {
        try await post(APIEndpoint.tune, body: TuneFrequencyRequest(frequencyID: frequencyID))
    }

    @discardableResult
    func startScan(categoryID: Int64) async throws -> NowPlayingStatus {
        try await post(APIEndpoint.startScan, body: StartCategoryScanRequest(categoryID: categoryID))
    }

    @discardableResult
    func stop() async throws -> NowPlayingStatus {
        try await post(APIEndpoint.stop)
    }

    func devices() async throws -> [DeviceSummary] {
        try await get(APIEndpoint.devices)
    }

    @discardableResult
    func startDevice(name: String) async throws -> NowPlayingStatus {
        try await post(APIEndpoint.startDevice, body: StartDeviceRequest(deviceName: name))
    }

    func recordings() async throws -> [RecordingSummary] {
        try await get(APIEndpoint.recordings)
    }

    func controlBoothStatus() async throws -> ControlBoothStatus {
        try await get(APIEndpoint.controlBoothStatus)
    }

    @discardableResult
    func launchControlBooth() async throws -> ControlBoothStatus {
        try await post(APIEndpoint.controlBoothLaunch)
    }

    @discardableResult
    func startControlBoothPipeline(named name: String) async throws -> NowPlayingStatus {
        try await post(APIEndpoint.controlBoothStart, body: StartControlBoothPipelineRequest(pipelineName: name))
    }

    @discardableResult
    func stopControlBooth() async throws -> NowPlayingStatus {
        try await post(APIEndpoint.controlBoothStop)
    }

    func captions() async throws -> CaptionsStatus {
        try await get(APIEndpoint.captions)
    }

    func spatialAudio() async throws -> SpatialAudioStatus {
        try await get(APIEndpoint.spatialAudio)
    }

    /// Any subset of the three may be provided — see `SetSpatialAudioRequest`'s
    /// doc comment on why `nil` means "leave this alone", not "set to zero".
    @discardableResult
    func setSpatialAudio(azimuth: Double? = nil, elevation: Double? = nil, distance: Double? = nil) async throws -> SpatialAudioStatus {
        try await post(APIEndpoint.setSpatialAudio,
                       body: SetSpatialAudioRequest(azimuth: azimuth, elevation: elevation, distance: distance))
    }

    // MARK: Gqrx, Play Audio Files, Text to Speech, Speak RSS Headlines

    func gqrxStatus() async throws -> GqrxStatus {
        try await get(APIEndpoint.gqrxStatus)
    }

    @discardableResult
    func launchGqrx() async throws -> GqrxStatus {
        try await post(APIEndpoint.gqrxLaunch)
    }

    @discardableResult
    func startGqrx(channels: Int) async throws -> NowPlayingStatus {
        try await post(APIEndpoint.gqrxStart, body: StartGqrxRequest(channels: channels))
    }

    func gqrxBookmarks() async throws -> [GqrxBookmarkSummary] {
        try await get(APIEndpoint.gqrxBookmarks)
    }

    @discardableResult
    func playGqrxBookmark(frequencyHz: Int64, channels: Int) async throws -> NowPlayingStatus {
        try await post(APIEndpoint.gqrxBookmarkPlay,
                       body: PlayGqrxBookmarkRequest(frequencyHz: frequencyHz, channels: channels))
    }

    func audioFiles() async throws -> FolderListing {
        try await get(APIEndpoint.audioFiles)
    }

    @discardableResult
    func startAudioFiles(_ request: StartAudioFilesRequest) async throws -> NowPlayingStatus {
        try await post(APIEndpoint.audioFilesStart, body: request)
    }

    func textToSpeechFiles() async throws -> FolderListing {
        try await get(APIEndpoint.textToSpeech)
    }

    @discardableResult
    func startTextToSpeech(_ request: StartTextToSpeechRequest) async throws -> NowPlayingStatus {
        try await post(APIEndpoint.textToSpeechStart, body: request)
    }

    func rssFeeds() async throws -> [RSSFeedSummary] {
        try await get(APIEndpoint.rssFeeds)
    }

    @discardableResult
    func startRSSHeadlines(_ request: StartRSSHeadlinesRequest) async throws -> NowPlayingStatus {
        try await post(APIEndpoint.rssHeadlinesStart, body: request)
    }

    // MARK: AirPlay Receiver (via ControlBooth)

    @discardableResult
    func startAirPlay() async throws -> NowPlayingStatus {
        try await post(APIEndpoint.controlBoothAirPlayStart)
    }

    @discardableResult
    func stopAirPlay() async throws -> NowPlayingStatus {
        try await post(APIEndpoint.controlBoothAirPlayStop)
    }
}
