import AntennaHeadAPI
import Foundation

/// Talks to one AntennaHead Mac's JSON API (`/api/v1/...`, see
/// `AntennaHeadAPI`'s README) over plain HTTP on the LAN.
///
/// No discovery yet — `host` is entered manually (see `ConnectScreen`) until
/// Bonjour-based pairing (flagged as a follow-up in the feasibility study) is
/// built. That also means no HTTPS/Basic-Auth support yet either, unlike the
/// web UI — this client assumes AntennaHead's plain HTTP listener with no
/// auth configured, since that's the simplest thing that lets the rest of
/// the app get built and tested first.
actor AntennaHeadAPIClient {
    enum ClientError: Error, LocalizedError {
        case invalidHost
        case badResponse(Int)
        case decoding(Error)

        var errorDescription: String? {
            switch self {
            case .invalidHost:
                return "Enter a valid host, e.g. 192.168.1.23:8090."
            case .badResponse(let code):
                return "The server returned HTTP \(code)."
            case .decoding(let error):
                return "Couldn't understand the server's response: \(error.localizedDescription)"
            }
        }
    }

    private let session: URLSession
    let host: String

    init(host: String, session: URLSession = .shared) {
        self.host = host
        self.session = session
    }

    private func url(for path: String) throws -> URL {
        guard !host.isEmpty, let url = URL(string: "http://\(host)\(path)") else {
            throw ClientError.invalidHost
        }
        return url
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
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
}
