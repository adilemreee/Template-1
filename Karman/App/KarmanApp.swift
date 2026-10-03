import SwiftUI

@main
struct KarmanApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // English formats first: stored properties initialise in order, before AppModel reads the locale.
    private let english: Void = AppLocale.apply()
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .onAppear { appDelegate.model = model }
        }
    }
}
