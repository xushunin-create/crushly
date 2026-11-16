import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Crushly

/// Guards from docs/CAMPUS_SPACES_DESIGN.md §1 and §7.5.
@MainActor
struct PrivacyGuardTests {
    /// The app sources, located from this file (tests run on the simulator, which can read the host filesystem).
    private static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Crushly")

    private func swiftFiles(in relative: String) -> [URL] {
        let dir = Self.appSources.appendingPathComponent(relative)
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test func noLoggingWhereCoordinatesMessagesOrTokensFlow() throws {
        let files = swiftFiles(in: "Location") + swiftFiles(in: "Services/Chat") + swiftFiles(in: "Services/Live")
            + swiftFiles(in: "Services/Demo") + [Self.appSources.appendingPathComponent("App/AppState.swift")]
        #expect(files.count >= 8, "found the sources")
        let banned = ["print(", "NSLog(", "os_log(", "Logger(", "debugPrint(", "dump("]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in banned {
                #expect(!text.contains(word), "\(file.lastPathComponent) must not call \(word)")
            }
        }
    }

    @Test func analyticsHasNoPresenceInterestOrMessageEvents() {
        let names = AnalyticsEvent.allCases.map(\.rawValue)
        for word in ["space", "location", "participat", "interest", "match_", "message", "candidate"] {
            #expect(!names.contains { $0.contains(word) }, "no '\(word)' analytics events")
        }
    }

    @Test func evidenceCarriesNoCoordinates() throws {
        let evidence = LocationEvidence(fixTimestamp: Date(), fixAge: 1.5, horizontalAccuracy: 9, stationary: false)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EvidenceDTO(evidence))) as? [String: Any]
        #expect(Set((json ?? [:]).keys) == ["fix_ts_ms", "fix_age_ms", "horizontal_accuracy_m", "stationary"])
    }

    @Test func photoProcessingStripsLocationMetadata() throws {
        // A JPEG carrying GPS coordinates, like a photo straight from the camera roll.
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 34.0205, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 118.2856, kCGImagePropertyGPSLongitudeRef: "W"]
        CGImageDestinationAddImage(destination, try #require(image.cgImage), [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        func properties(_ d: Data) -> [CFString: Any] {
            guard let source = CGImageSourceCreateWithData(d as CFData, nil) else { return [:] }
            return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        }
        #expect(properties(data as Data)[kCGImagePropertyGPSDictionary] != nil, "the input really has GPS data")

        let processed = try #require(ImageProcessing.jpeg(from: data as Data))
        #expect(properties(processed)[kCGImagePropertyGPSDictionary] == nil, "uploads carry no location")
    }
}
