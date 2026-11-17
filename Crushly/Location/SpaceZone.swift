import Foundation

/// A supported campus space as configured on the server (`public.campus_spaces`) or in the bundled fallback
/// (`Resources/campus_spaces.json`). Same JSON shape in both places.
nonisolated struct SpaceZone: Identifiable, Equatable, Sendable {
    enum ValidationStatus: String, Codable, Sendable {
        /// Traced from a map; not yet walked with a device. Never usable in production.
        case draft
        /// Walked and adjusted on site.
        case fieldValidated = "field_validated"
    }

    /// How a fix is judged against this zone (docs/CAMPUS_SPACES_DESIGN.md §3.1a).
    enum MembershipRule: String, Codable, Sendable {
        /// Default, for open-air spaces: the whole accuracy circle (plus margin) must be inside.
        case circle
        /// For buildings, where indoor fixes are too coarse for `circle`: the fix's own position must be inside.
        /// Weaker: someone just outside the walls can count when their GPS errs inward.
        case point
    }

    var slug: String
    var name: String
    var subtitle: String?
    var shape: ZoneShape
    var boundaryVersion: Int
    var validationStatus: ValidationStatus
    var enabled: Bool
    var sortOrder: Int
    var membershipRule: MembershipRule = .circle
    /// Per-zone limit on fix accuracy (metres). nil = the global `evidence_max_accuracy_m`. The server enforces the same.
    var maxAccuracyMeters: Double? = nil

    var id: String { slug }

    /// The accuracy limit that applies in this zone.
    func maxAccuracy(default globalLimit: Double) -> Double { maxAccuracyMeters ?? globalLimit }

    /// Whether this build may use the zone at all. Drafts are allowed only when the server (or a DEBUG build's
    /// bundled config) says so. The server re-checks this on every participation request.
    func isUsable(allowDrafts: Bool) -> Bool {
        enabled && (validationStatus == .fieldValidated || allowDrafts)
    }
}

extension SpaceZone: Decodable {
    private enum CodingKeys: String, CodingKey {
        case slug, name, subtitle, boundary
        case boundaryVersion = "boundary_version"
        case validationStatus = "validation_status"
        case enabled
        case sortOrder = "sort_order"
        case membershipRule = "membership_rule"
        case maxAccuracyMeters = "max_accuracy_m"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        name = try c.decode(String.self, forKey: .name)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        shape = try c.decode(GeoJSONShape.self, forKey: .boundary).shape
        boundaryVersion = try c.decode(Int.self, forKey: .boundaryVersion)
        validationStatus = try c.decode(ValidationStatus.self, forKey: .validationStatus)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        membershipRule = try c.decodeIfPresent(MembershipRule.self, forKey: .membershipRule) ?? .circle
        maxAccuracyMeters = try c.decodeIfPresent(Double.self, forKey: .maxAccuracyMeters)
        if let m = maxAccuracyMeters, !(5...100).contains(m) {
            throw DecodingError.dataCorruptedError(forKey: .maxAccuracyMeters, in: c, debugDescription: "max_accuracy_m out of range")
        }
    }
}

/// GeoJSON Polygon / MultiPolygon → ZoneShape (outer rings only; coordinates are [longitude, latitude]).
nonisolated struct GeoJSONShape: Decodable, Sendable {
    let shape: ZoneShape

    private enum CodingKeys: String, CodingKey { case type, coordinates }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let polygons: [[[[Double]]]]
        switch type {
        case "Polygon": polygons = [try c.decode([[[Double]]].self, forKey: .coordinates)]
        case "MultiPolygon": polygons = try c.decode([[[[Double]]]].self, forKey: .coordinates)
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unsupported geometry \(type)")
        }
        var rings: [[GeoPoint]] = []
        for polygon in polygons {
            guard let outer = polygon.first else { continue }
            let ring = try outer.map { pair -> GeoPoint in
                guard pair.count >= 2, (-180...180).contains(pair[0]), (-90...90).contains(pair[1]) else {
                    throw DecodingError.dataCorruptedError(forKey: .coordinates, in: c, debugDescription: "Bad coordinate")
                }
                return GeoPoint(latitude: pair[1], longitude: pair[0])
            }
            guard ring.count >= 4, ring.first == ring.last else {
                throw DecodingError.dataCorruptedError(forKey: .coordinates, in: c, debugDescription: "Ring must be closed with ≥ 4 points")
            }
            rings.append(ring)
        }
        guard !rings.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .coordinates, in: c, debugDescription: "No rings")
        }
        shape = ZoneShape(rings: rings)
    }
}

enum SpaceZoneCatalog {
    /// The zones shipped in the app bundle, used until the server list loads (or if it can't).
    static func bundled(in bundle: Bundle = .main) -> [SpaceZone] {
        guard let url = bundle.url(forResource: "campus_spaces", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? decode(data)) ?? []
    }

    static func decode(_ data: Data) throws -> [SpaceZone] {
        try JSONDecoder().decode([SpaceZone].self, from: data).sorted { ($0.sortOrder, $0.slug) < ($1.sortOrder, $1.slug) }
    }
}
