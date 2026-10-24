import Foundation

/// Compass heading from the raw magnetometer and gravity, so the watch needs no
/// location permission (DECISIONS D-11): all location context comes from the iPhone.
///
/// Tilt-compensated: east = down × magnetic, north = east × down; the heading of the
/// device's +y axis (top of the watch face) is atan2(east.y, north.y), clockwise from
/// magnetic north. The magnetometer is uncalibrated, so absolute heading can be off by a
/// fixed offset; the engine only uses heading *changes* (heading_change_deg).
public enum Compass {
    public static func heading(gravity g: [Double], magnetic m: [Double]) -> Double? {
        guard g.count == 3, m.count == 3 else { return nil }
        let east = cross(g, m)
        let north = cross(east, g)
        let ne = norm(east), nn = norm(north)
        guard ne > 1e-9, nn > 1e-9 else { return nil }      // field parallel to gravity
        var deg = atan2(east[1] / ne, north[1] / nn) * 180 / .pi
        if deg < 0 { deg += 360 }
        return deg
    }

    static func cross(_ a: [Double], _ b: [Double]) -> [Double] {
        [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
    }

    static func norm(_ v: [Double]) -> Double { (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).squareRoot() }
}
