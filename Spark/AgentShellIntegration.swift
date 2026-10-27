import Foundation

/// A private ZDOTDIR forwards login startup files, then puts two launchers on
/// PATH. Descendants such as `caveman codex` use the same integration.
final class AgentShellIntegration {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Spark-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
            let bin = directory.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            for agent in ["codex", "claude"] {
                let file = bin.appendingPathComponent(agent)
                try Self.launcher(for: agent).write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            }
            for name in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
                var script = """
                if (( ${+SPARK_USER_ZDOTDIR} )); then
                  ZDOTDIR="$SPARK_USER_ZDOTDIR"
                else
                  unset ZDOTDIR
                fi
                [[ -r "${ZDOTDIR:-$HOME}/\(name)" ]] && source "${ZDOTDIR:-$HOME}/\(name)"
                if (( ${+ZDOTDIR} )); then
                  export SPARK_USER_ZDOTDIR="$ZDOTDIR"
                else
                  unset SPARK_USER_ZDOTDIR
                fi

                """
                if name == ".zlogin" {
                    script += Self.functions
                } else if name == ".zshrc" {
                    script += "if [[ -o login ]]; then\n  export ZDOTDIR=\"$SPARK_INTEGRATION_DIRECTORY\"\nelse\n" + Self.functions + "\nfi\n"
                } else {
                    script += "export ZDOTDIR=\"$SPARK_INTEGRATION_DIRECTORY\"\n"
                }
                try script.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func environment(inherited: [String: String], executable: String) -> [String: String] {
        var env = inherited
        env["SPARK_USER_ZDOTDIR"] = inherited["ZDOTDIR"]
        env["ZDOTDIR"] = directory.path
        env["SPARK_INTEGRATION_DIRECTORY"] = directory.path
        env["SPARK_METRICS_DIRECTORY"] = directory.path
        env["SPARK_AGENT_BIN"] = directory.appendingPathComponent("bin").path
        env["SPARK_EXECUTABLE"] = executable
        // JSON contains a fixed shell command. The executable is expanded as a
        // quoted environment variable, so spaces and metacharacters are safe.
        env["SPARK_CLAUDE_SETTINGS"] = #"{"statusLine":{"type":"command","command":"\"$SPARK_EXECUTABLE\" --claude-status"}}"#
        return env
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    static let titleItems = ["app-name", "thread-name", "app-name", "model", "app-name", "context-used", "app-name",
                             "total-input-tokens", "app-name", "total-output-tokens", "app-name",
                             "five-hour-limit", "app-name", "weekly-limit", "app-name"]

    private static var functions: String {
        return """
        if [[ -o interactive ]]; then
          # Restore shell input before every prompt, including aliases that
          # bypass our wrappers. Tracking and encoding are separate mouse modes;
          # disabling only SGR encoding still sends pointer events to the shell.
          # Pop the whole Kitty stack so a later pop cannot revive a stale mode.
          function _spark_restore_input {
            [[ -t 1 ]] && printf '\\033[?9;1000;1002;1003;1004;1005;1006;1015;1016l\\033[<999u'
            return 0
          }
          typeset -ga precmd_functions
          precmd_functions=(_spark_restore_input ${precmd_functions:#_spark_restore_input})
          path=("$SPARK_AGENT_BIN" "${path[@]}")
          export PATH
          rehash
        fi

        """
    }

    private static func launcher(for agent: String) -> String {
        let items = String(data: try! JSONEncoder().encode(titleItems), encoding: .utf8)!
        let start = agent == "codex"
            ? "printf '\\033]9001;SparkAgent:codex\\007'\n\"$spark_binary\" -c 'tui.terminal_title=\(items)' \"$@\""
            : "export SPARK_CLAUDE_INVOCATION=$(/usr/bin/uuidgen)\nprintf '\\033]9001;SparkAgent:claude:%s\\007' \"$SPARK_CLAUDE_INVOCATION\"\n\"$spark_binary\" --settings \"$SPARK_CLAUDE_SETTINGS\" \"$@\""
        return """
        #!/bin/zsh -f
        # Resolve the user's executable without finding this launcher again.
        typeset -a spark_original_path=("${path[@]}")
        typeset -a spark_search_path=()
        for spark_entry in "${path[@]}"; do
          [[ "$spark_entry" != "$SPARK_AGENT_BIN" ]] && spark_search_path+=("$spark_entry")
        done
        path=("${spark_search_path[@]}")
        spark_binary=$(whence -p \(agent)) || { print -u2 'Spark: \(agent) not found on PATH'; exit 127; }
        path=("${spark_original_path[@]}")
        export PATH
        # Automation retains its original arguments, output, and exit status.
        if [[ ! -t 0 || ! -t 1 ]]; then exec "$spark_binary" "$@"; fi
        trap 'printf "\\033]9001;SparkAgent:end\\007\\033]7501;state=clear\\007\\033]2;\\007"' EXIT
        \(start)
        exit $?

        """
    }
}
