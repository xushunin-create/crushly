import PhotosUI
import SwiftUI

struct ProfileEditorView: View {
    enum Mode { case onboarding, edit }
    let mode: Mode

    /// Onboarding walks through these one at a time; editing shows them all on one screen.
    enum Step: Int, CaseIterable {
        case basics, photos, about, lookingFor

        var title: String {
            switch self {
            case .basics: "The basics"
            case .photos: "Add your photos"
            case .about: "Show some personality"
            case .lookingFor: "Who you'd like to meet"
            }
        }
        var subtitle: String {
            switch self {
            case .basics: "Your first name and age are on your profile. Your gender helps us match you with the right people."
            case .photos: "At least one. They go live right away. Each photo is checked on your phone first, and explicit images are blocked."
            case .about: "Three interests and one prompt answer give people something to talk about."
            case .lookingFor: "Your preferences are private. Both people have to fit each other's to match."
            }
        }
    }

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Profile?
    @State private var preferences = MatchPreferences()
    @State private var showGender = true
    @State private var step: Step = .basics
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var uploading = 0
    @State private var customInterest = ""
    @State private var showMissing = false

    var body: some View {
        Group {
            if let binding = Binding($draft) {
                form(binding)
            } else {
                ProgressView()
            }
        }
        .background(Theme.Palette.paper)
        .navigationTitle(mode == .onboarding ? "Create your profile" : "Edit profile")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(mode == .onboarding)
        .toolbar {
            if mode == .onboarding {
                ToolbarItem(placement: .topBarLeading) {
                    if step == .basics {
                        Button("Sign out") { Task { await state.signOut() } }
                    } else {
                        Button { go(to: Step(rawValue: step.rawValue - 1) ?? .basics) } label: {
                            Label("Back", systemImage: "chevron.left").labelStyle(.titleAndIcon)
                        }
                        .accessibilityIdentifier("profile.back")
                    }
                }
            }
        }
        .onAppear {
            guard draft == nil else { return }
            let profile = state.profile ?? Profile(id: state.userID ?? UUID())
            draft = profile
            preferences = state.preferences
            showGender = state.profile.map { !$0.gender.isEmpty } ?? true
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task { await upload(items) }
        }
    }

