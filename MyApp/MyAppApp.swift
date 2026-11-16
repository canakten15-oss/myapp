import SwiftUI

@main
struct MyAppApp: App {
    @StateObject private var model = LibraryViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task { await AdService.shared.start() }
        }
    }
}
