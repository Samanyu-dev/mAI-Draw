import SwiftUI

@main
struct PhoneApp: App {
    @StateObject private var authState = AuthState()

    var body: some Scene {
        WindowGroup {
            Group {
                if authState.isLoading {
                    ProgressView()
                } else if authState.isAuthenticated {
                    ProjectGalleryView()
                        .environmentObject(authState)
                } else {
                    LoginView()
                        .environmentObject(authState)
                }
            }
            .task {
                await authState.checkSession()
            }
        }
    }
}
