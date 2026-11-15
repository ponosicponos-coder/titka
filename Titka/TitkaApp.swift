import SwiftUI

@main
struct TitkaApp: App {
    @StateObject private var state = AppState.shared

    init() {
        // Запускається і тоді, коли iOS будить програму у фоні через подію зони.
        AppState.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
        }
    }
}
