import SwiftUI
import BackgroundTasks
import CrestaCore

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppModel.syncTaskID, using: nil) { task in
            let work = Task { @MainActor in
                await AppModel.shared.runBackgroundSync()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
        MainActor.assumeIsolated { _ = AppModel.shared }
        return true
    }
}

@main
struct CrestaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ThemedRoot()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.setActive(true)
            case .background: model.setActive(false)
            default: break
            }
        }
    }
}

/// Builds the Material palette: seed from the season (or the user's
/// choice) and the light/dark appearance.
private struct ThemedRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var systemScheme

    private var scheme: ColorScheme {
        switch model.data.settings.appearance {
        case .system: return systemScheme
        case .light: return .light
        case .dark: return .dark
        }
    }

    var body: some View {
        let theme = M3Theme(seed: model.seedColor, dark: scheme == .dark)
        RootView()
            .environment(\.m3, theme)
            .tint(theme.primary)
            .preferredColorScheme(model.data.settings.appearance == .system ? nil : scheme)
            .animation(.easeInOut(duration: 0.5), value: model.seedColor)
    }
}
