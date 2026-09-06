import Foundation

struct CommandResult {
    let exitCode: Int32
    let output: String
    var succeeded: Bool { exitCode == 0 }
}

enum CommandError: LocalizedError {
    case launchFailed(String)
    case missingExecutable(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .launchFailed(let detail): return "Could not start the process: \(detail)"
        case .missingExecutable(let path): return "Executable not found at \(path)."
        case .cancelled: return "Cancelled."
        }
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Runs child processes under a pseudo-terminal.
///
/// Heimdall only flushes progress when it believes it is attached to a terminal, and
/// it redraws percentages with carriage returns. Piping it directly yields nothing
/// until the process exits, so every command goes through `script -q /dev/null`,
/// which allocates a pty for us and preserves the live output.
final class CommandRunner: @unchecked Sendable {
    private static let scriptPath = "/usr/bin/script"
    private static let sudoPath = "/usr/bin/sudo"

    /// Environment variable the askpass helper reads the password from.
    static let askpassSecretVariable = "VALKYRIE_ASKPASS_SECRET"

    /// Writes (once) the tiny helper sudo calls to obtain a password.
    ///
    /// Feeding `sudo -S` on stdin cannot work here: every command runs under a pty for
    /// live progress, and the pty echoes the password straight back instead of handing
    /// it to sudo, which then blocks forever waiting on the terminal. `sudo -A` sidesteps
    /// stdin and the tty completely by asking this helper instead.
    ///
    /// The script itself holds no secret — it only echoes an environment variable that
    /// is set per invocation, so nothing sensitive is written to disk.
    private static func askpassHelper() throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Valkyrie", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = directory.appendingPathComponent("askpass.sh")

        let body = "#!/bin/sh\nprintf '%s\\n' \"$\(askpassSecretVariable)\"\n"
        let existing = try? String(contentsOf: helper, encoding: .utf8)
        if existing != body {
            try body.write(to: helper, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return helper
    }

    private let processBox = Box<Process?>(nil)

    /// - Parameters:
    ///   - elevated: runs the command through `sudo -A`, with `stdin` supplying the
    ///     password to the askpass helper rather than being written to the process.
    ///   - stdin: written to the child once, followed by a newline.
    @discardableResult
    func run(
        executable: String,
        arguments: [String] = [],
        elevated: Bool = false,
        stdin: String? = nil,
        onOutput: ((String) -> Void)? = nil
    ) async throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw CommandError.missingExecutable(executable)
        }

        let process = Process()

        // Only allocate a pty when the caller wants live output.
        //
        // `script` makes the child believe it is on a terminal, which is what keeps the
        // flash's progress flowing — but it also echoes an EOF marker ("^D" plus two
        // backspaces) into the stream. TerminalBuffer resolves those for display, yet any
        // caller capturing output as *data* would be handed the junk: it is what turned a
        // detected model into "^D<BS><BS>SM-F956B" and made Samsung reject the lookup.
        // Commands that are only read for their result run directly on pipes instead.
        let usesTerminal = onOutput != nil
        var argv: [String] = []
        var environment = ProcessInfo.processInfo.environment

        if elevated {
            let helper = try CommandRunner.askpassHelper()
            environment["SUDO_ASKPASS"] = helper.path
            environment[CommandRunner.askpassSecretVariable] = stdin ?? ""
        }

        if usesTerminal {
            process.executableURL = URL(fileURLWithPath: CommandRunner.scriptPath)
            argv = ["-q", "/dev/null"]
            if elevated { argv += [CommandRunner.sudoPath, "-A"] }
            argv.append(executable)
            argv += arguments
        } else if elevated {
            process.executableURL = URL(fileURLWithPath: CommandRunner.sudoPath)
            argv = ["-A", executable] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: executable)
            argv = arguments
        }

        process.arguments = argv
        process.environment = environment

        let outPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe
        process.standardInput = inPipe

        let collected = Box("")
        let lock = NSLock()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = CommandRunner.sanitize(String(decoding: data, as: UTF8.self))
            guard !chunk.isEmpty else { return }
            lock.lock()
            collected.value += chunk
            lock.unlock()
            onOutput?(chunk)
        }

        processBox.value = process
        let launchError = Box<Error?>(nil)

        let exitCode: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
                if let stdin, !elevated {
                    inPipe.fileHandleForWriting.write(Data((stdin + "\n").utf8))
                }
                try? inPipe.fileHandleForWriting.close()
            } catch {
                launchError.value = error
                process.terminationHandler = nil
                continuation.resume(returning: -1)
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        processBox.value = nil

        if let error = launchError.value {
            throw CommandError.launchFailed(error.localizedDescription)
        }

        // Drain whatever landed between the last read and exit.
        if let rest = try? outPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            let chunk = CommandRunner.sanitize(String(decoding: rest, as: UTF8.self))
            if !chunk.isEmpty {
                lock.lock()
                collected.value += chunk
                lock.unlock()
                onOutput?(chunk)
            }
        }

        lock.lock()
        let output = collected.value
        lock.unlock()
        return CommandResult(exitCode: exitCode, output: output)
    }

    func cancel() {
        processBox.value?.terminate()
    }

    /// Strips the EOF marker a pty echoes back. Backspaces and carriage returns are
    /// preserved — TerminalBuffer applies their semantics to rebuild display lines.
    static func sanitize(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{04}", with: "")

    }
}

/// Handles the one privileged step. libusb must claim the USB interface to talk to
/// the bootloader, and macOS only permits that as root.
///
/// An earlier design validated the password once with `sudo -v` and then ran everything
/// with `sudo -n`. That cannot work here: sudo's credential cache is scoped per
/// terminal ("one time stamp record is used for each terminal"), and every command runs
/// under its own freshly allocated pty — so the warmed credential was never visible to
/// the command that needed it, and `sudo -n`, which by design cannot prompt, failed
/// immediately.
///
/// Instead the password is held in memory for the session and written to each elevated
/// command's stdin. It is never written to disk or the Keychain, and is dropped when the
/// app quits or `forget()` is called.
@MainActor
enum PrivilegeBroker {
    private static var cachedPassword: String?

    static var hasPassword: Bool { cachedPassword != nil }

    static func password() -> String? { cachedPassword }

    /// Confirms the password is accepted before it's used for anything destructive.
    static func validateAndStore(_ password: String) async -> Bool {
        let result = try? await CommandRunner().run(
            executable: "/usr/bin/true",
            elevated: true,
            stdin: password
        )
        let ok = result?.succeeded == true
        if ok { cachedPassword = password }
        return ok
    }

    static func forget() {
        cachedPassword = nil
    }
}
