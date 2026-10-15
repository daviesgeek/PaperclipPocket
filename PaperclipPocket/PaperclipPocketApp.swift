import SwiftUI

@main
struct PaperclipPocketApp: App {
    @UIApplicationDelegateAdaptor(NotificationDelegate.self) private var notifications
    @StateObject private var store = AppStore.shared

    var body: some Scene {
        WindowGroup {
            TabView(selection: $store.selectedTab) {
                TasksView()
                    .tabItem { Label("Tasks", systemImage: "checklist") }
                    .tag(0)
                ChatsView()
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                    .tag(1)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(2)
            }
            .environmentObject(store)
        }
    }
}
