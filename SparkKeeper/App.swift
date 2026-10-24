import SwiftUI
import UIKit

@main
@MainActor
struct SparkKeeperApp: App {

    @StateObject private var store = Store.shared

    init() {
        Scheduler.shared.register()
        Notifier.requestAuth()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onAppear {
                    Task { @MainActor in Scheduler.shared.scheduleNext() }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("续火花", systemImage: "flame.fill") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
            HistoryView()
                .tabItem { Label("记录", systemImage: "list.bullet.rectangle") }
        }
        .accentColor(.orange)
        .onChange(of: phase) { newPhase in
            if newPhase == .active {
                Task { @MainActor in
                    store.log("App 回到前台，重排定时")
                    Scheduler.shared.scheduleNext()
                }
            }
        }
    }
}
