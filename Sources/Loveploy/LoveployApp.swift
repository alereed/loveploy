import SwiftUI

@main
struct LoveployApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(pending: model.pendingCount, busy: model.isDeploying)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let pending: Int
    let busy: Bool

    var body: some View {
        if busy {
            Image(systemName: "arrow.triangle.2.circlepath")
        } else if pending > 0 {
            Image(systemName: "arrow.up.heart.fill")
            Text("\(pending)")
        } else {
            Image(systemName: "heart")
        }
    }
}
