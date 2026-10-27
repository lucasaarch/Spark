import AppKit
import Combine
import UserNotifications

/// State transitions, not progress/message updates, produce notifications.
struct AgentNotificationPolicy {
    private var previous: AgentActivity?
    private var hasWorked = false

    mutating func update(_ activity: AgentActivity?, isViewing: Bool) -> String? {
        guard let activity else { previous = nil; hasWorked = false; return nil }
        if previous?.provider != activity.provider { hasWorked = false }
        let changed = previous?.provider != activity.provider || previous?.state != activity.state || previous?.kind != activity.kind
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
final class AgentNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var enabled: Bool
    @Published private(set) var requestingAuthorization = false
    @Published private(set) var status: String = "Alerts for completion, errors and requests for attention."
    var activateSession: ((UUID, UUID) -> Void)?
    var isViewingSession: ((UUID, UUID) -> Bool)?
    private var policies: [UUID: AgentNotificationPolicy] = [:]
    private var authorizationGeneration = 0
    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults

    init(center: UNUserNotificationCenter = .current(), defaults: UserDefaults = .standard) {
        self.center = center
        self.defaults = defaults
        enabled = defaults.bool(forKey: "agentNotificationsEnabled")
        super.init()
        center.delegate = self
        if enabled {
            Task { [weak self, center] in
                let settings = await center.notificationSettings()
                guard let self, self.enabled, !self.requestingAuthorization else { return }
                if settings.authorizationStatus != .authorized && settings.authorizationStatus != .provisional {
                    self.enabled = false
                    self.defaults.set(false, forKey: "agentNotificationsEnabled")
                    self.status = "Allow Spark notifications in System Settings to receive agent alerts."
                }
            }
        }
    }

    func setEnabled(_ value: Bool) {
        authorizationGeneration += 1
        let generation = authorizationGeneration
        guard value else {
            enabled = false
            requestingAuthorization = false
            defaults.set(false, forKey: "agentNotificationsEnabled")
            status = "Alerts for completion, errors and requests for attention."
            center.removeAllPendingNotificationRequests()
            center.removeAllDeliveredNotifications()
            return
        }
        requestingAuthorization = true
        status = "Waiting for notification permission from macOS…"
        Task {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard authorizationGeneration == generation else { return }
                requestingAuthorization = false
                enabled = granted
                defaults.set(granted, forKey: "agentNotificationsEnabled")
                status = granted ? "Notifications enabled. The session you are using stays quiet."
                    : "Notifications are blocked. Allow Spark in System Settings → Notifications."
            } catch {
                guard authorizationGeneration == generation else { return }
                requestingAuthorization = false
                enabled = false
                defaults.set(false, forKey: "agentNotificationsEnabled")
                status = "Notifications unavailable: \(error.localizedDescription)"
            }
        }
    }

    func observe(_ activity: AgentActivity?, session: TerminalSession, workspaceID: UUID) {
        var policy = policies[session.id] ?? AgentNotificationPolicy()
        let event = policy.update(activity, isViewing: isViewingSession?(workspaceID, session.id) ?? false)
        policies[session.id] = policy
        guard enabled, let event, let activity else { return }
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

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let info = notification.request.content.userInfo
        let workspace = (info["workspace"] as? String).flatMap(UUID.init(uuidString:))
        let session = (info["session"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor [weak self] in
            guard let self, self.enabled, let workspace, let session,
                  self.isViewingSession?(workspace, session) != true else { completionHandler([]); return }
            completionHandler([.banner, .sound])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
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
