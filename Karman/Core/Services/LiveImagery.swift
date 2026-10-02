import Foundation
import Metal

/// Downloads yesterday's global true-colour mosaic (NASA GIBS via the Kármán API) once a day.
@MainActor
final class LiveImagery {
    static let shared = LiveImagery()
    private(set) var day: String?
    private(set) var isLoading = false

    private var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "imagery", directoryHint: .isDirectory)
    }

    func ensureLoaded(into globe: GlobeController) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let today = Self.expectedDay()
        let cached = cacheDir.appending(path: "\(today).jpg")
        var fileURL: URL?
        if FileManager.default.fileExists(atPath: cached.path()) {
            fileURL = cached
        } else if let (dayName, data) = try? await APIClient.shared.latestImagery(), !data.isEmpty {
            let name = dayName.isEmpty ? today : dayName
            let target = cacheDir.appending(path: "\(name).jpg")
            try? data.write(to: target, options: .atomic)
            fileURL = target
            pruneOld(keep: target)
        } else if let newest = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first {
            fileURL = newest
        }
        guard let fileURL, globe.liveImageryTexture == nil || day != fileURL.deletingPathExtension().lastPathComponent else { return }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
        let texture = await Task.detached(priority: .utility) { () -> SendableTexture? in
            MetalResources.loadTexture(url: fileURL, kind: .colorSRGB, device: device, queue: queue).map(SendableTexture.init)
        }.value
        if let texture {
            globe.liveImageryTexture = texture
            day = fileURL.deletingPathExtension().lastPathComponent
        }
    }

    private func pruneOld(keep: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f != keep { try? FileManager.default.removeItem(at: f) }
    }

    static func expectedDay() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date().addingTimeInterval(-86400))
    }
}
