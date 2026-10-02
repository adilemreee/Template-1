import Foundation
import simd

/// Near-Earth SGP4 propagator (Vallado et al., "Revisiting Spacetrack Report #3", WGS-72).
/// Deep-space (SDP4) orbits are rejected at initialisation; the API only ships LEO element sets.
nonisolated struct SGP4: Sendable {
    // WGS-72 constants used by SGP4.
    static let mu = 398600.8
    static let radiusEarthKm = 6378.135
    static let xke = 60.0 / sqrt(radiusEarthKm * radiusEarthKm * radiusEarthKm / mu)
    static let j2 = 0.001082616
    static let j3 = -0.00000253881
    static let j4 = -0.00000165597
    static let j3oj2 = j3 / j2
    static let x2o3 = 2.0 / 3.0
    static let twoPi = 2.0 * Double.pi

    enum Failure: Error { case deepSpace, decayed, eccentricity, meanMotion, semiLatusRectum }

    let epoch: Date
    let name: String
    let noradID: Int

    // Elements
    private let ecco, inclo, nodeo, argpo, mo, bstar, noUnkozai: Double
    // Initialised coefficients
    private let isimp: Bool
    private let aycof, con41, cc1, cc4, cc5, d2, d3, d4, delmo, eta, argpdot, omgcof, sinmao, t2cof, t3cof, t4cof, t5cof,
        x1mth2, x7thm1, mdot, nodedot, xlcof, xmcof, nodecf: Double

    init(elements e: OrbitalElements) throws {
        name = e.name
        noradID = e.id
        epoch = SGP4.parseEpoch(e.epoch) ?? Date()
        let deg = Double.pi / 180
        ecco = e.ecc
        inclo = e.inc * deg
        nodeo = e.raan * deg
        argpo = e.argp * deg
        mo = e.ma * deg
        bstar = e.bstar
        let noKozai = e.mm * SGP4.twoPi / 1440.0

        // ---- initl
        let eccsq = ecco * ecco
        let omeosq = 1 - eccsq
        let rteosq = sqrt(omeosq)
        let cosio = cos(inclo)
        let cosio2 = cosio * cosio
        let ak = pow(SGP4.xke / noKozai, SGP4.x2o3)
        let d1 = 0.75 * SGP4.j2 * (3 * cosio2 - 1) / (rteosq * omeosq)
        var del = d1 / (ak * ak)
        let adel = ak * (1 - del * del - del * (1.0 / 3.0 + 134 * del * del / 81))
        del = d1 / (adel * adel)
        noUnkozai = noKozai / (1 + del)
        let ao = pow(SGP4.xke / noUnkozai, SGP4.x2o3)
        let sinio = sin(inclo)
        let po = ao * omeosq
        let con42 = 1 - 5 * cosio2
        con41 = -con42 - cosio2 - cosio2
        let posq = po * po
        let rp = ao * (1 - ecco)

        if SGP4.twoPi / noUnkozai >= 225 { throw Failure.deepSpace }

        // ---- sgp4init
        let ss = 78 / SGP4.radiusEarthKm + 1
        let qzms2t = pow((120 - 78) / SGP4.radiusEarthKm, 4)
        isimp = rp < (220 / SGP4.radiusEarthKm + 1)
        var sfour = ss
        var qzms24 = qzms2t
        let perige = (rp - 1) * SGP4.radiusEarthKm
        if perige < 156 {
            sfour = perige < 98 ? 20 : perige - 78
            qzms24 = pow((120 - sfour) / SGP4.radiusEarthKm, 4)
            sfour = sfour / SGP4.radiusEarthKm + 1
        }
        let pinvsq = 1 / posq
        let tsi = 1 / (ao - sfour)
        eta = ao * ecco * tsi
        let etasq = eta * eta
        let eeta = ecco * eta
        let psisq = abs(1 - etasq)
        let coef = qzms24 * pow(tsi, 4)
        let coef1 = coef / pow(psisq, 3.5)
        let cc2 = coef1 * noUnkozai * (ao * (1 + 1.5 * etasq + eeta * (4 + etasq))
            + 0.375 * SGP4.j2 * tsi / psisq * con41 * (8 + 3 * etasq * (8 + etasq)))
        cc1 = bstar * cc2
        var cc3 = 0.0
        if ecco > 1e-4 { cc3 = -2 * coef * tsi * SGP4.j3oj2 * noUnkozai * sinio / ecco }
        x1mth2 = 1 - cosio2
        cc4 = 2 * noUnkozai * coef1 * ao * omeosq * (eta * (2 + 0.5 * etasq) + ecco * (0.5 + 2 * etasq)
            - SGP4.j2 * tsi / (ao * psisq) * (-3 * con41 * (1 - 2 * eeta + etasq * (1.5 - 0.5 * eeta))
            + 0.75 * x1mth2 * (2 * etasq - eeta * (1 + etasq)) * cos(2 * argpo)))
        cc5 = 2 * coef1 * ao * omeosq * (1 + 2.75 * (etasq + eeta) + eeta * etasq)
        let cosio4 = cosio2 * cosio2
        let temp1 = 1.5 * SGP4.j2 * pinvsq * noUnkozai
        let temp2 = 0.5 * temp1 * SGP4.j2 * pinvsq
        let temp3 = -0.46875 * SGP4.j4 * pinvsq * pinvsq * noUnkozai
        mdot = noUnkozai + 0.5 * temp1 * rteosq * con41 + 0.0625 * temp2 * rteosq * (13 - 78 * cosio2 + 137 * cosio4)
        argpdot = -0.5 * temp1 * con42 + 0.0625 * temp2 * (7 - 114 * cosio2 + 395 * cosio4) + temp3 * (3 - 36 * cosio2 + 49 * cosio4)
        let xhdot1 = -temp1 * cosio
        nodedot = xhdot1 + (0.5 * temp2 * (4 - 19 * cosio2) + 2 * temp3 * (3 - 7 * cosio2)) * cosio
        omgcof = bstar * cc3 * cos(argpo)
        xmcof = ecco > 1e-4 ? -SGP4.x2o3 * coef * bstar / eeta : 0
        nodecf = 3.5 * omeosq * xhdot1 * cc1
        t2cof = 1.5 * cc1
        if abs(cosio + 1) > 1.5e-12 {
            xlcof = -0.25 * SGP4.j3oj2 * sinio * (3 + 5 * cosio) / (1 + cosio)
        } else {
            xlcof = -0.25 * SGP4.j3oj2 * sinio * (3 + 5 * cosio) / 1.5e-12
        }
        aycof = -0.5 * SGP4.j3oj2 * sinio
        delmo = pow(1 + eta * cos(mo), 3)
        sinmao = sin(mo)
        x7thm1 = 7 * cosio2 - 1

        if !isimp {
            let cc1sq = cc1 * cc1
            d2 = 4 * ao * tsi * cc1sq
            let temp = d2 * tsi * cc1 / 3
            d3 = (17 * ao + sfour) * temp
            d4 = 0.5 * temp * ao * tsi * (221 * ao + 31 * sfour) * cc1
            t3cof = d2 + 2 * cc1sq
            t4cof = 0.25 * (3 * d3 + cc1 * (12 * d2 + 10 * cc1sq))
            t5cof = 0.2 * (3 * d4 + 12 * cc1 * d3 + 6 * d2 * d2 + 15 * cc1sq * (2 * d2 + cc1sq))
        } else {
            d2 = 0; d3 = 0; d4 = 0; t3cof = 0; t4cof = 0; t5cof = 0
        }
    }

    /// Position (km) and velocity (km/s) in the TEME frame at minutes since epoch.
    func propagate(minutes t: Double) throws -> (position: SIMD3<Double>, velocity: SIMD3<Double>) {
        let xmdf = mo + mdot * t
        let argpdf = argpo + argpdot * t
        let nodedf = nodeo + nodedot * t
        var argpm = argpdf
        var mm = xmdf
        let t2 = t * t
        var nodem = nodedf + nodecf * t2
        var tempa = 1 - cc1 * t
        var tempe = bstar * cc4 * t
        var templ = t2cof * t2

        if !isimp {
            let delomg = omgcof * t
            let delmtemp = 1 + eta * cos(xmdf)
            let delm = xmcof * (delmtemp * delmtemp * delmtemp - delmo)
            let temp = delomg + delm
            mm = xmdf + temp
            argpm = argpdf - temp
            let t3 = t2 * t
            let t4 = t3 * t
            tempa = tempa - d2 * t2 - d3 * t3 - d4 * t4
            tempe = tempe + bstar * cc5 * (sin(mm) - sinmao)
            templ = templ + t3cof * t3 + t4 * (t4cof + t * t5cof)
        }

        var nm = noUnkozai
        var em = ecco
        let inclm = inclo
        guard nm > 0 else { throw Failure.meanMotion }
        let am = pow(SGP4.xke / nm, SGP4.x2o3) * tempa * tempa
        nm = SGP4.xke / pow(am, 1.5)
        em = em - tempe
        guard em < 1, em >= -0.001 else { throw Failure.eccentricity }
        if em < 1e-6 { em = 1e-6 }
        mm = mm + noUnkozai * templ
        var xlm = mm + argpm + nodem
        nodem = fmod(nodem, SGP4.twoPi)
        argpm = fmod(argpm, SGP4.twoPi)
        xlm = fmod(xlm, SGP4.twoPi)
        mm = fmod(xlm - argpm - nodem, SGP4.twoPi)

        let sinim = sin(inclm), cosim = cos(inclm)
        let ep = em
        let axnl = ep * cos(argpm)
        var temp = 1 / (am * (1 - ep * ep))
        let aynl = ep * sin(argpm) + temp * aycof
        let xl = mm + argpm + nodem + temp * xlcof * axnl

        // Kepler's equation
        let u = fmod(xl - nodem, SGP4.twoPi)
        var eo1 = u
        var tem5 = 9999.9
        var ktr = 1
        var sineo1 = 0.0, coseo1 = 0.0
        while abs(tem5) >= 1e-12 && ktr <= 10 {
            sineo1 = sin(eo1)
            coseo1 = cos(eo1)
            tem5 = 1 - coseo1 * axnl - sineo1 * aynl
            tem5 = (u - aynl * coseo1 + axnl * sineo1 - eo1) / tem5
            if abs(tem5) >= 0.95 { tem5 = tem5 > 0 ? 0.95 : -0.95 }
            eo1 += tem5
            ktr += 1
        }

        let ecose = axnl * coseo1 + aynl * sineo1
        let esine = axnl * sineo1 - aynl * coseo1
        let el2 = axnl * axnl + aynl * aynl
        let pl = am * (1 - el2)
        guard pl >= 0 else { throw Failure.semiLatusRectum }
        let rl = am * (1 - ecose)
        let rdotl = sqrt(am) * esine / rl
        let rvdotl = sqrt(pl) / rl
        let betal = sqrt(1 - el2)
        temp = esine / (1 + betal)
        let sinu = am / rl * (sineo1 - aynl - axnl * temp)
        let cosu = am / rl * (coseo1 - axnl + aynl * temp)
        var su = atan2(sinu, cosu)
        let sin2u = (cosu + cosu) * sinu
        let cos2u = 1 - 2 * sinu * sinu
        temp = 1 / pl
        let temp1 = 0.5 * SGP4.j2 * temp
        let temp2 = temp1 * temp

        let mrt = rl * (1 - 1.5 * temp2 * betal * con41) + 0.5 * temp1 * x1mth2 * cos2u
        su = su - 0.25 * temp2 * x7thm1 * sin2u
        let xnode = nodem + 1.5 * temp2 * cosim * sin2u
        let xinc = inclm + 1.5 * temp2 * cosim * sinim * cos2u
        let mvt = rdotl - nm * temp1 * x1mth2 * sin2u / SGP4.xke
        let rvdot = rvdotl + nm * temp1 * (x1mth2 * cos2u + 1.5 * con41) / SGP4.xke

        let sinsu = sin(su), cossu = cos(su)
        let snod = sin(xnode), cnod = cos(xnode)
        let sini = sin(xinc), cosi = cos(xinc)
        let xmx = -snod * cosi
        let xmy = cnod * cosi
        let ux = xmx * sinsu + cnod * cossu
        let uy = xmy * sinsu + snod * cossu
        let uz = sini * sinsu
        let vx = xmx * cossu - cnod * sinsu
        let vy = xmy * cossu - snod * sinsu
        let vz = sini * cossu

        guard mrt >= 1 else { throw Failure.decayed }
        let r = SIMD3(mrt * ux, mrt * uy, mrt * uz) * SGP4.radiusEarthKm
        let vkmpersec = SGP4.radiusEarthKm * SGP4.xke / 60
        let v = SIMD3(mvt * ux + rvdot * vx, mvt * uy + rvdot * vy, mvt * uz + rvdot * vz) * vkmpersec
        return (r, v)
    }

    func propagate(to date: Date) throws -> (position: SIMD3<Double>, velocity: SIMD3<Double>) {
        try propagate(minutes: date.timeIntervalSince(epoch) / 60)
    }

    /// Earth-fixed position (km, ECEF with Z = north) at `date`.
    func ecef(at date: Date) throws -> SIMD3<Double> {
        let teme = try propagate(to: date).position
        let g = Astro.gmst(date)
        return SIMD3(cos(g) * teme.x + sin(g) * teme.y, -sin(g) * teme.x + cos(g) * teme.y, teme.z)
    }

    /// Orbital period in minutes.
    var periodMinutes: Double { SGP4.twoPi / noUnkozai }

    static func parseEpoch(_ s: String) -> Date? {
        var str = s
        if !str.hasSuffix("Z") { str += "Z" }
        return KarmanJSON.parseISO8601(str)
    }
}

