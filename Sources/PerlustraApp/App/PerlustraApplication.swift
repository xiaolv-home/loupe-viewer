import AppKit

/// The program's entry point. The app lives in this library so tests can reach it.
public enum PerlustraApplication {
    public static func run() {
        LegacyData.migrateIfNeeded()
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            withExtendedLifetime(delegate) {
                app.run()
            }
        }
    }
}
