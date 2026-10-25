import SwiftUI

@main
struct LoveployApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(pending: model.pendingCount, busy: model.isDeploying, turbo: model.state.turbo)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let pending: Int
    let busy: Bool
    let turbo: Bool

    var body: some View {
        if busy {
            Image(systemName: "arrow.triangle.2.circlepath")
        } else if turbo {
            Image(systemName: "bolt.heart.fill")
            if pending > 0 { Text("\(pending)") }
        } else if pending > 0 {
            Image(systemName: "arrow.up.heart.fill")
            Text("\(pending)")
        } else {
            Image(systemName: "heart")
        }
    }
}