    private func form(_ draft: Binding<Profile>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                if mode == .onboarding {
                    stepHeader
                    sections(for: step, draft)
                } else {
                    ForEach(Step.allCases, id: \.self) { section in
                        sections(for: section, draft)
                    }
                }

                let missing = mode == .onboarding ? missingFields(for: step, draft.wrappedValue) : allMissing(draft.wrappedValue)
                if showMissing, !missing.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Still needed").font(Theme.Typeface.headline)
                        ForEach(missing, id: \.self) { Text("• \($0)") }
                    }
                    .font(Theme.Typeface.callout)
                    .foregroundStyle(Theme.Palette.danger)
                    .crushCard(fill: Theme.Palette.crushSoft)
                    .accessibilityElement(children: .combine)
                }

                if mode == .onboarding, step != .lookingFor {
                    Button { advance(draft.wrappedValue) } label: { Text("Continue") }
                        .buttonStyle(.crush)
                        .disabled(uploading > 0)
                        .accessibilityIdentifier("profile.next")
                } else {
                    AsyncButton { await save(draft.wrappedValue) } label: {
                        Text(mode == .onboarding ? "Create my profile" : "Save changes")
                    }
                    .buttonStyle(.crush)
                    .disabled(uploading > 0)
                    .accessibilityIdentifier("profile.save")
                }
            }
            .padding(Theme.Space.gutter)
            .crushScrollPadding()
        }
        .id(mode == .onboarding ? step.rawValue : 0)   // each step starts at the top
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .accessibilityIdentifier("keyboard.done")
            }
        }
    }

    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? Theme.Palette.crush : Theme.Palette.ink.opacity(0.12))
                        .frame(height: 5)
                }
            }
            .accessibilityHidden(true)
            Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                .font(Theme.Typeface.eyebrow)
                .foregroundStyle(Theme.Palette.crushText)
                .padding(.top, Theme.Space.xs)
            Text(step.title)
                .font(Theme.Typeface.title)
                .foregroundStyle(Theme.Palette.oxblood)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("profile.stepTitle")
            Text(step.subtitle)
                .font(Theme.Typeface.callout).foregroundStyle(Theme.Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func sections(for step: Step, _ draft: Binding<Profile>) -> some View {
        switch step {
        case .basics:
            basics(draft).editorSection()
        case .photos:
            photos(draft).editorSection()
        case .about:
            interests(draft).editorSection()
            prompt(draft).editorSection()
            vibes(draft).editorSection()
        case .lookingFor:
            intentions(draft).editorSection()
            matchingPreferences.editorSection()
        }
    }

    // MARK: Steps

    private func missingFields(for step: Step, _ profile: Profile) -> [String] {
        switch step {
        case .basics:
            var missing = profile.missingFields.filter { $0 == "First name" || $0 == "Age (18+)" }
            if preferences.matchGender == nil { missing.append("Gender") }
            return missing
        case .photos:
            return profile.photoPaths.isEmpty ? ["At least one photo"] : []
        case .about:
            return profile.missingFields.filter { $0.hasPrefix("Exactly") || $0 == "Prompt answer" }
        case .lookingFor:
            return preferences.showMe.isEmpty ? ["Show me"] : []
        }
    }

    private func allMissing(_ profile: Profile) -> [String] {
        Step.allCases.flatMap { missingFields(for: $0, profile) }
    }

    private func advance(_ profile: Profile) {
        guard missingFields(for: step, profile).isEmpty else {
            showMissing = true
            state.feedback.play(.warning)
            return
        }
        state.feedback.play(.tap)
        go(to: Step(rawValue: step.rawValue + 1) ?? .lookingFor)
    }

    private func go(to next: Step) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        showMissing = false
        withAnimation(Theme.Motion.soft) { step = next }
    }

    // MARK: Sections

    private func photos(_ draft: Binding<Profile>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Eyebrow(text: "Photos")
                Spacer()
                ReviewStatusPill(status: draft.wrappedValue.photoReviewStatus, hasPhotos: !draft.wrappedValue.photoPaths.isEmpty)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.m) {
                    ForEach(draft.wrappedValue.photoPaths, id: \.self) { path in
                        Avatar(path: path, name: draft.wrappedValue.firstName, size: 104, shape: .rounded)
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    draft.wrappedValue.photoPaths.removeAll { $0 == path }
                                    Task { try? await state.backend.deletePhoto(path: path) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title3)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, Theme.Palette.ink)
                                        .frame(width: Theme.minTap, height: Theme.minTap)
                                }
                                .accessibilityLabel("Remove photo")
                            }
                    }
                    ForEach(0..<uploading, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 22).fill(Theme.Palette.surface)
                            .frame(width: 104, height: 104)
                            .overlay {
                                VStack(spacing: 6) {
                                    ProgressView()
                                    Text("Checking…").font(Theme.Typeface.caption).foregroundStyle(Theme.Palette.inkSoft)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Uploading and checking photo")
                    }
                    if draft.wrappedValue.photoPaths.count + uploading < ProfileRules.maxPhotos {
                        PhotosPicker(selection: $pickerItems,
                                     maxSelectionCount: ProfileRules.maxPhotos - draft.wrappedValue.photoPaths.count - uploading,
                                     matching: .images) {
                            RoundedRectangle(cornerRadius: 22)
                                .strokeBorder(Theme.Palette.crush, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                                .frame(width: 104, height: 104)
                                .overlay(Image(systemName: "plus").font(.title2.bold()).foregroundStyle(Theme.Palette.crush))
                        }
                        .accessibilityLabel("Add photos")
                    }
                }
            }
            if state.config.isDemo, draft.wrappedValue.photoPaths.count < ProfileRules.maxPhotos {
                Button { Task { await uploadSample() } } label: {
                    Label("Use a sample photo (demo)", systemImage: "testtube.2")
                }
                .font(Theme.Typeface.subheadline.weight(.semibold))
                .frame(minHeight: Theme.minTap)
                .accessibilityIdentifier("profile.samplePhoto")
            }
            Label("Photos go live as soon as you save. Each one is checked on your phone first, and nudity or explicit images are blocked.",
                  systemImage: "checkmark.shield")
                .font(Theme.Typeface.footnote).foregroundStyle(Theme.Palette.inkSoft)
        }
    }

    private func basics(_ draft: Binding<Profile>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Eyebrow(text: "Basics")
            field("First name", text: draft.firstName)
                .textContentType(.givenName)
                .accessibilityIdentifier("profile.firstName")
            Stepper(value: draft.age, in: 18...99) {
                HStack {
                    Text("Age").font(Theme.Typeface.callout.weight(.semibold))
                    Spacer()
                    Text("\(draft.wrappedValue.age)").font(Theme.Typeface.headline)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(minHeight: 54)
            .background(Theme.Palette.field, in: RoundedRectangle(cornerRadius: Theme.Radius.s))

            // The one place to set gender: it drives matching (private) and, if shown, the profile label.
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Gender").font(Theme.Typeface.callout.weight(.semibold))
                FlowLayout(spacing: 8) {
                    ForEach(MatchGender.allCases) { option in
                        SelectableChip(title: option.title, selected: preferences.matchGender == option) {
                            preferences.matchGender = option
                        }
                        .accessibilityIdentifier("prefs.matchAs.\(option.rawValue)")
                    }
                }
                Toggle(isOn: $showGender) {
                    Text("Show on my profile").font(Theme.Typeface.callout)
                }
                .tint(Theme.Palette.crush)
                .frame(minHeight: Theme.minTap)
                .accessibilityIdentifier("profile.showGender")
                Text(showGender
                     ? "People can see it on your profile. It's also used so you only appear to people looking for you."
                     : "Kept private. It's only used so you appear to people looking for you.")
                    .font(Theme.Typeface.footnote).foregroundStyle(Theme.Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            choiceRow("Pronouns (optional)", options: ["she/her", "he/him", "they/them", "she/they", "he/they"], selection: draft.pronouns)
        }
    }

    private func interests(_ draft: Binding<Profile>) -> some View {
        let picked = draft.wrappedValue.interests
        let options = Array(Set(ProfileRules.interestSuggestions + picked)).sorted()
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Eyebrow(text: "Three interests")
                Spacer()
                Text("\(picked.count)/\(ProfileRules.interestCount)")
                    .font(Theme.Typeface.caption.weight(.bold))
                    .foregroundStyle(picked.count == ProfileRules.interestCount ? Theme.Palette.mint : Theme.Palette.inkSoft)
            }
            FlowLayout(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    SelectableChip(title: option, selected: picked.contains(option)) {
                        if picked.contains(option) {
                            draft.wrappedValue.interests.removeAll { $0 == option }
                        } else if picked.count < ProfileRules.interestCount {
                            draft.wrappedValue.interests.append(option)
                        } else {
                            state.feedback.play(.warning)
                        }
                    }
                }
            }
            HStack {
                field("Add your own", text: $customInterest)
                Button("Add") {
                    let value = customInterest.trimmingCharacters(in: .whitespaces)
                    guard !value.isEmpty, picked.count < ProfileRules.interestCount, !picked.contains(value) else { return }
                    draft.wrappedValue.interests.append(String(value.prefix(24)))
                    customInterest = ""
                }
                .buttonStyle(.crush(.quiet))
                .frame(width: 90)
            }
        }
    }

    private func vibes(_ draft: Binding<Profile>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Eyebrow(text: "Vibe tags · up to \(ProfileRules.maxVibeTags)")
            FlowLayout(spacing: 8) {
                ForEach(ProfileRules.vibeSuggestions, id: \.self) { option in
                    let selected = draft.wrappedValue.vibeTags.contains(option)
                    SelectableChip(title: option, selected: selected, tint: Theme.Palette.plum) {
                        if selected {
                            draft.wrappedValue.vibeTags.removeAll { $0 == option }
                        } else if draft.wrappedValue.vibeTags.count < ProfileRules.maxVibeTags {
                            draft.wrappedValue.vibeTags.append(option)
                        }
                    }
                }
            }
        }
    }

    private func prompt(_ draft: Binding<Profile>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Eyebrow(text: "Prompt")
            Menu {
                Picker("Prompt", selection: draft.promptQuestion) {
                    ForEach(ProfilePrompts.all, id: \.self) { Text($0).tag($0) }
                }
            } label: {
                HStack {
                    Text(draft.wrappedValue.promptQuestion).font(Theme.Typeface.headline).foregroundStyle(Theme.Palette.ink)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").foregroundStyle(Theme.Palette.inkSoft)
                }
                .frame(minHeight: Theme.minTap)
            }
            TextField("Your answer", text: draft.promptAnswer, axis: .vertical)
                .accessibilityIdentifier("profile.promptAnswer")
                .lineLimit(2...4)
                .font(Theme.Typeface.body)
                .padding(Theme.Space.l)
                .background(Theme.Palette.field, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                .onChange(of: draft.wrappedValue.promptAnswer) { _, new in
                    if new.count > ProfileRules.promptMaxLength {
                        draft.wrappedValue.promptAnswer = String(new.prefix(ProfileRules.promptMaxLength))
                    }
                }
            Text("\(draft.wrappedValue.promptAnswer.count)/\(ProfileRules.promptMaxLength)")
                .font(Theme.Typeface.caption).foregroundStyle(Theme.Palette.inkSoft)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func intentions(_ draft: Binding<Profile>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Eyebrow(text: "Looking for")
            FlowLayout(spacing: 8) {
                ForEach(Intention.allCases) { option in
                    SelectableChip(title: option.title, selected: draft.wrappedValue.intention == option) {
                        draft.wrappedValue.intention = option
                    }
                }
            }
            Eyebrow(text: "Pace")
            AvailabilityPicker(selection: draft.availability)
        }
    }

    /// Private. Enforced in both directions on the server; never shown to anyone.
    private var matchingPreferences: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Eyebrow(text: "Show me · private")
            FlowLayout(spacing: 8) {
                ForEach(MatchGender.allCases) { option in
                    SelectableChip(title: option.plural, selected: preferences.showMe.contains(option)) {
                        if preferences.showMe.contains(option) { preferences.showMe.remove(option) } else { preferences.showMe.insert(option) }
                    }
                    .accessibilityIdentifier("prefs.showMe.\(option.rawValue)")
                }
                SelectableChip(title: "Everyone", selected: preferences.showMe == Set(MatchGender.allCases)) {
                    preferences.showMe = Set(MatchGender.allCases)
                }
                .accessibilityIdentifier("prefs.showMe.everyone")
            }
            ageStepper("Youngest", value: Binding(
                get: { preferences.ageMin },
                set: { preferences.ageMin = $0; preferences.ageMax = max(preferences.ageMax, $0) }),
                range: MatchPreferences.ageFloor...MatchPreferences.ageCeilingShown)
            ageStepper("Oldest", value: Binding(
                get: { min(preferences.ageMax, MatchPreferences.ageCeilingShown) },
                set: { preferences.ageMax = $0 >= MatchPreferences.ageCeilingShown ? MatchPreferences.ageCeilingStored : $0
                       preferences.ageMin = min(preferences.ageMin, $0) }),
                range: MatchPreferences.ageFloor...MatchPreferences.ageCeilingShown, plusAtTop: true)
            Label("Both people have to fit each other's preferences to match.", systemImage: "lock.fill")
                .font(Theme.Typeface.footnote).foregroundStyle(Theme.Palette.inkSoft)
        }
    }

    private func ageStepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, plusAtTop: Bool = false) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(title).font(Theme.Typeface.callout.weight(.semibold))
                Spacer()
                Text(plusAtTop && value.wrappedValue >= range.upperBound ? "\(range.upperBound)+" : "\(value.wrappedValue)")
                    .font(Theme.Typeface.headline)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(minHeight: 54)
        .background(Theme.Palette.field, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
    }

    // MARK: Helpers

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .font(Theme.Typeface.body)
            .padding(.horizontal, Theme.Space.l)
            .frame(minHeight: 54)
            .background(Theme.Palette.field, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s).stroke(Theme.Palette.hairline))
    }

    private func choiceRow(_ title: String, options: [String], selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).font(Theme.Typeface.callout.weight(.semibold))
            FlowLayout(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    SelectableChip(title: option, selected: selection.wrappedValue == option) {
                        selection.wrappedValue = selection.wrappedValue == option ? "" : option
                    }
                }
            }
            if !selection.wrappedValue.isEmpty, !options.contains(selection.wrappedValue) {
                Tag(text: selection.wrappedValue)
            }
            field("Or type your own", text: selection)
        }
    }

    private func upload(_ items: [PhotosPickerItem]) async {
        for item in items {
            uploading += 1
            defer { uploading -= 1 }
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let jpeg = ImageProcessing.jpeg(from: data) else {
                    throw CrushlyError.invalidInput("That photo couldn't be read. Try another one.")
                }
                let path = try await state.uploadPhoto(jpeg)
                draft?.photoPaths.append(path)
            } catch {
                state.handle(error)
            }
        }
    }

    /// Demo-only: uploads a generated image so the flow can be exercised without the system photo picker.
    private func uploadSample() async {
        let size = CGSize(width: 600, height: 600)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(Theme.Palette.crush).cgColor, UIColor(Theme.Palette.plum).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 600, y: 600), options: [])
            }
            let symbol = UIImage(systemName: "heart.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal)
            symbol?.draw(in: CGRect(x: 200, y: 210, width: 200, height: 180))
        }
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        uploading += 1
        defer { uploading -= 1 }
        do {
            let path = try await state.uploadPhoto(data)
            draft?.photoPaths.append(path)
        } catch {
            state.handle(error)
        }
    }

    private func save(_ profile: Profile) async {
        showMissing = true
        var profile = profile
        profile.gender = showGender ? (preferences.matchGender?.title ?? "") : ""
        guard profile.isComplete, preferences.isComplete else {
            state.feedback.play(.warning)
            // Onboarding: send the person back to the first step that still needs something.
            if mode == .onboarding, let first = Step.allCases.first(where: { !missingFields(for: $0, profile).isEmpty }) {
                go(to: first)
                showMissing = true
            }
            return
        }
        let ok = await state.perform {
            try await state.saveProfile(profile, preferences: preferences)
        }
        if ok {
            state.feedback.play(.success)
            if mode == .edit { dismiss() }
        }
    }
}

