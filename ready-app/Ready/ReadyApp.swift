import SwiftUI

@main
struct ReadyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = ReadinessViewModel()

    var body: some Scene {
        WindowGroup {
            ReadinessView(viewModel: viewModel)
                .task {
                    await viewModel.start()
                }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active {
                        Task { await viewModel.refresh() }
                    }
                }
        }
    }
}
