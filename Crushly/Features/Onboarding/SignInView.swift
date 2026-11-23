import SwiftUI

/// Passwordless USC email sign-in. "Create account" makes an account for a new address; "Sign in" only works for an
/// existing one, so a mistyped address doesn't quietly create a second, empty account.
struct SignInView: View {
    @Environment(AppState.self) private var state
    @State private var mode: Mode = .createAccount
    @State private var noAccountFor: String?
    @State private var email = ""
    @State private var code = ""
    @State private var codeSentTo: String?
    @State private var resendAvailableAt = Date.distantPast
    @FocusState private var focus: Field?

    private enum Field { case email, code }

    enum Mode: String, CaseIterable, Identifiable {
        case createAccount, signIn
        var id: Self { self }
        var title: String { self == .createAccount ? "Create account" : "Sign in" }
    }

    var body: some View {
        ZStack {
            RetroBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    hero
                    Group {
                        if let sentTo = codeSentTo {
                            codeStep(sentTo)
                        } else {
                            emailStep
                        }
                    }
                    .crushCard(padding: Theme.Space.xl, fill: Theme.Palette.surface.opacity(0.94))

                    Text("Verifying your email confirms you control a USC address. It is not identity or age verification.")
                        .font(Theme.Typeface.footnote)
                        .foregroundStyle(Theme.Palette.inkSoft)
                }
                .padding(Theme.Space.gutter)
                .padding(.top, Theme.Space.xxl)
                .crushScrollPadding()
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear { focus = .email }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    CrushlyBrandIcon(size: 58)
                        .padding(.bottom, Theme.Space.s)
                    Text("Crushly")
                        .font(Theme.Typeface.display)
                        .foregroundStyle(Theme.Palette.oxblood)
                }
                Spacer()
                if state.config.isDemo { DemoBadge() }
            }
            Text("Someone nearby\nmight be feeling it too.")
                .font(Theme.Typeface.title)
                .foregroundStyle(Theme.Palette.oxblood)
                .lineLimit(3)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)
            Text("Crushly is for USC students. Interest stays anonymous until it's mutual.")
                .font(Theme.Typeface.body)
                .foregroundStyle(Theme.Palette.inkSoft)
        }
    }

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Picker("Account", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("signin.mode")
            .onChange(of: mode) { noAccountFor = nil }

            Eyebrow(text: mode == .createAccount ? "New here? Use your USC email" : "Welcome back")
            TextField("you@usc.edu", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .email)
                .submitLabel(.send)
                .onSubmit { Task { await sendCode() } }
                .onChange(of: email) { noAccountFor = nil }
                .font(Theme.Typeface.body)
                .padding(.horizontal, Theme.Space.l)
                .frame(minHeight: 54)
                .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s).stroke(Theme.Palette.hairline))
                .accessibilityLabel("USC email address")
                .accessibilityIdentifier("signin.email")

            if !email.isEmpty, email.contains("@"), !state.rules.isAllowedEmail(email) {
                Label("Use your @usc.edu address.", systemImage: "info.circle")
                    .font(Theme.Typeface.footnote)
                    .foregroundStyle(Theme.Palette.danger)
            }

            if let missing = noAccountFor {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Label("There's no Crushly account for \(missing) yet.", systemImage: "person.crop.circle.badge.questionmark")
                        .font(Theme.Typeface.footnote)
                        .foregroundStyle(Theme.Palette.danger)
                    Button("Create an account instead") {
                        mode = .createAccount
                        Task { await sendCode() }
                    }
                    .font(Theme.Typeface.subheadline.weight(.semibold))
                    .frame(minHeight: Theme.minTap)
                    .accessibilityIdentifier("signin.createInstead")
                }
            }

            AsyncButton { await sendCode() } label: { Text("Email me a code") }
                .buttonStyle(.crush)
                .accessibilityIdentifier("signin.sendCode")
                .disabled(!state.rules.isAllowedEmail(email))
        }
    }

    private func codeStep(_ sentTo: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Eyebrow(text: "Check your inbox")
            Text("We sent a 6-digit code to **\(sentTo)**.")
                .font(Theme.Typeface.body)
            if state.config.isDemo {
                Label("Demo mode: no email is sent. Use code \(DemoWorld.demoCode).", systemImage: "testtube.2")
                    .font(Theme.Typeface.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Palette.plum)
            }
            TextField("123456", text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .focused($focus, equals: .code)
                .font(.system(.title, design: .monospaced).weight(.bold))
                .multilineTextAlignment(.center)
                .frame(minHeight: 60)
                .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s).stroke(Theme.Palette.hairline))
                .onChange(of: code) { _, new in code = String(new.filter(\.isNumber).prefix(6)) }
                .accessibilityLabel("Six digit code")
                .accessibilityIdentifier("signin.code")

            AsyncButton { await verify(sentTo) } label: { Text("Verify and continue") }
                .buttonStyle(.crush)
                .accessibilityIdentifier("signin.verify")
                .disabled(code.count != 6)

            HStack {
                Button("Use a different email") {
                    codeSentTo = nil
                    code = ""
                    focus = .email
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let wait = Int(resendAvailableAt.timeIntervalSince(context.date).rounded(.up))
                    Button(wait > 0 ? "Resend in \(wait)s" : "Resend code") { Task { await sendCode() } }
                        .disabled(wait > 0)
                }
            }
            .font(Theme.Typeface.subheadline.weight(.semibold))
            .frame(minHeight: Theme.minTap)
        }
        .onAppear { focus = .code }
    }

    private func sendCode() async {
        let target = email.lowercased().trimmingCharacters(in: .whitespaces)
        guard state.rules.isAllowedEmail(target) else { return }
        noAccountFor = nil
        var missing = false
        let sent = await state.perform {
            do {
                try await state.requestCode(email: target, createAccount: mode == .createAccount)
            } catch CrushlyError.accountNotFound {
                missing = true
            }
        }
        if missing {
            noAccountFor = target
        } else if sent {
            codeSentTo = target
            resendAvailableAt = Date().addingTimeInterval(30)
        }
    }

    private func verify(_ sentTo: String) async {
        await state.perform { try await state.verifyCode(email: sentTo, code: code) }
    }
}
