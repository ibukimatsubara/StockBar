import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    @Published var isEnabled: Bool = false
    @Published var lastError: String?

    private let service = SMAppService.mainApp

    private init() {
        refresh()
    }

    func refresh() {
        isEnabled = (service.status == .enabled)
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                if service.status == .enabled { isEnabled = true; return }
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }
}
