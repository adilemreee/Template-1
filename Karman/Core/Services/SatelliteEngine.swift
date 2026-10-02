import Foundation
import Metal
import Observation
import QuartzCore
import simd

/// Propagates satellite constellations off the main thread and keeps two keyframes of
/// positions that the GPU interpolates between, so thousands of satellites move smoothly.
@MainActor
@Observable
final class SatelliteEngine {
    enum Group: String, CaseIterable, Sendable {
        case stations, visual, starlink
    }

    struct Tracked: Sendable, Identifiable, Hashable {
        var id: Int
        var name: String
        var group: Group
    }

    struct Keyframes {
        var prev: MTLBuffer
        var next: MTLBuffer
        var count: Int
        var prevTime: CFTimeInterval
        var nextTime: CFTimeInterval
    }

    private(set) var catalogs: [Group: [OrbitalElements]] = [:]
    private(set) var tracked: [Group: [Tracked]] = [:]
    @ObservationIgnored private var propagators: [Group: [SGP4]] = [:]
    @ObservationIgnored private var buffers: [Group: [MTLBuffer]] = [:]
    @ObservationIgnored private var keyframes: [Group: Keyframes] = [:]
    @ObservationIgnored private var latestECEF: [Group: [SIMD3<Double>]] = [:]
    @ObservationIgnored private var bufferCursor: [Group: Int] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var enabledGroups: Set<Group> = [.stations, .visual]
    @ObservationIgnored private let device: MTLDevice?

    /// Orbit path of the ISS (render frame) over one revolution, refreshed periodically.
    private(set) var issPath: [PathVertex] = []
    private(set) var issPathVersion = 0
    @ObservationIgnored private var lastPathTime: Date = .distantPast

    init(device: MTLDevice?) {
        self.device = device
    }

    func load(group: Group, elements: [OrbitalElements]) {
        let props = elements.compactMap { try? SGP4(elements: $0) }
        catalogs[group] = elements
        propagators[group] = props
        tracked[group] = props.map { Tracked(id: $0.noradID, name: $0.name, group: group) }
        keyframes[group] = nil
        buffers[group] = nil
        lastPathTime = .distantPast
        start()
    }

    func keyframes(for group: Group) -> Keyframes? { keyframes[group] }

    var iss: SGP4? { propagators[.stations]?.first { $0.noradID == 25544 } }

    func propagator(id: Int) -> SGP4? {
        for g in Group.allCases { if let p = propagators[g]?.first(where: { $0.noradID == id }) { return p } }
        return nil
    }

    /// Latest Earth-fixed positions (km) for picking.
    func positions(for group: Group) -> [SIMD3<Double>] { latestECEF[group] ?? [] }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .milliseconds(1000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() async {
        let now = CACurrentMediaTime()
        let wall = Date()
        for group in Group.allCases where enabledGroups.contains(group) {
            guard let props = propagators[group], !props.isEmpty else { continue }
            let existing = keyframes[group]
            // The next keyframe is one second after the current "next" (or two seconds out at start).
            let targetMedia = (existing?.nextTime ?? now) + 1.0
            let targetDate = wall.addingTimeInterval(targetMedia - now)
            let result = await Self.propagate(props, at: targetDate)
            ensureBuffers(group: group, count: props.count)
            guard let bufs = buffers[group] else { continue }
            let cursor = ((bufferCursor[group] ?? 0) + 1) % bufs.count
            bufferCursor[group] = cursor
            let dest = bufs[cursor]
            result.render.withUnsafeBytes { raw in
                dest.contents().copyMemory(from: raw.baseAddress!, byteCount: min(raw.count, dest.length))
            }
            latestECEF[group] = result.ecef
            if let existing {
                keyframes[group] = Keyframes(prev: existing.next, next: dest, count: props.count, prevTime: existing.nextTime, nextTime: targetMedia)
            } else {
                // First frame: duplicate so the satellites appear immediately.
                keyframes[group] = Keyframes(prev: dest, next: dest, count: props.count, prevTime: now, nextTime: targetMedia)
            }
        }
        if wall.timeIntervalSince(lastPathTime) > 20, let iss {
            lastPathTime = wall
            issPath = await Self.orbitPath(iss, around: wall)
            issPathVersion &+= 1
        }
    }

    private func ensureBuffers(group: Group, count: Int) {
        if let b = buffers[group], b.first?.length == count * 16 { return }
        guard let device else { return }
        buffers[group] = (0..<3).compactMap { _ in device.makeBuffer(length: max(16, count * 16), options: .storageModeShared) }
        keyframes[group] = nil
    }

    struct Propagated: Sendable {
        var render: [SIMD4<Float>]
        var ecef: [SIMD3<Double>]
    }

    @concurrent
    nonisolated static func propagate(_ props: [SGP4], at date: Date) async -> Propagated {
        let sun = Astro.sunECEF(date)
        var render = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 0), count: props.count)
        var ecef = [SIMD3<Double>](repeating: .zero, count: props.count)
        let g = Astro.gmst(date)
        let cg = cos(g), sg = sin(g)
        for (i, p) in props.enumerated() {
            guard let teme = try? p.propagate(to: date).position else { continue }
            let e = SIMD3(cg * teme.x + sg * teme.y, -sg * teme.x + cg * teme.y, teme.z)
            ecef[i] = e
            let r = Geo.renderFrame(fromECEF: e) / Geo.earthRadiusKm
            let lit: Float = SatGeo.isSunlit(e, sun: sun) ? 1 : 0
            render[i] = SIMD4(Float(r.x), Float(r.y), Float(r.z), lit)
        }
        return Propagated(render: render, ecef: ecef)
    }

    @concurrent
    nonisolated static func orbitPath(_ sat: SGP4, around date: Date) async -> [PathVertex] {
        let period = sat.periodMinutes * 60
        let steps = 160
        var out: [PathVertex] = []
        out.reserveCapacity(steps + 1)
        for i in 0...steps {
            let f = Double(i) / Double(steps)
            let t = date.addingTimeInterval((f - 0.35) * period)
            guard let e = try? sat.ecef(at: t) else { continue }
            let r = Geo.renderFrame(fromECEF: e) / Geo.earthRadiusKm
            // Bright ahead of the station, fading behind it.
            let alpha: Float = f < 0.35 ? Float(f / 0.35) * 0.55 : Float(1 - (f - 0.35) / 0.65) * 0.9 + 0.1
            out.append(PathVertex(position: SIMD3<Float>(Float(r.x), Float(r.y), Float(r.z)), alpha: alpha))
        }
        return out
    }
}
