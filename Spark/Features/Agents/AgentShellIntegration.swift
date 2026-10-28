import Foundation

/// A private ZDOTDIR forwards login startup files, then puts two launchers on
/// PATH. Descendants such as `caveman codex` use the same integration.
final class AgentShellIntegration {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Spark-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        do {
            let bin = directory.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(
                at: bin, withIntermediateDirectories: false,
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
                    script +=
                        "if [[ -o login ]]; then\n  export ZDOTDIR=\"$SPARK_INTEGRATION_DIRECTORY\"\nelse\n"
                        + Self.functions + "\nfi\n"
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
        env["SPARK_CLAUDE_SETTINGS"] =
            #"{"statusLine":{"type":"command","command":"\"$SPARK_EXECUTABLE\" --claude-status"}}"#
        return env
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    static let titleItems = [
        "app-name", "thread-id", "app-name", "five-hour-limit", "app-name", "weekly-limit", "app-name",
        "model", "app-name", "context-used", "app-name",
        "total-input-tokens", "app-name", "total-output-tokens", "app-name",
        "thread-name", "app-name"
    ]

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
              function _spark_capture_command {
                local spark_command="$1"
                [[ -n "$spark_command" && ${#spark_command} -le 4096 ]] || return 0
                local spark_payload
                spark_payload=$(printf '%s' "$spark_command" | /usr/bin/base64 | /usr/bin/tr -d '\\n')
                printf '\\033]9001;SparkCommand:%s\\007' "$spark_payload"
              }
              typeset -ga precmd_functions
              precmd_functions=(_spark_restore_input ${precmd_functions:#_spark_restore_input})
              typeset -ga preexec_functions
              preexec_functions=(_spark_capture_command ${preexec_functions:#_spark_capture_command})
              path=("$SPARK_AGENT_BIN" "${path[@]}")
              export PATH
              rehash
              if [[ -n "$SPARK_LAUNCH_PROVIDER" ]]; then
                typeset -gi _spark_launch_attempts=0
                function _spark_launch_agent {
                  if [[ ! -t 0 || ! -t 1 || ! -t 2 ]]; then
                    if (( ++_spark_launch_attempts < 10 )); then
                      sched +1 _spark_launch_agent
                      return 0
                    fi
                    unset SPARK_LAUNCH_PROVIDER SPARK_RESUME_ID
                    printf '\033]9001;SparkAgent:launch-failed\007'
                    print -u2 'Spark could not resume this conversation because terminal input is unavailable.'
                    return 1
                  fi
                  local spark_provider="$SPARK_LAUNCH_PROVIDER" spark_resume="$SPARK_RESUME_ID"
                  unset SPARK_LAUNCH_PROVIDER SPARK_RESUME_ID
                  unset _spark_launch_attempts
                  case "$spark_provider" in
                    codex)
                      if [[ -n "$spark_resume" ]]; then command codex resume "$spark_resume"; else command codex; fi ;;
                    claude)
                      if [[ -n "$spark_resume" ]]; then command claude --resume "$spark_resume"; else command claude; fi ;;
                  esac
                  local spark_exit=$?
                  _spark_restore_input
                  return $spark_exit
                }
                # Prompt themes can keep stdin on /dev/null until their scheduled
                # post-precmd cleanup. Queue behind it instead of running inside precmd.
                function _spark_schedule_launch {
                  precmd_functions=(${precmd_functions:#_spark_schedule_launch})
                  zmodload zsh/sched
                  sched +0 _spark_launch_agent
                }
                precmd_functions+=(_spark_schedule_launch)
              fi
            fi

            """
    }

    private static func launcher(for agent: String) throws -> String {
        let items = String(decoding: try JSONEncoder().encode(titleItems), as: UTF8.self)
        let start: String
        if agent == "codex" {
            start = """
                printf '\\033]9001;SparkAgent:codex\\007'
                printf '\\033]9001;SparkCodexHome:%s\\007' "$(printf '%s' "${CODEX_HOME:-$HOME/.codex}" | /usr/bin/base64)"
                "$spark_binary" -c 'tui.terminal_title=\(items)' "$@"
                """
        } else {
            start = """
                export SPARK_CLAUDE_INVOCATION=$(/usr/bin/uuidgen)
                printf '\\033]9001;SparkAgent:claude:%s\\007' "$SPARK_CLAUDE_INVOCATION"
                "$spark_binary" --settings "$SPARK_CLAUDE_SETTINGS" "$@"
                """
        }
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
