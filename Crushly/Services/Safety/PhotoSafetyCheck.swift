import CoreML
import Foundation
import Vision

/// On-device check for nudity and explicit content, run on every profile photo before it is uploaded. The photo
/// never leaves the phone for this; no outside service or API key is involved.
///
/// Model: `Resources/Models/NSFW.mlmodel` from NSFWDetector (BSD-3-Clause, see NSFW-LICENSE.txt). It is a small
/// classifier on top of Apple's built-in Vision image features and returns a 0–1 "NSFW" confidence.
///
/// Limits, stated plainly: this runs in the app, so a tampered client could skip it, and no classifier is perfect.
/// Reports and moderators (docs/MODERATION.md) stay the backstop. The Simulator can't run the model at all, so
/// Simulator builds skip the check (see `evaluate`).
nonisolated enum PhotoSafetyCheck {
    enum Verdict: Equatable, Sendable { case allowed, explicit }

    /// Confidence at or above which a photo is refused. Lower = stricter (more false positives, e.g. swimwear).
    static let blockThreshold: Float = 0.85

    private nonisolated(unsafe) static let model: VNCoreMLModel? = {
        guard let url = Bundle.main.url(forResource: "NSFW", withExtension: "mlmodelc") else { return nil }
        let configuration = MLModelConfiguration()
        guard let model = try? MLModel(contentsOf: url, configuration: configuration) else { return nil }
        return try? VNCoreMLModel(for: model)
    }()

    /// Whether the bundled model loaded (it always should; tests check it).
    static var isModelAvailable: Bool { model != nil }

    /// On a device, throws when the image can't be analysed, and callers refuse the photo (fail closed).
    static func evaluate(_ imageData: Data) async throws -> Verdict {
        do {
            let confidence = try await Task.detached(priority: .userInitiated) { try score(imageData) }.value
            return confidence >= blockThreshold ? .explicit : .allowed
        } catch {
            #if targetEnvironment(simulator)
            // The model is built on Vision's feature print, which can't create an inference context in the Simulator
            // ("Could not create inference context"). Let photos through there so development and the demo work;
            // device builds never take this path.
            return .allowed
            #else
            throw error
            #endif
        }
    }

    /// The model's NSFW confidence for an encoded image (0 = safe, 1 = explicit).
    static func score(_ imageData: Data) throws -> Float {
        guard let model else { throw CrushlyError.photoCheckUnavailable }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .centerCrop
        try VNImageRequestHandler(data: imageData, options: [:]).perform([request])
        guard let observation = (request.results as? [VNClassificationObservation])?.first(where: { $0.identifier == "NSFW" }) else {
            throw CrushlyError.photoCheckUnavailable
        }
        return observation.confidence
    }
}
