import SwiftUI

struct LoginView: View {
    @EnvironmentObject var authState: AuthState
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Logo
            VStack(spacing: 8) {
                Image(systemName: "pencil.and.scribble")
                    .font(.system(size: 60, weight: .light))
                    .foregroundStyle(.primary)
                Text("mAIDraw")
                    .font(.largeTitle.weight(.bold))
            }

            // Fields
            VStack(spacing: 16) {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding()
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))

                SecureField("Senha", text: $password)
                    .textContentType(.password)
                    .padding()
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
            }
            .frame(maxWidth: 360)

            // Buttons
            VStack(spacing: 12) {
                let fieldsReady = !email.isEmpty && !password.isEmpty && !isLoading

                Button {
                    signIn()
                } label: {
                    Text("Entrar")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.black)
                }
                .opacity(fieldsReady ? 1 : 0.35)
                .disabled(!fieldsReady)

                Button {
                    signUp()
                } label: {
                    Text("Criar conta")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .disabled(!fieldsReady)
            }
            .frame(maxWidth: 360)

            if isLoading {
                ProgressView()
            }

            Spacer()
            Spacer()
        }
        .padding(24)
        .alert("Erro", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "Erro desconhecido")
        }
    }

    private func signIn() {
        isLoading = true
        Task {
            do {
                try await authState.signIn(email: email, password: password)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            isLoading = false
        }
    }

    private func signUp() {
        isLoading = true
        Task {
            do {
                try await authState.signUp(email: email, password: password)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            isLoading = false
        }
    }
}
