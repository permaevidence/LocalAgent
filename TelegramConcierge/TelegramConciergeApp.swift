import SwiftUI

@main
struct TelegramConciergeApp: App {
    @StateObject private var conversationManager = ConversationManager()
    @State private var onboardingComplete = !OnboardingView.shouldShowOnboarding

    init() {
        LandingZone.bootstrap()
        ProjectsZipAutoExtractor.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            if onboardingComplete {
                MainView()
                    .environmentObject(conversationManager)
            } else {
                OnboardingView(isComplete: $onboardingComplete)
                    .environmentObject(conversationManager)
            }
        }
        .defaultSize(width: 960, height: 700)
    }
}
