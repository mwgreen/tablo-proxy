import SwiftUI

@main
struct TabloTVApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ProxyClient.shared)
        }
    }
}
