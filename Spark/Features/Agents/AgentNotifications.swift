import AppKit
import UserNotifications

/// State transitions, not progress/message updates, produce notifications.
struct AgentNotificationPolicy {
    private var previous: AgentActivity?
    private var hasWorked = false

    mutating func update(_ activity: AgentActivity?, isViewing: Bool) -> String? {
        guard let activity else { previous = nil; hasWorked = false; return nil }
        if previous?.provider != activity.provider { hasWorked = false }
        let changed =
            previous?.provider != activity.provider || previous?.state != activity.state
            || previous?.kind != activity.kind
        previous = activity
        var event: String?
        switch activity.state {
        case .working: hasWorked = true
        case .idle, .done:
            if hasWorked { event = "Finished working"; hasWorked = false }
        case .blocked:
            if changed { event = activity.label }
        case .error:
            if changed { event = "Encountered an error" }
            hasWorked = false
        }
        return isViewing ? nil : event
    }
}

@MainActor
final class AgentNotifications: NSObject, UNUserNotificationCenterDelegate {
    var activateSession: ((UUID, UUID) -> Void)?
    var isViewingSession: ((UUID, UUID) -> Bool)?
    private var policies: [UUID: AgentNotificationPolicy] = [:]
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    /// No app-level opt-out: macOS owns permission and delivery settings, including
    /// re-enabling alerts while Spark is running. Legacy app preferences are ignored.
    func requestAuthorizationIfNeeded() {
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) } catch {
                NSLog("Spark: notification authorization failed: %@", error.localizedDescription)
            }
        }
    }

    func observe(_ activity: AgentActivity?, session: TerminalSession, workspaceID: UUID) {
        var policy = policies[session.id] ?? AgentNotificationPolicy()
        let event = policy.update(activity, isViewing: isViewingSession?(workspaceID, session.id) ?? false)
        policies[session.id] = policy
        guard let event, let activity else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(activity.provider.name) · \(event)"
        content.body = String(session.displayTitle.prefix(160))
        content.sound = .default
        content.threadIdentifier = workspaceID.uuidString
        content.userInfo = ["workspace": workspaceID.uuidString, "session": session.id.uuidString]
        // One outstanding alert per session; progress bursts cannot flood the center.
        let request = UNNotificationRequest(identifier: session.id.uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error { NSLog("Spark: notification delivery failed: %@", error.localizedDescription) }
        }
    }

    func removeSession(_ id: UUID) {
        policies.removeValue(forKey: id)
        center.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let info = notification.request.content.userInfo
        let workspace = (info["workspace"] as? String).flatMap(UUID.init(uuidString:))
        let session = (info["session"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor [weak self] in
            guard let self, let workspace, let session,
                self.isViewingSession?(workspace, session) != true
            else { completionHandler([]); return }
            completionHandler([.banner, .sound])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let workspace = (info["workspace"] as? String).flatMap(UUID.init(uuidString:))
        let session = (info["session"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor [weak self] in
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier, let workspace, let session {
                self?.activateSession?(workspace, session)
            }
            completionHandler()
        }
    }
}
