import Foundation

// Pure geometry for deciding whether a location fix is inside a campus space.
// Everything here runs on the device; nothing in this file is ever sent anywhere.
//
// Membership is conservative by design (docs/CAMPUS_SPACES_DESIGN.md §3.1): a fix counts as INSIDE only if its
// whole accuracy circle (plus a safety margin) lies inside the space, and OUTSIDE only if the whole circle lies
// outside. Anything in between is "straddling" and is treated as uncertain.

nonisolated struct GeoPoint: Equatable, Hashable, Sendable, Codable {
    var latitude: Double
    var longitude: Double
}

/// A zone made of one or more polygons (GeoJSON Polygon or MultiPolygon). Holes are not supported and not needed
/// for open lawns and plazas; inner rings, if present, are ignored.
nonisolated struct ZoneShape: Equatable, Sendable {
    /// Outer rings, each closed (first == last), in GeoJSON order.
    var rings: [[GeoPoint]]

    /// Points sampled on the accuracy circle (and again at half radius). 64 points on a 50 m circle are ~5 m apart,
    /// finer than any notch in a lawn- or plaza-sized outline.
    static let circleSamples = 64

    enum Relation: Equatable, Sendable {
        /// The whole accuracy circle (plus margin) is inside the zone.
        case inside
        /// The whole accuracy circle (plus margin) is outside the zone.
        case outside
        /// The circle crosses the boundary. `centerInside` says which side the fix itself is on.
        case straddling(centerInside: Bool)
    }

    /// Where a fix with the given accuracy radius sits relative to this zone.
    func relation(of point: GeoPoint, radius: Double) -> Relation {
        let projection = LocalProjection(origin: point)
        let polygons = rings.map { $0.map(projection.project) }
        let center = Vec2(x: 0, y: 0)
        let centerInside = polygons.contains { Self.contains($0, center) }

        // Sample against the UNION of the rings, so the seam between two abutting polygons of one zone
        // (e.g. Alumni Park and Hahn Plaza) is not treated as a boundary.
        var anyIn = centerInside, anyOut = !centerInside
        for scale in [1.0, 0.5] {
            for i in 0..<Self.circleSamples {
                let angle = Double(i) / Double(Self.circleSamples) * 2 * .pi
                let p = Vec2(x: scale * radius * cos(angle), y: scale * radius * sin(angle))
                if polygons.contains(where: { Self.contains($0, p) }) { anyIn = true } else { anyOut = true }
                if anyIn && anyOut { return .straddling(centerInside: centerInside) }
            }
        }
        if centerInside { return .inside }
        // Outside: any ring edge within the radius means part of the circle is inside that ring, so a corner
        // poking between samples can't be missed.
        let nearest = polygons.map { Self.distanceToBoundary($0, center) }.min() ?? .infinity
        return nearest < radius ? .straddling(centerInside: false) : .outside
    }

    /// Whether the point itself lies inside the zone (any of its polygons). Used by the `point` membership rule.
    func contains(_ point: GeoPoint) -> Bool {
        let projection = LocalProjection(origin: point)
        return rings.contains { Self.contains($0.map(projection.project), Vec2(x: 0, y: 0)) }
    }

    /// Distance in metres from the point to the nearest boundary of the zone (∞ for an empty zone).
    func distanceToBoundary(from point: GeoPoint) -> Double {
        let projection = LocalProjection(origin: point)
        return rings.map { Self.distanceToBoundary($0.map(projection.project), Vec2(x: 0, y: 0)) }.min() ?? .infinity
    }

    /// Smallest distance in metres between this zone's boundary and another's (0 if they touch or overlap).
    func minimumDistance(to other: ZoneShape) -> Double {
        guard let origin = rings.first?.first else { return .infinity }
        let projection = LocalProjection(origin: origin)
        let mine = rings.map { $0.map(projection.project) }
        let theirs = other.rings.map { $0.map(projection.project) }
        for a in mine { for b in theirs where a.contains(where: { Self.contains(b, $0) }) || b.contains(where: { Self.contains(a, $0) }) { return 0 } }
        var best = Double.infinity
        for a in mine {
            for b in theirs {
                for p in a { best = min(best, Self.distanceToBoundary(b, p)) }
                for p in b { best = min(best, Self.distanceToBoundary(a, p)) }
            }
        }
        return best
    }

    // MARK: Planar helpers (metres, local tangent plane)

    struct Vec2: Equatable { var x: Double; var y: Double }

    /// Ray casting. Points exactly on an edge may land either way; callers never rely on that.
    static func contains(_ ring: [Vec2], _ p: Vec2) -> Bool {
        guard ring.count >= 4 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    static func distanceToBoundary(_ ring: [Vec2], _ p: Vec2) -> Double {
        guard ring.count >= 2 else { return .infinity }
        var best = Double.infinity
        for i in 0..<(ring.count - 1) {
            best = min(best, segmentDistance(p, ring[i], ring[i + 1]))
        }
        return best
    }

    static func segmentDistance(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }
}

/// Equirectangular projection around an origin. Error is far below a metre within a few kilometres, which is all a
/// campus needs.
nonisolated struct LocalProjection: Sendable {
    let origin: GeoPoint
    private let metresPerDegreeLat: Double
    private let metresPerDegreeLon: Double

    init(origin: GeoPoint) {
        self.origin = origin
        let phi = origin.latitude * .pi / 180
        // WGS-84 series expansions for metres per degree.
        metresPerDegreeLat = 111_132.92 - 559.82 * cos(2 * phi) + 1.175 * cos(4 * phi)
        metresPerDegreeLon = 111_412.84 * cos(phi) - 93.5 * cos(3 * phi)
    }

    func project(_ p: GeoPoint) -> ZoneShape.Vec2 {
        ZoneShape.Vec2(x: (p.longitude - origin.longitude) * metresPerDegreeLon,
                       y: (p.latitude - origin.latitude) * metresPerDegreeLat)
    }

    func unproject(_ v: ZoneShape.Vec2) -> GeoPoint {
        GeoPoint(latitude: origin.latitude + v.y / metresPerDegreeLat,
                 longitude: origin.longitude + v.x / metresPerDegreeLon)
    }
}
