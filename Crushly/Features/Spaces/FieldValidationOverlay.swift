#if DEBUG
import SwiftUI

// Field-validation overlay (docs/CAMPUS_SPACES_DESIGN.md §8.3 step 3). DEBUG builds only.
//
// While it's on, every location sample is classified against ALL enabled zones (drafts included, whatever the
// server's allow_draft_spaces says) with the same geometry and thresholds as the MembershipEngine, and shown on screen.
// You tap what's actually true where you're standing ("Inside" / "Edge" / "Outside") to build a tally of
// ground truth vs verdict. Everything is held in memory only: never logged, persisted or sent, and cleared when the
// overlay is turned off.

@MainActor @Observable
final class FieldValidationRecorder {
    static let shared = FieldValidationRecorder()

    struct ZoneReading: Identifiable, Equatable {
        var slug: String
        var name: String
        var status: SpaceZone.ValidationStatus
        var relation: ZoneShape.Relation
        /// Metres to the boundary; positive inside, negative outside.
        var signedDistance: Double
        var id: String { slug }
    }

    struct Reading: Equatable {
        var coordinate: GeoPoint
        var accuracy: Double
        var timestamp: Date
        var stationary: Bool
        var verdict: MembershipEngine.Verdict
        var engineState: MembershipState
        var zones: [ZoneReading]
    }

    enum Truth: String, CaseIterable { case inside = "Inside", edge = "Edge", outside = "Outside" }

    struct Mark: Identifiable {
        let id = UUID()
        var truth: Truth
        var verdict: MembershipEngine.Verdict
        var accuracy: Double
        var nearestZone: String?
        var time: Date

        /// Inside verdict where you're actually outside: the case that would make someone visible where they aren't.
        var isFalseInside: Bool { truth == .outside && verdict.isInside }
        /// Outside verdict where you're actually inside: costs availability, not privacy.
        var isFalseOutside: Bool { truth == .inside && verdict == .outside }
    }

    var isOn = false {
        didSet { if !isOn { reading = nil; marks = [] } }
    }
    private(set) var reading: Reading?
    private(set) var marks: [Mark] = []

    func record(_ sample: LocationSample, zones: [SpaceZone], config: MembershipConfig, state: MembershipState) {
        guard isOn else { return }
        let enabled = zones.filter(\.enabled)
        let radius = max(0, sample.horizontalAccuracy) + config.safetyMargin
        let readings = enabled.map { zone -> ZoneReading in
            let relation = zone.shape.relation(of: sample.coordinate, radius: radius)
            let inside = zone.shape.relation(of: sample.coordinate, radius: 0) != .outside
            let distance = zone.shape.distanceToBoundary(from: sample.coordinate)
            return ZoneReading(slug: zone.slug, name: zone.name, status: zone.validationStatus,
                               relation: relation, signedDistance: inside ? distance : -distance)
        }
        .sorted { abs($0.signedDistance) < abs($1.signedDistance) }
        reading = Reading(coordinate: sample.coordinate, accuracy: sample.horizontalAccuracy,
                          timestamp: sample.timestamp, stationary: sample.stationary,
                          verdict: MembershipEngine(zones: enabled, config: config).classify(sample),
                          engineState: state, zones: readings)
    }

    func mark(_ truth: Truth) {
        guard let reading else { return }
        marks.append(Mark(truth: truth, verdict: reading.verdict, accuracy: reading.accuracy,
                          nearestZone: reading.zones.first?.name, time: Date()))
    }

    func undoLastMark() { _ = marks.popLast() }
}

extension MembershipEngine.Verdict {
    var isInside: Bool { if case .inside = self { true } else { false } }

    var label: String {
        switch self {
        case .inside(let slug, let depth): "INSIDE \(slug) (\(Int(depth)) m deep)"
        case .outside: "OUTSIDE"
        case .outsideLeaning: "OUTSIDE-LEANING"
        case .uncertain: "UNCERTAIN"
        }
    }

    var color: Color {
        switch self {
        case .inside: Theme.Palette.live
        case .outside: Theme.Palette.inkFaint
        case .outsideLeaning, .uncertain: Theme.Palette.orange
        }
    }
}

