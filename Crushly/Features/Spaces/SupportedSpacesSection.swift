import SwiftUI

/// The static list of supported spaces. No counts, no activity and no way to check in remotely: you can only take part
/// by actually being there.
struct SupportedSpacesSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Eyebrow(text: "Supported spaces")
            if state.zones.isEmpty {
                Text("No campus spaces are available for matching yet.")
                    .font(Theme.Typeface.callout)
                    .foregroundStyle(Theme.Palette.inkSoft)
            }
            ForEach(state.zones) { zone in
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Image(systemName: "building.columns")
                        .foregroundStyle(Theme.Palette.crush)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(zone.name).font(Theme.Typeface.headline).foregroundStyle(Theme.Palette.ink)
                        if let subtitle = zone.subtitle {
                            Text(subtitle).font(Theme.Typeface.subheadline).foregroundStyle(Theme.Palette.inkSoft)
                        }
                        if zone.validationStatus == .draft {
                            Text("Draft boundary (dev/staging only)")
                                .font(Theme.Typeface.caption.weight(.bold))
                                .foregroundStyle(Theme.Palette.amberText)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .crushCard(padding: Theme.Space.m)
                .accessibilityElement(children: .combine)
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                NavigationLink { HowMatchingWorksView() } label: {
                    Label("How matching works", systemImage: "questionmark.circle")
                        .font(Theme.Typeface.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.Palette.crushText)
                        .frame(minHeight: Theme.minTap)
                }
                .accessibilityIdentifier("spaces.howItWorks")
                Text("Space outlines © OpenStreetMap contributors (ODbL).")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.Palette.inkSoft)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .crushCard(padding: Theme.Space.m)   // solid backing: never over the decorative background
        }
    }
}

/// Plain-language explainer. Honest about what others can infer and what Crushly can't promise.
struct HowMatchingWorksView: View {
    var body: some View {
        List {
            Section("Your location") {
                point("location.fill", "Checked on your iPhone",
                      "While the app is open and campus matching is on, your iPhone checks whether you're inside a supported campus space. Your coordinates stay on your phone.")
                point("eye.slash.fill", "Invisible by default",
                      "Being in a space never makes you visible. You choose \"Open to matching\" each visit, and only for that visit.")
                point("timer", "A 60-second lease",
                      "While you're open to matching, Crushly's server only knows which space you chose, renewed about every 20 seconds. If your phone can't confirm you're still there, you become invisible within a minute. When you leave, it ends right away.")
                point("location.circle", "In the background",
                      "If you leave the app while open to matching, iOS shows the location indicator while renewals continue. Go invisible any time to stop.")
            }
            Section("What others can tell") {
                point("person.2.fill", "Only people matching in the same space",
                      "Other people never see your location, distance, arrival or departure, whether you're online, or how many people are here.")
                point("info.circle.fill", "Inference is possible",
                      "If someone sees your profile while matching, or matches with you, they can infer you were in the same campus space at the same time. A quiet space can also hint at who is or isn't around.")
                point("heart.fill", "Interest stays private",
                      "No one learns you were interested unless they're interested too. Interests disappear when either of you leaves.")
            }
            Section("Messages") {
                point("lock.fill", "Protected, not end-to-end encrypted",
                      "Messages are encrypted in transit and at rest, and only the two of you can load them through the app. They are not end-to-end encrypted: Crushly's operators can technically read them.")
                point("trash.fill", "Leaving deletes for both",
                      "Leave & delete ends the match and removes the conversation for both of you. It can't remove screenshots or copies on a device that's offline, and deleted data can remain in backups until they age out.")
            }
            Section("Limits") {
                point("exclamationmark.triangle.fill", "Location can be faked",
                      "Phones report their own location, so someone using spoofing tools could claim to be in a space. Report anything that feels off.")
                point("building.columns.fill", "Not affiliated with USC",
                      "Crushly is an independent app for USC students and isn't endorsed by the University of Southern California.")
            }
        }
        .foregroundStyle(Theme.Palette.ink, Theme.Palette.inkSoft)
        .navigationTitle("How matching works")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private func point(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: icon).foregroundStyle(Theme.Palette.crush).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Typeface.headline)
                Text(detail).font(Theme.Typeface.subheadline).foregroundStyle(Theme.Palette.inkSoft)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
