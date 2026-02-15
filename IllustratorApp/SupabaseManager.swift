import Supabase
import Foundation

final class SupabaseManager {
    static let shared = SupabaseManager()

    let client: SupabaseClient

    private init() {
        client = SupabaseClient(
            supabaseURL: URL(string: "https://supabase.loop9.com.br")!,
            supabaseKey: "SUPABASE_KEY_REMOVED"
        )
    }

    var isAuthenticated: Bool {
        client.auth.currentSession != nil
    }

    var currentUserId: String? {
        client.auth.currentSession?.user.id.uuidString
    }
}
