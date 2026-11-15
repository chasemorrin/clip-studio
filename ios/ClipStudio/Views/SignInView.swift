import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @EnvironmentObject var session: SessionStore
    @State private var testPassword = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 8) {
                Text("Clip Studio")
                    .font(.system(size: 40, weight: .bold, design: .serif))
                    .italic()
                Text("Find the moments in your footage.")
                    .foregroundStyle(.secondary)
            }
            Spacer()

            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = []
            } onCompletion: { result in
                switch result {
                case .success(let auth):
                    guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                          let data = cred.identityToken, let token = String(data: data, encoding: .utf8) else {
                        error = "Apple didn't return a sign-in. Try again."
                        return
                    }
                    Task { await finish { try await APIClient.shared.signInWithApple(identityToken: token) } }
                case .failure(let e):
                    let code = (e as? ASAuthorizationError)?.code
                    if code == .canceled { return }
                    error = "Sign in with Apple isn't available yet. Use your test password below until the Apple Developer membership is active."
                }
            }
            .signInWithAppleButtonStyle(.whiteOutline)
            .frame(height: 50)

            VStack(alignment: .leading, spacing: 8) {
                Text("Test sign-in").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                HStack {
                    SecureField("Test password", text: $testPassword)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit(signInWithPassword)
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    Button("Sign in", action: signInWithPassword)
                        .buttonStyle(.borderedProminent)
                        .disabled(testPassword.isEmpty || working)
                }
            }

            if let error {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            if working { ProgressView() }
            Spacer().frame(height: 20)
        }
        .padding(.horizontal, 24)
    }

    private func signInWithPassword() {
        let key = testPassword
        Task { await finish { try await APIClient.shared.signInWithTestPassword(key) } }
    }

    private func finish(_ call: () async throws -> String) async {
        working = true
        error = nil
        defer { working = false }
        do {
            session.signedIn(token: try await call())
        } catch {
            self.error = error.localizedDescription
        }
    }
}
