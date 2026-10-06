import Darwin
import Foundation

struct CodexOwnedProcessResult: Sendable {
    let stdout: String
    let stderr: String
    let terminationStatus: Int32
    let wasTruncated: Bool
}

enum CodexOwnedProcessError: LocalizedError, Equatable {
    case launchFailed(String)
    case timedOut
    case outputLimitExceeded
    case pipeDrainTimedOut
    case inputFailed(String)
    case ioFailed(String)
    case ownershipLost
    case terminationFailed

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message): "Unable to launch command: \(message)"
        case .timedOut: "The command exceeded its time limit."
        case .outputLimitExceeded: "The command exceeded its bounded output limit."
        case .pipeDrainTimedOut: "A command child kept an output pipe open after the command exited."
        case .inputFailed(let message): "Unable to write command input: \(message)"
        case .ioFailed(let message): "Unable to capture command output: \(message)"
        case .ownershipLost: "The command was reaped outside its owner; its outcome could not be confirmed."
        case .terminationFailed: "The command did not finish terminating within its cleanup limit."
        }
    }
}

/// A single owned process group. No global process lookup or temporary capture
/// files are involved. The leader stays unreaped until the final group signal,
/// so its PID cannot be reused as another process's group during cleanup.
final class CodexOwnedProcess: @unchecked Sendable {
    struct Limits: Sendable {
        var timeout: TimeInterval = 30
        var maximumOutputBytes: Int = 4 * 1_024 * 1_024
        var maximumErrorBytes: Int = 128 * 1_024
        var terminationGrace: TimeInterval = 0.5
        var pipeDrainTimeout: TimeInterval = 1
    }

    private let lock = NSLock()
    private var cancelled = false

