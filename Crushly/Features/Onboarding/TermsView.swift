import SwiftUI

/// Age declaration + Terms/Privacy acceptance. A declaration is not age verification, and is labelled as such.
struct TermsView: View {
    @Environment(AppState.self) private var state
    @State private var isAdult = false
    @State private var acceptsTerms = false
    @State private var acceptsPrivacy = false
    @State private var showing: LegalDoc?

    enum LegalDoc: String, Identifiable { case terms = "Terms of Service", privacy = "Privacy Policy"; var id: String { rawValue } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                SectionHeader(eyebrow: "Before you start", title: "A few promises")

                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    promise("eye.slash.fill", "Interest stays anonymous", "No one sees who signalled them unless it's mutual.")
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
        }
        .sheet(item: $showing) { doc in LegalDocumentView(title: doc.rawValue) }
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
        HStack(spacing: Theme.Space.m) {
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
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Theme.minTap + 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if LegalDocuments.isPlaceholder {
                        Label("Development placeholder — not the real \(title). Final legal text is a release dependency.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Typeface.callout.weight(.semibold))
                            .foregroundStyle(Theme.Palette.amber)
                            .crushCard(fill: Theme.Palette.amberSoft)
                    }
                    Text("Version \(LegalDocuments.termsVersion)").font(Theme.Typeface.footnote).foregroundStyle(Theme.Palette.inkSoft)
                    Text("""
                    This placeholder outlines the topics the final document must cover: eligibility (USC students, 18+), \
                    acceptable use, anonymous interest and mutual matching, Campus Space visibility, data collected and \
                    retained, moderation and reporting, account deletion, and contact information.
                    """)
                    .font(Theme.Typeface.body)
                }
                .padding(Theme.Space.gutter)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
