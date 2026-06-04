import Supabase
import Foundation

enum AppSecrets {
    static func value(_ key: String) -> String? {
        let candidates = [
            Bundle.main.object(forInfoDictionaryKey: key) as? String,
            ProcessInfo.processInfo.environment[key]
        ]

        return candidates.compactMap(normalized).first
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("$("),
              !trimmed.contains("_REMOVED") else {
            return nil
        }

        return trimmed
    }
}

final class SupabaseManager {
    static let shared = SupabaseManager()

    let client: SupabaseClient

    private init() {
        client = SupabaseClient(
            supabaseURL: URL(string: AppSecrets.value("SUPABASE_URL") ?? "https://supabase.loop9.com.br")!,
            supabaseKey: AppSecrets.value("SUPABASE_KEY") ?? ""
        )
    }

    var isAuthenticated: Bool {
        client.auth.currentSession != nil
    }

    var currentUserId: String? {
        client.auth.currentSession?.user.id.uuidString
    }
}