    static func run(
        executable: String,
        arguments: [String],
        directory: URL,
        stdin: Data? = nil,
        limits: Limits = .init(),
        allowTruncation: Bool = false
    ) async throws -> CodexOwnedProcessResult {
        try Task.checkCancellation()
        let runner = CodexOwnedProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // poll/read/write/waitid are synchronous; never occupy Swift's
                // cooperative executor with subprocess I/O.
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try runner.execute(
                            executable: executable,
                            arguments: arguments,
                            directory: directory,
                            stdin: stdin,
                            limits: limits,
                            allowTruncation: allowTruncation
                        )
                    })
                }
            }
        } onCancel: {
            runner.lock.withLock { runner.cancelled = true }
        }
    }

    private func execute(
        executable: String,
        arguments: [String],
        directory: URL,
        stdin: Data?,
        limits: Limits,
        allowTruncation: Bool
    ) throws -> CodexOwnedProcessResult {
        precondition(limits.timeout > 0 && limits.timeout.isFinite)
        precondition(limits.maximumOutputBytes >= 0 && limits.maximumErrorBytes >= 0)
        precondition(limits.terminationGrace >= 0 && limits.terminationGrace.isFinite)
        precondition(limits.pipeDrainTimeout > 0 && limits.pipeDrainTimeout.isFinite)
        if lock.withLock({ cancelled }) { throw CancellationError() }

        var descriptors: [Int32] = []
        defer { descriptors.forEach { _ = Darwin.close($0) } }
        func makePipe() throws -> (read: Int32, write: Int32) {
            var pair: [Int32] = [0, 0]
            guard Darwin.pipe(&pair) == 0 else { throw Self.systemError() }
            for index in pair.indices where pair[index] < 3 {
                let replacement = fcntl(pair[index], F_DUPFD_CLOEXEC, 3)
                guard replacement >= 0 else {
                    pair.forEach { _ = Darwin.close($0) }
                    throw Self.systemError()
                }
                _ = Darwin.close(pair[index])
                pair[index] = replacement
            }
            descriptors.append(contentsOf: pair)
            for descriptor in pair {
                guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1 else { throw Self.systemError() }
            }
            return (pair[0], pair[1])
        }
        func closeDescriptor(_ descriptor: Int32) {
            guard let index = descriptors.firstIndex(of: descriptor) else { return }
            _ = Darwin.close(descriptor)
            descriptors.remove(at: index)
        }

        let output = try makePipe()
        let error = try makePipe()
        let input = try stdin.map { _ in try makePipe() }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try Self.check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try Self.check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try Self.check(posix_spawn_file_actions_addchdir(&actions, directory.path))
        try Self.check(posix_spawn_file_actions_adddup2(&actions, output.write, STDOUT_FILENO))
        try Self.check(posix_spawn_file_actions_adddup2(&actions, error.write, STDERR_FILENO))
        if let input {
            try Self.check(posix_spawn_file_actions_adddup2(&actions, input.read, STDIN_FILENO))
        } else {
            try Self.check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        }
        for descriptor in descriptors {
            try Self.check(posix_spawn_file_actions_addclose(&actions, descriptor))
        }
        var mask = sigset_t()
        sigemptyset(&mask)
        try Self.check(posix_spawnattr_setsigmask(&attributes, &mask))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGINT, SIGTERM, SIGPIPE] { sigaddset(&defaults, signal) }
        try Self.check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try Self.check(posix_spawnattr_setpgroup(&attributes, 0))
        try Self.check(posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)
        ))

        let strings = [executable] + arguments
        var argv = strings.map { strdup($0) } + [nil]
        var environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            environment.forEach { free($0) }
        }
        var pid: pid_t = 0
        // Cancellation is sticky and this lock makes the check and launch one
        // operation. A cancellation arriving during spawn is observed below.
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try Self.check(posix_spawnp(&pid, executable, &actions, &attributes, &argv, &environment))
        }
        defer {
            var status: Int32 = 0
            var reaped: pid_t
            repeat { reaped = waitpid(pid, &status, WNOHANG) } while reaped == -1 && errno == EINTR
            if reaped == 0 {
                // SIGKILL normally finishes immediately. If kernel teardown is
                // delayed, return within the deadline and retain sole reaping
                // responsibility on a non-cooperative worker.
                let ownedPID = pid
                DispatchQueue.global(qos: .utility).async {
                    var status: Int32 = 0
                    while waitpid(ownedPID, &status, 0) == -1 && errno == EINTR {}
                }
            }
        }
        closeDescriptor(output.write)
        closeDescriptor(error.write)
        if let input { closeDescriptor(input.read) }
        for descriptor in [output.read, error.read] + (input.map { [$0.write] } ?? []) {
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else {
                _ = kill(-pid, SIGKILL)
                throw CodexOwnedProcessError.ioFailed(String(cString: strerror(errno)))
            }
        }
        if let input {
            guard fcntl(input.write, F_SETNOSIGPIPE, 1) != -1 else {
                _ = kill(-pid, SIGKILL)
                throw CodexOwnedProcessError.inputFailed(String(cString: strerror(errno)))
            }
        }

        let clock = ContinuousClock()
        let started = clock.now
        var leaderExitedAt: ContinuousClock.Instant?
        var stoppedAt: ContinuousClock.Instant?
        var killedAt: ContinuousClock.Instant?
        var failure: Error?
        var truncated = false
        var canReturnTruncatedOutput = false
        var stdout = Data()
        var stderr = Data()
        var inputOffset = 0
        var outputOpen = true
        var errorOpen = true
        var inputOpen = input != nil
        var status: Int32 = 0

        func stop(_ error: Error) {
            guard stoppedAt == nil else { return }
            failure = error
            stoppedAt = clock.now
            _ = kill(-pid, SIGTERM)
        }
        func elapsed(_ instant: ContinuousClock.Instant) -> TimeInterval {
            let components = instant.duration(to: clock.now).components
            return Double(components.seconds) + Double(components.attoseconds) / 1e18
        }
        func drain(_ descriptor: Int32, into data: inout Data, limit: Int, open: inout Bool, isOutput: Bool) {
            // One bounded chunk per stream per iteration prevents a continuous
            // stdout producer from starving stderr, cancellation or deadlines.
            var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let remaining = max(0, limit - data.count)
                data.append(contentsOf: buffer.prefix(min(count, remaining)))
                if count > remaining {
                    truncated = true
                    if stoppedAt == nil { canReturnTruncatedOutput = isOutput }
                    if !isOutput { canReturnTruncatedOutput = false }
                    stop(CodexOwnedProcessError.outputLimitExceeded)
                }
            } else if count == 0 {
                open = false
                closeDescriptor(descriptor)
            } else if errno != EAGAIN && errno != EINTR {
                stop(CodexOwnedProcessError.ioFailed(String(cString: strerror(errno))))
                open = false
                closeDescriptor(descriptor)
            }
        }

        while true {
            var info = siginfo_t()
            // WNOWAIT preserves ownership of the group ID until all signals
            // and pipe cleanup finish, including a child retaining a pipe.
            let observed = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if observed == -1 && errno == ECHILD {
                // A host-wide reaper must not cause this runner to signal a
                // potentially reused group ID. Close only our descriptors.
                throw CodexOwnedProcessError.ownershipLost
            }
            if leaderExitedAt == nil && observed == 0 && info.si_pid == pid {
                leaderExitedAt = clock.now
                status = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
            }
            if lock.withLock({ cancelled }) { stop(CancellationError()) }
            // Observe an already exited leader before checking elapsed time:
            // scheduler delay must not discard a completed command's bytes.
            if leaderExitedAt == nil && elapsed(started) >= limits.timeout { stop(CodexOwnedProcessError.timedOut) }
            if let leaderExitedAt, (outputOpen || errorOpen),
               elapsed(leaderExitedAt) >= limits.pipeDrainTimeout {
                stop(CodexOwnedProcessError.pipeDrainTimedOut)
            }
            if let stoppedAt, killedAt == nil, elapsed(stoppedAt) >= limits.terminationGrace {
                _ = kill(-pid, SIGKILL)
                killedAt = clock.now
            }
            if outputOpen { drain(output.read, into: &stdout, limit: limits.maximumOutputBytes, open: &outputOpen, isOutput: true) }
            if errorOpen { drain(error.read, into: &stderr, limit: limits.maximumErrorBytes, open: &errorOpen, isOutput: false) }
            if let input, inputOpen {
                if let stdin, inputOffset < stdin.count, stoppedAt == nil, leaderExitedAt == nil {
                    let count = stdin.withUnsafeBytes { bytes in
                        Darwin.write(input.write, bytes.baseAddress!.advanced(by: inputOffset), min(16 * 1_024, stdin.count - inputOffset))
                    }
                    if count > 0 {
                        inputOffset += count
                    } else if count == -1 && errno != EAGAIN && errno != EINTR {
                        stop(CodexOwnedProcessError.inputFailed(String(cString: strerror(errno))))
                    }
                }
                if inputOffset == stdin?.count || stoppedAt != nil || leaderExitedAt != nil {
                    inputOpen = false
                    closeDescriptor(input.write)
                }
            }
            if leaderExitedAt != nil && !outputOpen && !errorOpen {
                // A stopped leader can leave a TERM-ignoring child after its
                // pipes close. Complete escalation before releasing ownership.
                if stoppedAt != nil && killedAt == nil { _ = kill(-pid, SIGKILL) }
                break
            }
            if let killedAt, elapsed(killedAt) >= limits.pipeDrainTimeout {
                if leaderExitedAt == nil { failure = CodexOwnedProcessError.terminationFailed }
                break
            }
            var pollDescriptors = [pollfd]()
            if outputOpen { pollDescriptors.append(pollfd(fd: output.read, events: Int16(POLLIN), revents: 0)) }
            if errorOpen { pollDescriptors.append(pollfd(fd: error.read, events: Int16(POLLIN), revents: 0)) }
            if let input, inputOpen { pollDescriptors.append(pollfd(fd: input.write, events: Int16(POLLOUT), revents: 0)) }
            _ = poll(&pollDescriptors, nfds_t(pollDescriptors.count), 10)
        }
        if lock.withLock({ cancelled }) { throw CancellationError() }
        if let failure {
            if !(allowTruncation && canReturnTruncatedOutput && (failure as? CodexOwnedProcessError) == .outputLimitExceeded) { throw failure }
        }
        return .init(
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self),
            terminationStatus: status,
            wasTruncated: truncated
        )
    }

    private static func check(_ code: Int32) throws {
        guard code == 0 else { throw CodexOwnedProcessError.launchFailed(String(cString: strerror(code))) }
    }

    private static func systemError() -> CodexOwnedProcessError {
        .launchFailed(String(cString: strerror(errno)))
    }
}
