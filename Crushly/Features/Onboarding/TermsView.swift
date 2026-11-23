import SwiftUI

/// Age declaration + Terms/Privacy acceptance. A declaration is not age verification, and is labelled as such.
struct TermsView: View {
    @Environment(AppState.self) private var state
    @State private var isAdult = false
    @State private var acceptsTerms = false
    @State private var acceptsPrivacy = false
    @State private var showing: LegalDoc?
    /// Documents read to the bottom; each acceptance stays locked until its document is in here.
    @State private var readToEnd: Set<LegalDoc> = []

    typealias LegalDoc = LegalDocuments.Kind

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                SectionHeader(eyebrow: "Before you start", title: "A few promises")

                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    promise("eye.slash.fill", "Interest stays private", "No one learns you were interested unless it's mutual.")
                    promise("location.slash.fill", "No exact location", "We show Campus Spaces, never your coordinates or direction.")
                    promise("shield.lefthalf.filled", "You're in control", "Pause, hide, block or report anytime.")
                }
                .crushCard()

                VStack(spacing: 0) {
                    check($isAdult, "I'm 18 or older", detail: "This is a declaration, not age verification.", id: "terms.age")
                    Divider().padding(.leading, 52)
                    check($acceptsTerms, "I accept the Terms of Service", link: .terms, id: "terms.tos")
                    Divider().padding(.leading, 52)
                    check($acceptsPrivacy, "I accept the Privacy Policy", link: .privacy, id: "terms.privacy")
                }
                .crushCard(padding: Theme.Space.s)

                AsyncButton {
                    await state.perform { try await state.acceptTerms() }
                } label: { Text("Continue") }
                    .buttonStyle(.crush)
                    .accessibilityIdentifier("terms.continue")
                    .disabled(!(isAdult && acceptsTerms && acceptsPrivacy))

                Button("Sign out") { Task { await state.signOut() } }
                    .buttonStyle(.crush(.quiet))
            }
            .padding(Theme.Space.gutter)
            .crushScrollPadding()
        }
        .scrollIndicators(.hidden)
        .sheet(item: $showing) { doc in
            LegalDocumentView(kind: doc) { readToEnd.insert(doc) }
        }
    }

    private func promise(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: icon).foregroundStyle(Theme.Palette.crush).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Typeface.headline)
                Text(detail).font(Theme.Typeface.subheadline).foregroundStyle(Theme.Palette.inkSoft)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func check(_ value: Binding<Bool>, _ title: String, detail: String? = nil, link: LegalDoc? = nil, id: String) -> some View {
        let locked = link.map { !readToEnd.contains($0) } ?? false
        return HStack(spacing: Theme.Space.m) {
            Button {
                value.wrappedValue.toggle()
                state.feedback.play(.tap)
            } label: {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: value.wrappedValue ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(value.wrappedValue ? Theme.Palette.crush : Theme.Palette.inkFaint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(Theme.Typeface.callout.weight(.semibold)).foregroundStyle(Theme.Palette.ink)
                        if let detail { Text(detail).font(Theme.Typeface.footnote).foregroundStyle(Theme.Palette.inkSoft) }
                        if locked, let link {
                            Text("Tap Read and scroll to the end of the \(link.rawValue) first.")
                                .font(Theme.Typeface.footnote).foregroundStyle(Theme.Palette.inkSoft)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Theme.minTap + 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(locked)
            .opacity(locked ? 0.4 : 1)
            .accessibilityAddTraits(value.wrappedValue ? .isSelected : [])
            .accessibilityIdentifier(id)
            if let link {
                Button("Read") { showing = link }
                    .font(Theme.Typeface.subheadline.weight(.bold))
                    .frame(minWidth: Theme.minTap, minHeight: Theme.minTap)
                    .accessibilityLabel("Read \(link.rawValue)")
            }
        }
        .padding(.horizontal, Theme.Space.s)
    }
}

struct LegalDocumentView: View {
    let kind: LegalDocuments.Kind
    /// Called once the reader has scrolled to the bottom of a loaded document.
    var onReadToEnd: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var reachedEnd = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if LegalDocuments.isPlaceholder {
                        Label("Draft — pending legal review. Not the final \(kind.rawValue).",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Typeface.callout.weight(.semibold))
                            .foregroundStyle(Theme.Palette.amberText)
                            .crushCard(fill: Theme.Palette.amberSoft)
                    }
                    Text("Version \(kind.version)").font(Theme.Typeface.footnote).foregroundStyle(Theme.Palette.inkSoft)
                    if let text = LegalDocuments.text(kind) {
                        MarkdownBlocks(text: text)
                    } else {
                        Text("This document couldn't be loaded.").font(Theme.Typeface.body)
                    }
                }
                .padding(Theme.Space.gutter)
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                // True when the bottom edge of the content is on screen (also true if the document fits without scrolling).
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 24
            } action: { _, atBottom in
                guard atBottom, !reachedEnd, LegalDocuments.text(kind) != nil else { return }
                reachedEnd = true
                onReadToEnd?()
            }
            .accessibilityIdentifier("legal.scroll")
            .navigationTitle(kind.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Minimal block renderer for the bundled legal Markdown: headings, bullets, simple tables, paragraphs.
/// Inline styling (bold, links) goes through AttributedString's Markdown parser.
private struct MarkdownBlocks: View {
    let text: String

    private enum Block: Hashable {
        case h1(String), h2(String), bullet(String), row([String]), paragraph(String)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        func flush() { if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] } }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("# ") { flush(); out.append(.h1(String(line.dropFirst(2)))) }
            else if line.hasPrefix("## ") { flush(); out.append(.h2(String(line.dropFirst(3)))) }
            else if line.hasPrefix("- ") { flush(); out.append(.bullet(String(line.dropFirst(2)))) }
            else if line.hasPrefix("|") {
                flush()
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } }) {
                    if case .row = out.last { out.removeLast() }   // drop the header row above the separator
                } else {
                    out.append(.row(cells))
                }
            } else { paragraph.append(line) }
        }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .h1(let s):
                    Text(inline(s)).font(Theme.Typeface.title2).foregroundStyle(Theme.Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                case .h2(let s):
                    Text(inline(s)).font(Theme.Typeface.headline).foregroundStyle(Theme.Palette.ink)
                        .padding(.top, Theme.Space.m)
                        .accessibilityAddTraits(.isHeader)
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Text("•").accessibilityHidden(true)
                        Text(inline(s))
                    }
                    .font(Theme.Typeface.body)
                case .row(let cells):
                    VStack(alignment: .leading, spacing: 2) {
                        Text(inline(cells.first ?? "")).font(Theme.Typeface.subheadline.weight(.semibold))
                        if cells.count > 1 { Text(inline(cells.dropFirst().joined(separator: " · "))).font(Theme.Typeface.subheadline) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                case .paragraph(let s):
                    Text(inline(s)).font(Theme.Typeface.body)
                }
            }
        }
        .foregroundStyle(Theme.Palette.ink)
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
