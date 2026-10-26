import Foundation

/// A private ZDOTDIR forwards every login startup file, then installs two
/// interactive functions. No user rc file or global CLI setting is edited.
final class AgentShellIntegration {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Spark-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
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
        let items = String(data: try! JSONEncoder().encode(titleItems), encoding: .utf8)!
        return """
        if [[ -o interactive ]]; then
          if (( ! $+functions[codex] && ! $+aliases[codex] )); then
            function codex {
              if [[ ! -t 0 || ! -t 1 ]]; then command codex "$@"; return $?; fi
              printf '\\033]9001;SparkAgent:codex\\007'
              command codex -c 'tui.terminal_title=\(items)' "$@"
              local spark_exit=$?
              printf '\\033]9001;SparkAgent:end\\007\\033]7501;state=clear\\007\\033]2;\\007'
              return $spark_exit
            }
          fi
          if (( ! $+functions[claude] && ! $+aliases[claude] )); then
            function claude {
              if [[ ! -t 0 || ! -t 1 ]]; then command claude "$@"; return $?; fi
              local -x SPARK_CLAUDE_INVOCATION=$(/usr/bin/uuidgen)
              printf '\\033]9001;SparkAgent:claude:%s\\007' "$SPARK_CLAUDE_INVOCATION"
              command claude --settings "$SPARK_CLAUDE_SETTINGS" "$@"
              local spark_exit=$?
              printf '\\033]9001;SparkAgent:end\\007\\033]7501;state=clear\\007\\033]2;\\007'
              return $spark_exit
            }
          fi
        fi

        """
    }
}
