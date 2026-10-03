import CryptoKit
import Foundation
import Security

/// Talks to the Kármán API. TLS is pinned to the server's public key when a pin is configured
/// (the default deployment uses a self-signed certificate on a dedicated IP).
nonisolated final class APIClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let shared = APIClient()

    let baseURL: URL
    private let pin: String
    let devToken: String
    private(set) var session: URLSession!

    enum APIError: LocalizedError {
        case http(Int, String?)
        case notModified
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .http(let code, let msg): return msg ?? "HTTP \(code)"
            case .notModified: return "Not modified"
            case .invalidResponse: return "Invalid response"
            }
        }
    }

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let base = (info["KarmanAPIBaseURL"] as? String).flatMap { $0.isEmpty || $0.contains("$(") ? nil : $0 } ?? "https://karman.adilemree.xyz:9443"
        #if targetEnvironment(simulator)
        let override = ProcessInfo.processInfo.environment["KARMAN_API_BASE_URL"]
        baseURL = URL(string: override ?? base)!
        #else
        baseURL = URL(string: base)!
        #endif
        pin = (info["KarmanAPIPin"] as? String).flatMap { $0.contains("$(") ? nil : $0 } ?? ""
        #if DEBUG
        devToken = ProcessInfo.processInfo.environment["KARMAN_DEV_TOKEN"] ?? (info["KarmanDevToken"] as? String).flatMap { $0.contains("$(") ? nil : $0 } ?? ""
        #else
        devToken = ""
        #endif
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "Karman-iOS/1.0", "Accept-Encoding": "gzip"]
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: Pinning

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        guard !pin.isEmpty, challenge.protectionSpace.host == baseURL.host() else {
            return (.performDefaultHandling, nil)
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              let key = SecCertificateCopyKey(leaf), let spkiHash = Self.spkiSHA256(key) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        guard spkiHash == pin else { return (.cancelAuthenticationChallenge, nil) }
        // Make the pinned certificate the only anchor, so the system evaluation that App
        // Transport Security repeats on top of ours trusts exactly this server and nothing else.
        SecTrustSetAnchorCertificates(trust, [leaf] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    static func spkiSHA256(_ key: SecKey) -> String? {
        guard let attrs = SecKeyCopyAttributes(key) as? [CFString: Any],
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        let type = attrs[kSecAttrKeyType] as? String
        let bits = attrs[kSecAttrKeySizeInBits] as? Int ?? 0
        var header: [UInt8]
        if type == (kSecAttrKeyTypeECSECPrimeRandom as String), bits == 256 {
            header = [0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00]
        } else if type == (kSecAttrKeyTypeRSA as String), bits == 2048 {
            header = [0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00]
        } else {
            return nil
        }
        var spki = Data(header)
        spki.append(raw)
        return Data(SHA256.hash(data: spki)).base64EncodedString()
    }

    // MARK: Requests

    func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil, token: String? = nil, etag: String? = nil) -> URLRequest {
        var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        else if !devToken.isEmpty { req.setValue("Dev \(devToken)", forHTTPHeaderField: "Authorization") }
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return req
    }

    func data(for req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 304 { throw APIError.notModified }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw APIError.http(http.statusCode, msg)
        }
        return (data, http)
    }

    func snapshot(etag: String?) async throws -> (PlanetSnapshot, String?, Data) {
        let (data, http) = try await data(for: request("v1/snapshot", etag: etag))
        let snap = try KarmanJSON.decoder().decode(PlanetSnapshot.self, from: data)
        return (snap, http.value(forHTTPHeaderField: "ETag"), data)
    }

    func satellites(group: String) async throws -> ([OrbitalElements], Data) {
        let (data, _) = try await data(for: request("v1/satellites/\(group)"))
        return (try JSONDecoder().decode([OrbitalElements].self, from: data), data)
    }

    func briefing(language: String) async throws -> Briefing {
        let (data, _) = try await data(for: request("v1/briefing", query: [URLQueryItem(name: "lang", value: language)]))
        return try KarmanJSON.decoder().decode(Briefing.self, from: data)
    }

    func sunImage(band: String) async throws -> (data: Data, observed: Date?) {
        let (data, http) = try await data(for: request("v1/sun/\(band)"))
        return (data, http.value(forHTTPHeaderField: "X-Observed").flatMap(KarmanJSON.parseISO8601))
    }

    struct SunFrames: Decodable {
        struct Frame: Decodable { var id: String; var t: Date }
        var frames: [Frame]
    }

    func sunFrames(band: String) async throws -> SunFrames {
        let (data, _) = try await data(for: request("v1/sun/\(band)/frames"))
        return try KarmanJSON.decoder().decode(SunFrames.self, from: data)
    }

    func sunFrame(band: String, id: String) async throws -> Data {
        try await data(for: request("v1/sun/\(band)/frames/\(id)")).0
    }

    func latestImagery() async throws -> (day: String, data: Data) {
        let (data, http) = try await data(for: request("v1/imagery/latest"))
        return (http.value(forHTTPHeaderField: "X-Imagery-Day") ?? "", data)
    }

    struct TokenResponse: Decodable { var token: String; var expiresAt: Date }

    func authenticate(appTransactionJWS: String) async throws -> TokenResponse {
        let body = try JSONEncoder().encode(["jws": appTransactionJWS])
        let (data, _) = try await data(for: request("v1/auth/app-transaction", method: "POST", body: body))
        return try KarmanJSON.decoder().decode(TokenResponse.self, from: data)
    }

    struct Quota: Decodable { var remaining: Int; var limit: Int; var enabled: Bool }

    func askQuota(token: String?) async throws -> Quota {
        let (data, _) = try await data(for: request("v1/ask/quota", token: token))
        return try JSONDecoder().decode(Quota.self, from: data)
    }

    struct AskTurn: Codable, Sendable { var role: String; var text: String }
    /// What the user was looking at when they asked ("Ask about this").
    struct AskAbout: Codable, Sendable, Hashable {
        var refId: String
        var kind: String
        var title: String
        var details: String?
    }
    struct AskBody: Codable, Sendable {
        var question: String
        var language: String
        var lat: Double?
        var lon: Double?
        var history: [AskTurn]
        var about: AskAbout?
    }

    /// A place the answer is about; the app flies the globe there while the text streams.
    struct GlobeFocus: Codable, Sendable, Hashable {
        var refId: String
        var kind: String
        var title: String
        var lat: Double
        var lon: Double
    }

    enum AskEvent: Sendable { case delta(String), focus([GlobeFocus]), done(remaining: Int), failure(String) }

    /// Streams an answer as server-sent events.
    func ask(_ body: AskBody, token: String?) -> AsyncThrowingStream<AskEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = request("v1/ask", method: "POST", body: try JSONEncoder().encode(body), token: token)
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.timeoutInterval = 90
                    let (bytes, resp) = try await session.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
                    guard http.statusCode == 200 else {
                        var raw = Data()
                        for try await b in bytes { raw.append(b); if raw.count > 4096 { break } }
                        let msg = (try? JSONDecoder().decode([String: String].self, from: raw))?["error"]
                        throw APIError.http(http.statusCode, msg)
                    }
                    var event = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let payload = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                            let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
                            switch event {
                            case "delta": continuation.yield(.delta(obj["text"] as? String ?? ""))
                            case "focus":
                                struct Items: Decodable { var items: [GlobeFocus] }
                                if let items = try? JSONDecoder().decode(Items.self, from: payload).items, !items.isEmpty {
                                    continuation.yield(.focus(items))
                                }
                            case "done": continuation.yield(.done(remaining: obj["remaining"] as? Int ?? 0))
                            case "error": continuation.yield(.failure(obj["message"] as? String ?? ""))
                            default: break
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    struct DeviceRegistration: Codable, Sendable {
        struct Prefs: Codable, Sendable {
            var quakeMinMag: Double
            var quakeRadiusKm: Double
            var globalMajor: Bool
            var aurora: Bool
            var auroraMinChance: Int
            var launches: Bool
            var spaceStorms: Bool
        }
        var token: String
        var env: String
        var lat: Double?
        var lon: Double?
        var language: String
        var tzOffsetMinutes: Int
        var prefs: Prefs
        var places: [WatchedPlaceBody]?
    }

    /// A watched place as the server stores it (rounded to about 50 km before it leaves the phone).
    struct WatchedPlaceBody: Codable, Sendable, Hashable {
        var name: String
        var lat: Double
        var lon: Double
    }

    // MARK: Weather, history, plates, clouds

    struct WeatherIndex: Decodable, Sendable {
        struct Frame: Decodable, Sendable, Hashable { var id: String; var valid: Date }
        var frames: [Frame]
        var width: Int
        var height: Int
        var attribution: String?
    }

    func weatherIndex() async throws -> WeatherIndex {
        let (data, _) = try await data(for: request("v1/weather"))
        return try KarmanJSON.decoder().decode(WeatherIndex.self, from: data)
    }

    /// One packed GFS time step (360×181 RGBA8; see WeatherGrid). Frames are immutable per id.
    func weatherFrame(id: String) async throws -> Data {
        try await data(for: request("v1/weather/\(id)")).0
    }

    struct QuakeYear: Decodable, Sendable {
        var from: Date
        var to: Date
        var minMag: Double
        var quakes: [Quake]
    }

    func quakeYear() async throws -> (QuakeYear, Data) {
        let (data, _) = try await data(for: request("v1/quakes/year"))
        return (try KarmanJSON.decoder().decode(QuakeYear.self, from: data), data)
    }

    func plates() async throws -> Data {
        try await data(for: request("v1/plates")).0
    }

    struct CloudForecast: Decodable, Sendable {
        struct Point: Decodable, Sendable { var t: Date; var cloud: Double; var humidity: Double; var tempC: Double }
        var lat: Double
        var lon: Double
        var points: [Point]
        var attribution: String?
    }

    /// Hourly cloud cover for stargazing (MET Norway, via the Kármán API; ~50 km precision).
    func clouds(lat: Double, lon: Double) async throws -> CloudForecast {
        let q = [URLQueryItem(name: "lat", value: String(format: "%.1f", lat)), URLQueryItem(name: "lon", value: String(format: "%.1f", lon))]
        let (data, _) = try await data(for: request("v1/sky/clouds", query: q))
        return try KarmanJSON.decoder().decode(CloudForecast.self, from: data)
    }

    func register(device: DeviceRegistration) async throws {
        _ = try await data(for: request("v1/devices", method: "POST", body: try JSONEncoder().encode(device)))
    }
}
