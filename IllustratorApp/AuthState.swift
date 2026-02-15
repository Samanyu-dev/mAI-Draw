import SwiftUI
import Supabase

@MainActor
class AuthState: ObservableObject {
    @Published var isAuthenticated = false
    @Published var isLoading = true

    func checkSession() async {
        do {
            _ = try await SupabaseManager.shared.client.auth.session
            isAuthenticated = true
        } catch {
            isAuthenticated = false
        }
        isLoading = false
    }

    func signIn(email: String, password: String) async throws {
        try await SupabaseManager.shared.client.auth.signIn(email: email, password: password)
        isAuthenticated = true
    }

    func signUp(email: String, password: String) async throws {
        try await SupabaseManager.shared.client.auth.signUp(email: email, password: password)
        isAuthenticated = true
    }

    func signOut() async {
        try? await SupabaseManager.shared.client.auth.signOut()
        isAuthenticated = false
    }
}
