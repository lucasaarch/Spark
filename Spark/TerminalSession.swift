import AppKit
import Combine
import SwiftTerm

/// The session owns its PTY and view. SwiftUI may detach the view without ending the shell.
@MainActor
final class TerminalSession: ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let terminal: SparkTerminalView
    let shell: String
    @Published var title: String
    @Published var directory: URL
    @Published var dimensions = ""
    @Published private(set) var status: Status = .ready

    enum Status: Equatable {
        case ready, running, exited(Int32?), failed
        var label: String {
            switch self {
            case .ready: "Ready"
            case .running: "Running"
            case .exited(let code): code.map { "Exited · \($0)" } ?? "Ended"
            case .failed: "Launch failed"
            }
        }
    }

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.directory = directory
        shell = Self.loginShell()
        title = URL(fileURLWithPath: shell).lastPathComponent
        var options = TerminalOptions.default
        options.scrollback = 10_000
        options.termName = "xterm-256color"
        terminal = SparkTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 560), options: options)
        terminal.processDelegate = self
        terminal.setAccessibilityLabel("Terminal")
        terminal.nativeBackgroundColor = NSColor(srgbRed: 0.055, green: 0.063, blue: 0.078, alpha: 1)
        terminal.nativeForegroundColor = NSColor(srgbRed: 0.84, green: 0.86, blue: 0.90, alpha: 1)
        terminal.caretColor = NSColor(srgbRed: 1, green: 0.72, blue: 0.37, alpha: 1)
        terminal.selectedTextBackgroundColor = NSColor(srgbRed: 0.26, green: 0.29, blue: 0.36, alpha: 1)
        terminal.optionAsMetaKey = false // Preserve macOS Option input for international keyboards.
        terminal.setCursorStyle(.blinkBar)
        terminal.installColors(Self.palette.map { hex in
            SwiftTerm.Color(red: UInt16((hex >> 16) & 255) * 257,
                            green: UInt16((hex >> 8) & 255) * 257,
                            blue: UInt16(hex & 255) * 257)
        })
        terminal.updateColorScheme(.dark)
        applyPreferences()
    }

    static func loginShell() -> String {
        if let entry = getpwuid(getuid()), let value = entry.pointee.pw_shell {
            let path = String(cString: value)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    static func environment(inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var environment = inherited
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Spark"
        environment["TERM_PROGRAM_VERSION"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        return environment.map { "\($0.key)=\($0.value)" }.sorted()
    }

    func start() {
        guard status == .ready else { return }
        status = .running
        terminal.startProcess(executable: shell, environment: Self.environment(),
                              execName: "-" + URL(fileURLWithPath: shell).lastPathComponent,
                              currentDirectory: directory.path)
    }

    func stop() {
        terminal.terminate()
    }

    func applyPreferences() {
        let size = UserDefaults.standard.double(forKey: "fontSize")
        terminal.font = .monospacedSystemFont(ofSize: min(28, max(11, size == 0 ? 14 : size)), weight: .regular)
        terminal.optionAsMetaKey = UserDefaults.standard.bool(forKey: "optionAsMeta")
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // Resize callbacks can arrive while SwiftUI is laying out its NSView.
        Task { @MainActor [weak self] in self?.dimensions = "\(newCols) × \(newRows)" }
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        self.title = String(title.prefix(160))
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost" || url.host == ProcessInfo.processInfo.hostName,
              FileManager.default.fileExists(atPath: url.path) else { return }
        self.directory = url
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) { status = .exited(exitCode) }
    func processFailedToStart(source: TerminalView, error: LocalProcessError) { status = .failed }

    private static let palette: [UInt32] = [
        0x20232D, 0xF08080, 0xA8CC8C, 0xEBCB8B, 0x8EBCED, 0xC5A1DE, 0x8BD5CA, 0xD8DEE9,
        0x697386, 0xF5A0A0, 0xBDDEA7, 0xF5DCA5, 0xADD0F5, 0xD8BAEB, 0xA7E5DB, 0xF3F5F7
    ]
}

/// Terminal output is untrusted: it may open web links, never arbitrary local URL schemes.
final class SparkTerminalView: LocalProcessTerminalView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityValue() -> Any? {
        visibleRowsText(0..<terminalDimensions.rows).joined(separator: "\n")
    }

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              ["https", "http", "mailto"].contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }

}