struct FieldValidationOverlay: View {
    @Environment(AppState.self) private var state
    @State private var expanded = true
    private var recorder: FieldValidationRecorder { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if expanded {
                if let r = recorder.reading { readingView(r) } else { waiting }
                markButtons
                tally
            }
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 8)
        .accessibilityIdentifier("fieldValidation.overlay")
    }

    private var header: some View {
        HStack {
            Text("FIELD VALIDATION").bold()
            Spacer()
            Button(expanded ? "Hide" : "Show") { expanded.toggle() }
            Button("Close") { recorder.isOn = false }
        }
        .buttonStyle(.borderless)
        .tint(.white)
    }

    private var waiting: some View {
        Text(state.locationRunning
             ? "Waiting for a location fix…"
             : "Location isn't running. Turn on campus matching (and allow precise location) to start.")
            .foregroundStyle(.white.opacity(0.8))
    }

    private func readingView(_ r: FieldValidationRecorder.Reading) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(r.verdict.label).bold().foregroundStyle(r.verdict.color)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let age = max(0, context.date.timeIntervalSince(r.timestamp))
                Text("±\(Int(r.accuracy.rounded())) m · fix \(Int(age)) s old\(r.stationary ? " · stationary" : "")")
                    .foregroundStyle(r.accuracy > state.engine.config.maxAccuracy || age > state.engine.config.maxEvidenceAge
                                     ? Theme.Palette.orange : .white)
            }
            Text(String(format: "%.6f, %.6f", r.coordinate.latitude, r.coordinate.longitude))
                .textSelection(.enabled)
            Text("engine: \(String(describing: r.engineState))").lineLimit(1).truncationMode(.middle)
            ForEach(r.zones.prefix(4)) { z in
                HStack(spacing: 4) {
                    Text(relationLabel(z.relation)).frame(width: 64, alignment: .leading)
                    Text("\(z.signedDistance >= 0 ? "+" : "")\(Int(z.signedDistance.rounded())) m")
                        .frame(width: 56, alignment: .trailing)
                    Text(z.name).lineLimit(1)
                    if z.status == .draft { Text("draft").foregroundStyle(Theme.Palette.orange) }
                }
            }
        }
    }

    private func relationLabel(_ relation: ZoneShape.Relation) -> String {
        switch relation {
        case .inside: "in"
        case .outside: "out"
        case .straddling(let centerInside): centerInside ? "edge(in)" : "edge(out)"
        }
    }

    private var markButtons: some View {
        HStack(spacing: 6) {
            Text("I'm:")
            ForEach(FieldValidationRecorder.Truth.allCases, id: \.self) { truth in
                Button(truth.rawValue) { recorder.mark(truth) }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .disabled(recorder.reading == nil)
            }
            Button("Undo") { recorder.undoLastMark() }
                .buttonStyle(.borderless)
                .tint(.white)
                .disabled(recorder.marks.isEmpty)
        }
    }

    @ViewBuilder private var tally: some View {
        let marks = recorder.marks
        if !marks.isEmpty {
            let falseInside = marks.filter(\.isFalseInside).count
            let falseOutside = marks.filter(\.isFalseOutside).count
            let accuracies = marks.map(\.accuracy).sorted()
            let median = accuracies[accuracies.count / 2]
            let over = marks.filter { $0.accuracy > state.engine.config.maxAccuracy }.count
            VStack(alignment: .leading, spacing: 2) {
                Text("\(marks.count) marks · median ±\(Int(median)) m · \(over) over \(Int(state.engine.config.maxAccuracy)) m")
                Text("false INSIDE: \(falseInside)  ·  false OUTSIDE: \(falseOutside)")
                    .foregroundStyle(falseInside > 0 ? Theme.Palette.crushSoft : .white)
                if let last = marks.last {
                    Text("last: \(last.truth.rawValue) → \(last.verdict.label)").lineLimit(1)
                }
            }
        }
    }
}

/// DEBUG-only switch in the Spaces tab.
struct FieldValidationToggle: View {
    var body: some View {
        @Bindable var recorder = FieldValidationRecorder.shared
        Toggle(isOn: $recorder.isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Field validation overlay").font(Theme.Typeface.headline).foregroundStyle(Theme.Palette.ink)
                Text("DEBUG only. Shows verdicts and accuracy on screen; nothing is logged or saved.")
                    .font(Theme.Typeface.caption).foregroundStyle(Theme.Palette.inkSoft)
            }
        }
        .tint(Theme.Palette.crush)
        .crushCard(padding: Theme.Space.m)
        .accessibilityIdentifier("fieldValidation.toggle")
    }
}
#endif