/// Geodetic helpers for satellite positions.
nonisolated enum SatGeo {
    /// Sub-satellite point and altitude (spherical Earth approximation, fine for display).
    static func subpoint(ecef p: SIMD3<Double>) -> (point: GeoPoint, altitudeKm: Double) {
        let r = simd_length(p)
        let lat = asin(p.z / r) * 180 / .pi
        let lon = atan2(p.y, p.x) * 180 / .pi
        return (GeoPoint(lat: lat, lon: lon), r - Geo.earthRadiusKm)
    }

    /// Topocentric look angles from an observer to an ECEF position.
    static func lookAngles(observer: GeoPoint, observerAltKm: Double = 0, target p: SIMD3<Double>) -> (azimuth: Double, elevation: Double, rangeKm: Double) {
        let φ = observer.lat * .pi / 180, λ = observer.lon * .pi / 180
        let rObs = Geo.earthRadiusKm + observerAltKm
        let o = SIMD3(rObs * cos(φ) * cos(λ), rObs * cos(φ) * sin(λ), rObs * sin(φ))
        let d = p - o
        // South-East-Zenith frame
        let s = sin(φ) * cos(λ) * d.x + sin(φ) * sin(λ) * d.y - cos(φ) * d.z
        let e = -sin(λ) * d.x + cos(λ) * d.y
        let z = cos(φ) * cos(λ) * d.x + cos(φ) * sin(λ) * d.y + sin(φ) * d.z
        let range = simd_length(d)
        let el = asin(z / range) * 180 / .pi
        var az = atan2(e, -s) * 180 / .pi
        if az < 0 { az += 360 }
        return (az, el, range)
    }

    /// Whether a satellite at `p` (ECEF km) is lit by the Sun (cylindrical shadow model).
    static func isSunlit(_ p: SIMD3<Double>, sun: SIMD3<Double>) -> Bool {
        let s = simd_normalize(sun)
        let proj = simd_dot(p, s)
        if proj > 0 { return true }
        let perp = simd_length(p - proj * s)
        return perp > Geo.earthRadiusKm
    }
}
