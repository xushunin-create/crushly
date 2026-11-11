import PhotosUI
import SwiftUI

struct ProfileEditorView: View {
    enum Mode { case onboarding, edit }
    let mode: Mode

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Profile?
    @State private var instagram = ""
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
        .navigationTitle(mode == .onboarding ? "Your profile" : "Edit profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if mode == .onboarding {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sign out") { Task { await state.signOut() } }
                }
            }
        }
        .onAppear {
            guard draft == nil else { return }
            draft = state.profile ?? Profile(id: state.userID ?? UUID())
            instagram = state.account.instagramHandle
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
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text("Make a first impression.").font(Theme.Typeface.title)
                        Text("Only people active in the same Campus Space can see it.")
                            .font(Theme.Typeface.callout).foregroundStyle(Theme.Palette.inkSoft)
                    }
                }

                photos(draft)
                basics(draft)
                interests(draft)
                vibes(draft)
                prompt(draft)
                intentions(draft)
                instagramSection

                if showMissing, !draft.wrappedValue.missingFields.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Still needed").font(Theme.Typeface.headline)
                        ForEach(draft.wrappedValue.missingFields, id: \.self) { Text("• \($0)") }
                    }
                    .font(Theme.Typeface.callout)
                    .foregroundStyle(Theme.Palette.danger)
                    .crushCard(fill: Theme.Palette.crushSoft)
                }

                AsyncButton { await save(draft.wrappedValue) } label: {
                    Text(mode == .onboarding ? "Create my profile" : "Save changes")
                }
                .buttonStyle(.crush)
                .disabled(uploading > 0)
            }
            .padding(Theme.Space.gutter)
            .padding(.bottom, Theme.Space.xxl)
        }
        .scrollDismissesKeyboard(.interactively)
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
                            .overlay(ProgressView())
                    }
                    if draft.wrappedValue.photoPaths.count + uploading < ProfileRules.maxPhotos {
                        PhotosPicker(selection: $pickerItems,
                                     maxSelectionCount: ProfileRules.maxPhotos - draft.wrappedValue.photoPaths.count,
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
            Text("New photos are reviewed before they get a verified badge. Rejected photos are hidden from others.")
                .font(Theme.Typeface.footnote).foregroundStyle(Theme.Palette.inkSoft)
        }
    }

    private func basics(_ draft: Binding<Profile>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Eyebrow(text: "Basics")
            field("First name", text: draft.firstName)
                .textContentType(.givenName)
            Stepper(value: draft.age, in: 18...99) {
                HStack {
                    Text("Age").font(Theme.Typeface.callout.weight(.semibold))
                    Spacer()
                    Text("\(draft.wrappedValue.age)").font(Theme.Typeface.headline)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(minHeight: 54)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
            choiceRow("Pronouns", options: ["she/her", "he/him", "they/them", "she/they", "he/they"], selection: draft.pronouns)
            choiceRow("Gender", options: ["Woman", "Man", "Non-binary"], selection: draft.gender)
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
                .lineLimit(2...4)
                .font(Theme.Typeface.body)
                .padding(Theme.Space.l)
                .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
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
            Eyebrow(text: "Social availability")
            AvailabilityPicker(selection: draft.availability)
        }
    }

    private var instagramSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Eyebrow(text: "Instagram · optional")
            field("@handle", text: $instagram)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Label("Private. Only shared if you and a match both agree to swap.", systemImage: "lock.fill")
                .font(Theme.Typeface.footnote).foregroundStyle(Theme.Palette.inkSoft)
        }
    }

    // MARK: Helpers

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .font(Theme.Typeface.body)
            .padding(.horizontal, Theme.Space.l)
            .frame(minHeight: 54)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
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
                let path = try await state.backend.uploadPhoto(jpeg)
                draft?.photoPaths.append(path)
            } catch {
                state.handle(error)
            }
        }
    }

    private func save(_ profile: Profile) async {
        showMissing = true
        guard profile.isComplete else {
            state.feedback.play(.warning)
            return
        }
        let ok = await state.perform {
            try await state.saveProfile(profile)
            if instagram != state.account.instagramHandle {
                try await state.savePrivate(instagram: normalizedInstagram, verifiedOnly: state.account.verifiedOnlyDiscovery)
            }
        }
        if ok {
            state.feedback.play(.success)
            if mode == .edit { dismiss() }
        }
    }

    private var normalizedInstagram: String {
        let trimmed = instagram.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        guard !trimmed.isEmpty else { return "" }
        return trimmed.hasPrefix("@") ? trimmed : "@" + trimmed
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
            switch status {
            case .pending:
                StatusPill(text: "Photo review pending", systemImage: "hourglass", tint: Theme.Palette.amber, fill: Theme.Palette.amberSoft)
            case .approved:
                StatusPill(text: "Photos approved", systemImage: "checkmark.seal.fill", tint: Theme.Palette.mint, fill: Theme.Palette.mintSoft)
            case .rejected:
                StatusPill(text: "Photo rejected", systemImage: "xmark.octagon.fill", tint: Theme.Palette.danger, fill: Theme.Palette.crushSoft)
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
