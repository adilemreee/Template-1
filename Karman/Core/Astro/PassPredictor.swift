import Foundation
import simd

/// Predicts naked-eye passes: satellite above the horizon, lit by the Sun, observer in twilight/night.
enum PassPredictor {
    struct Sample: Sendable, Hashable {
        var time: Date
        var azimuth: Double
        var elevation: Double
    }

    struct Pass: Sendable, Hashable, Identifiable {
        var satellite: String
        var noradID: Int
        var start: Date
        var peak: Date
        var end: Date
        var maxElevation: Double
        var startAzimuth: Double
        var peakAzimuth: Double
        var endAzimuth: Double
        var magnitude: Double
        var visible: Bool
        var track: [Sample]
        var id: String { "\(noradID)-\(Int(start.timeIntervalSince1970))" }

        var widget: WidgetState.Pass {
            WidgetState.Pass(satellite: satellite, start: start, peak: peak, end: end, maxElevation: maxElevation,
                             startAzimuth: startAzimuth, endAzimuth: endAzimuth, magnitude: magnitude)
        }
    }

    static func passes(for sat: SGP4, observer: GeoPoint, from start: Date = Date(), hours: Double = 72,
                       minElevation: Double = 10, visibleOnly: Bool = true) -> [Pass] {
        var result: [Pass] = []
        let step: TimeInterval = 20
        var t = start
        let end = start.addingTimeInterval(hours * 3600)
        var inPass = false
        var current: [Sample] = []

        func look(_ date: Date) -> (az: Double, el: Double, range: Double, ecef: SIMD3<Double>)? {
            guard let e = try? sat.ecef(at: date) else { return nil }
            let l = SatGeo.lookAngles(observer: observer, target: e)
            return (l.azimuth, l.elevation, l.rangeKm, e)
        }

        while t < end {
            guard let l = look(t) else { t += step; continue }
            if l.el > 0 {
                if !inPass { inPass = true; current = [] }
                current.append(Sample(time: t, azimuth: l.az, elevation: l.el))
            } else if inPass {
                inPass = false
                if let pass = finalize(current, sat: sat, observer: observer, minElevation: minElevation, look: look) {
                    if !visibleOnly || pass.visible { result.append(pass) }
                }
            }
            // Skip ahead faster when the satellite is far below the horizon.
            t += l.el < -25 ? step * 6 : step
        }
        return result
    }

    private static func finalize(_ samples: [Sample], sat: SGP4, observer: GeoPoint, minElevation: Double,
                                 look: (Date) -> (az: Double, el: Double, range: Double, ecef: SIMD3<Double>)?) -> Pass? {
        guard let first = samples.first, let last = samples.last,
              let peakSample = samples.max(by: { $0.elevation < $1.elevation }), peakSample.elevation >= minElevation else { return nil }
        // Visibility at the peak: satellite sunlit while the observer's sky is dark.
        var visible = false
        var magnitude = 9.0
        var visibleSamples: [Sample] = []
        for s in samples {
            guard let l = look(s.time) else { continue }
            let sun = Astro.sunECEF(s.time)
            let lit = SatGeo.isSunlit(l.ecef, sun: sun * 149_597_870.7)
            let sunAlt = Astro.sunAltitude(at: s.time, observer: observer)
            if lit && sunAlt < -6 {
                visible = true
                visibleSamples.append(s)
                // Diffuse-sphere phase function relative to 90°.
                let obsECEF = observerECEF(observer)
                let toObs = simd_normalize(obsECEF - l.ecef)
                let toSun = simd_normalize(sun)
                let phase = acos(max(-1, min(1, simd_dot(toObs, toSun))))
                let f = (sin(phase) + (.pi - phase) * cos(phase)) / .pi
                let m = -1.3 + 5 * log10(l.range / 1000) - 2.5 * log10(max(f, 0.01) * .pi)
                magnitude = min(magnitude, m)
            }
        }
        let track = visibleSamples.isEmpty ? samples : visibleSamples
        guard let vStart = track.first, let vEnd = track.last, let vPeak = track.max(by: { $0.elevation < $1.elevation }),
              vPeak.elevation >= minElevation, vEnd.time.timeIntervalSince(vStart.time) >= 60 else { return nil }
        _ = (first, last)
        return Pass(satellite: sat.name, noradID: sat.noradID, start: vStart.time, peak: vPeak.time, end: vEnd.time,
                    maxElevation: vPeak.elevation, startAzimuth: vStart.azimuth, peakAzimuth: vPeak.azimuth, endAzimuth: vEnd.azimuth,
                    magnitude: visible ? magnitude : 9, visible: visible, track: samples)
    }

    static func observerECEF(_ p: GeoPoint) -> SIMD3<Double> {
        let φ = p.lat * .pi / 180, λ = p.lon * .pi / 180
        let r = Geo.earthRadiusKm
        return SIMD3(r * cos(φ) * cos(λ), r * cos(φ) * sin(λ), r * sin(φ))
    }
}