struct SelectableChip: View {
    let title: String
    let selected: Bool
    var tint: Color = Theme.Palette.crush
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if selected { Image(systemName: "checkmark").font(.caption.bold()) }
                Text(title)
            }
            .font(Theme.Typeface.subheadline.weight(.semibold))
            .foregroundStyle(selected ? .white : Theme.Palette.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(selected ? tint : Theme.Palette.surface, in: Capsule())
            .overlay(Capsule().stroke(selected ? .clear : Theme.Palette.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct AvailabilityPicker: View {
    @Binding var selection: Availability

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ForEach(Availability.allCases) { option in
                let selected = selection == option
                Button { selection = option } label: {
                    VStack(spacing: 6) {
                        Image(systemName: option.symbol).font(.title3)
                        Text(option.title).font(Theme.Typeface.caption.weight(.bold)).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .foregroundStyle(selected ? .white : Theme.Palette.ink)
                    .background(selected ? Theme.Palette.ink : Theme.Palette.surface,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s).stroke(Theme.Palette.hairline))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

struct ReviewStatusPill: View {
    let status: ReviewStatus
    var hasPhotos = true

    var body: some View {
        if !hasPhotos {
            StatusPill(text: "No photos yet", systemImage: "photo", tint: Theme.Palette.inkSoft, fill: Theme.Palette.ink.opacity(0.06))
        } else {
            // Photos are live as soon as they pass the automatic check; only a moderator can take them down.
            switch status {
            case .pending, .approved:
                StatusPill(text: "Live", systemImage: "checkmark.circle.fill", tint: Theme.Palette.mint, fill: Theme.Palette.mintSoft)
            case .rejected:
                StatusPill(text: "Removed by a moderator", systemImage: "xmark.octagon.fill", tint: Theme.Palette.danger, fill: Theme.Palette.crushSoft)
            }
        }
    }
}

enum ImageProcessing {
    /// Downscales to ≤1600 px on the long edge and re-encodes as JPEG (also strips EXIF/location metadata).
    static func jpeg(from data: Data, maxDimension: CGFloat = 1600) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.82)
    }
}
