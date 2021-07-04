/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import class Foundation.ProcessInfo
import protocol Foundation.CustomNSError
import var Foundation.NSLocalizedDescriptionKey

#if os(Windows)
import Foundation
#endif

@_implementationOnly import TSCclibc
import TSCLibc
import Dispatch

/// Process result data which is available after process termination.
public struct ProcessResult: CustomStringConvertible {

    public enum Error: Swift.Error {
        /// The output is not a valid UTF8 sequence.
        case illegalUTF8Sequence

        /// The process had a non zero exit.
        case nonZeroExit(ProcessResult)
    }

    public enum ExitStatus: Equatable {
        /// The process was terminated normally with a exit code.
        case terminated(code: Int32)
#if !os(Windows)
        /// The process was terminated due to a signal.
        case signalled(signal: Int32)
#endif
    }

    /// The arguments with which the process was launched.
    public let arguments: [String]

    /// The environment with which the process was launched.
    public let environment: [String: String]

    /// The exit status of the process.
    public let exitStatus: ExitStatus

    /// The output bytes of the process. Available only if the process was
    /// asked to redirect its output and no stdout output closure was set.
    public let output: Result<[UInt8], Swift.Error>

    /// The output bytes of the process. Available only if the process was
    /// asked to redirect its output and no stderr output closure was set.
    public let stderrOutput: Result<[UInt8], Swift.Error>

    /// Create an instance using a POSIX process exit status code and output result.
    ///
    /// See `waitpid(2)` for information on the exit status code.
    public init(
        arguments: [String],
        environment: [String: String],
        exitStatusCode: Int32,
        output: Result<[UInt8], Swift.Error>,
        stderrOutput: Result<[UInt8], Swift.Error>
    ) {
        let exitStatus: ExitStatus
      #if os(Windows)
        exitStatus = .terminated(code: exitStatusCode)
      #else
        if WIFSIGNALED(exitStatusCode) {
            exitStatus = .signalled(signal: WTERMSIG(exitStatusCode))
        } else {
            precondition(WIFEXITED(exitStatusCode), "unexpected exit status \(exitStatusCode)")
            exitStatus = .terminated(code: WEXITSTATUS(exitStatusCode))
        }
      #endif
        self.init(arguments: arguments, environment: environment, exitStatus: exitStatus, output: output,
            stderrOutput: stderrOutput)
    }

    /// Create an instance using an exit status and output result.
    public init(
        arguments: [String],
        environment: [String: String],
        exitStatus: ExitStatus,
        output: Result<[UInt8], Swift.Error>,
        stderrOutput: Result<[UInt8], Swift.Error>
    ) {
        self.arguments = arguments
        self.environment = environment
        self.output = output
        self.stderrOutput = stderrOutput
        self.exitStatus = exitStatus
    }

    /// Converts stdout output bytes to string, assuming they're UTF8.
    public func utf8Output() throws -> String {
        return String(decoding: try output.get(), as: Unicode.UTF8.self)
    }

    /// Converts stderr output bytes to string, assuming they're UTF8.
    public func utf8stderrOutput() throws -> String {
        return String(decoding: try stderrOutput.get(), as: Unicode.UTF8.self)
    }

    public var description: String {
        return """
            <ProcessResult: exit: \(exitStatus), output:
             \((try? utf8Output()) ?? "")
            >
            """
    }
}

/// Process allows spawning new subprocesses and working with them.
///
/// Note: This class is thread safe.
public final class Process: ObjectIdentifierProtocol {

    /// Errors when attempting to invoke a process
    public enum Error: Swift.Error {
        /// The program requested to be executed cannot be found on the existing search paths, or is not executable.
        case missingExecutableProgram(program: String)

        /// The current OS does not support the workingDirectory API.
        case workingDirectoryNotSupported
    }

    public enum OutputRedirection {
        /// Do not redirect the output
        case none
        /// Collect stdout and stderr output and provide it back via ProcessResult object. If redirectStderr is true,
        /// stderr be redirected to stdout.
        case collect(redirectStderr: Bool)
        /// Stream stdout and stderr via the corresponding closures. If redirectStderr is true, stderr be redirected to
        /// stdout.
        case stream(stdout: OutputClosure, stderr: OutputClosure, redirectStderr: Bool)

        /// Default collect OutputRedirection that defaults to not redirect stderr. Provided for API compatibility.
        public static let collect: OutputRedirection = .collect(redirectStderr: false)

        /// Default stream OutputRedirection that defaults to not redirect stderr. Provided for API compatibility.
        public static func stream(stdout: @escaping OutputClosure, stderr: @escaping OutputClosure) -> Self {
            return .stream(stdout: stdout, stderr: stderr, redirectStderr: false)
        }

        public var redirectsOutput: Bool {
            switch self {
            case .none:
                return false
            case .collect, .stream:
                return true
            }
        }

        public var outputClosures: (stdoutClosure: OutputClosure, stderrClosure: OutputClosure)? {
            switch self {
            case let .stream(stdoutClosure, stderrClosure, _):
                return (stdoutClosure: stdoutClosure, stderrClosure: stderrClosure)
            case .collect, .none:
                return nil
            }
        }

        public var redirectStderr: Bool {
            switch self {
            case let .collect(redirectStderr):
                return redirectStderr
            case let .stream(_, _, redirectStderr):
                return redirectStderr
            default:
                return false
            }
        }
    }

    // process execution mutable state
    private enum State {
        case idle
        case readingOutputThread(stdout: Thread, stderr: Thread?)
        case readingOutputPipe(sync: DispatchGroup)
        case outputReady(stdout: Result<[UInt8], Swift.Error>, stderr: Result<[UInt8], Swift.Error>)
        case complete(ProcessResult)
    }

    /// Typealias for process id type.
  #if !os(Windows)
    public typealias ProcessID = pid_t
  #else
    public typealias ProcessID = DWORD
  #endif

    /// Typealias for stdout/stderr output closure.
    public typealias OutputClosure = ([UInt8]) -> Void

    /// Global default setting for verbose.
    public static var verbose = false

    /// If true, prints the subprocess arguments before launching it.
    public let verbose: Bool

    /// The current environment.
    @available(*, deprecated, message: "use ProcessEnv.vars instead")
    static public var env: [String: String] {
        return ProcessInfo.processInfo.environment
    }

    /// The arguments to execute.
    public let arguments: [String]

    /// The environment with which the process was executed.
    public let environment: [String: String]

    /// The path to the directory under which to run the process.
    public let workingDirectory: AbsolutePath?

    /// The process id of the spawned process, available after the process is launched.
  #if os(Windows)
    private var _process: Foundation.Process?
    public var processID: ProcessID {
        return DWORD(_process?.processIdentifier ?? 0)
    }
  #else
    public private(set) var processID = ProcessID()
  #endif

    // process execution mutable state
    private var state: State = .idle
    private let stateLock = Lock()

    /// The result of the process execution. Available after process is terminated.
    /// This will block while the process is awaiting result
    @available(*, deprecated, message: "use waitUntilExit instead")
    public var result: ProcessResult? {
        return self.stateLock.withLock {
            switch self.state {
            case .complete(let result):
                return result
            default:
                return nil
            }
        }
    }

    // ideally we would use the state for this, but we need to access it while the waitForExit is locking state
    private var _launched = false
    private let launchedLock = Lock()

    public var launched: Bool {
        return self.launchedLock.withLock {
            return self._launched
        }
    }

    /// How process redirects its output.
    public let outputRedirection: OutputRedirection

    /// Indicates if a new progress group is created for the child process.
    private let startNewProcessGroup: Bool

    /// Cache of validated executables.
    ///
    /// Key: Executable name or path.
    /// Value: Path to the executable, if found.
    private static var validatedExecutablesMap = [String: AbsolutePath?]()
    private static let validatedExecutablesMapLock = Lock()

    /// Create a new process instance.
    ///
    /// - Parameters:
    ///   - arguments: The arguments for the subprocess.
    ///   - environment: The environment to pass to subprocess. By default the current process environment
    ///     will be inherited.
    ///   - workingDirectory: The path to the directory under which to run the process.
    ///   - outputRedirection: How process redirects its output. Default value is .collect.
    ///   - verbose: If true, launch() will print the arguments of the subprocess before launching it.
    ///   - startNewProcessGroup: If true, a new progress group is created for the child making it
    ///     continue running even if the parent is killed or interrupted. Default value is true.
    @available(macOS 10.15, *)
    public init(
        arguments: [String],
        environment: [String: String] = ProcessEnv.vars,
        workingDirectory: AbsolutePath,
        outputRedirection: OutputRedirection = .collect,
        verbose: Bool = Process.verbose,
        startNewProcessGroup: Bool = true
    ) {
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.outputRedirection = outputRedirection
        self.verbose = verbose
        self.startNewProcessGroup = startNewProcessGroup
    }

    /// Create a new process instance.
    ///
    /// - Parameters:
    ///   - arguments: The arguments for the subprocess.
    ///   - environment: The environment to pass to subprocess. By default the current process environment
    ///     will be inherited.
    ///   - outputRedirection: How process redirects its output. Default value is .collect.
    ///   - verbose: If true, launch() will print the arguments of the subprocess before launching it.
    ///   - startNewProcessGroup: If true, a new progress group is created for the child making it
    ///     continue running even if the parent is killed or interrupted. Default value is true.
    public init(
        arguments: [String],
        environment: [String: String] = ProcessEnv.vars,
        outputRedirection: OutputRedirection = .collect,
        verbose: Bool = Process.verbose,
        startNewProcessGroup: Bool = true
    ) {
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = nil
        self.outputRedirection = outputRedirection
        self.verbose = verbose
        self.startNewProcessGroup = startNewProcessGroup
    }

    /// Returns the path of the the given program if found in the search paths.
    ///
    /// The program can be executable name, relative path or absolute path.
    public static func findExecutable(
        _ program: String,
        workingDirectory: AbsolutePath? = nil
    ) -> AbsolutePath? {
        if let abs = try? AbsolutePath(validating: program) {
            return abs
        }
        let cwdOpt = workingDirectory ?? localFileSystem.currentWorkingDirectory
        // The program might be a multi-component relative path.
        if let rel = try? RelativePath(validating: program), rel.components.count > 1 {
            if let cwd = cwdOpt {
                let abs = cwd.appending(rel)
                if localFileSystem.isExecutableFile(abs) {
                    return abs
                }
            }
            return nil
        }
        // From here on out, the program is an executable name, i.e. it doesn't contain a "/"
        let lookup: () -> AbsolutePath? = {
            let envSearchPaths = getEnvSearchPaths(
                pathString: ProcessEnv.path,
                currentWorkingDirectory: cwdOpt
            )
            let value = lookupExecutablePath(
                filename: program,
                currentWorkingDirectory: cwdOpt,
                searchPaths: envSearchPaths
            )
            return value
        }
        // This should cover the most common cases, i.e. when the cache is most helpful.
        if workingDirectory == localFileSystem.currentWorkingDirectory {
            return Process.validatedExecutablesMapLock.withLock {
                if let value = Process.validatedExecutablesMap[program] {
                    return value
                }
                let value = lookup()
                Process.validatedExecutablesMap[program] = value
                return value
            }
        } else {
            return lookup()
        }
    }

    /// Launch the subprocess. Returns a WritableByteStream object that can be used to communicate to the process's
    /// stdin. If needed, the stream can be closed using the close() API. Otherwise, the stream will be closed
    /// automatically.
    @discardableResult
    public func launch() throws -> WritableByteStream {
        precondition(arguments.count > 0 && !arguments[0].isEmpty, "Need at least one argument to launch the process.")

        self.launchedLock.withLock {
            precondition(!self._launched, "It is not allowed to launch the same process object again.")
            self._launched = true
        }

        // Print the arguments if we are verbose.
        if self.verbose {
            stdoutStream <<< arguments.map({ $0.spm_shellEscaped() }).joined(separator: " ") <<< "\n"
            stdoutStream.flush()
        }

        // Look for executable.
        let executable = arguments[0]
        guard let executablePath = Process.findExecutable(executable, workingDirectory: workingDirectory) else {
            throw Process.Error.missingExecutableProgram(program: executable)
        }

    #if DISABLE_POSIX_SPAWNP
        preconditionFailure("POSIX spawnp not available on this system.")
    #else
      #if os(Windows)
        _process = Foundation.Process()
        _process?.arguments = Array(arguments.dropFirst()) // Avoid including the executable URL twice.
        _process?.executableURL = executablePath.asURL
        _process?.environment = environment

        let stdinPipe = Pipe()
        _process?.standardInput = stdinPipe

        let group = DispatchGroup()

        var stdout: [UInt8] = []
        let stdoutLock = Lock()

        var stderr: [UInt8] = []
        let stderrLock = Lock()

        if outputRedirection.redirectsOutput {
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            group.enter()
            stdoutPipe.fileHandleForReading.readabilityHandler = { (fh : FileHandle) -> Void in
                let data = fh.availableData
                if (data.count == 0) {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    group.leave()
                } else {
                    let contents = data.withUnsafeBytes { Array<UInt8>($0) }
                    self.outputRedirection.outputClosures?.stdoutClosure(contents)
                    stdoutLock.withLock {
                        stdout += contents
                    }
                }
            }

            group.enter()
            stderrPipe.fileHandleForReading.readabilityHandler = { (fh : FileHandle) -> Void in
                let data = fh.availableData
                if (data.count == 0) {
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    group.leave()
                } else {
                    let contents = data.withUnsafeBytes { Array<UInt8>($0) }
                    self.outputRedirection.outputClosures?.stderrClosure(contents)
                    stderrLock.withLock {
                        stderr += contents
                    }
                }
            }

            _process?.standardOutput = stdoutPipe
            _process?.standardError = stderrPipe
        }

        // first set state then start reading threads
        let sync = DispatchGroup()
        sync.enter()
        self.stateLock.withLock {
            self.state = .readingOutputPipe(sync: sync)
        }

        group.notify(queue: .global()) {
            self.stateLock.withLock {
                self.state = .outputReady(stdout: .success(stdout), stderr: .success(stderr))
            }
            sync.leave()
        }

        try _process?.run()
        return stdinPipe.fileHandleForWriting
    #else
        // Initialize the spawn attributes.
      #if canImport(Darwin) || os(Android) || os(OpenBSD)
        var attributes: posix_spawnattr_t? = nil
      #else
        var attributes = posix_spawnattr_t()
      #endif
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // Unmask all signals.
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        // Reset all signals to default behavior.
      #if os(macOS)
        var mostSignals = sigset_t()
        sigfillset(&mostSignals)
        sigdelset(&mostSignals, SIGKILL)
        sigdelset(&mostSignals, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &mostSignals)
      #else
        // On Linux, this can only be used to reset signals that are legal to
        // modify, so we have to take care about the set we use.
        var mostSignals = sigset_t()
        sigemptyset(&mostSignals)
        for i in 1 ..< SIGSYS {
            if i == SIGKILL || i == SIGSTOP {
                continue
            }
            sigaddset(&mostSignals, i)
        }
        posix_spawnattr_setsigdefault(&attributes, &mostSignals)
      #endif

        // Set the attribute flags.
        var flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        if startNewProcessGroup {
            // Establish a separate process group.
            flags |= POSIX_SPAWN_SETPGROUP
            posix_spawnattr_setpgroup(&attributes, 0)
        }

        posix_spawnattr_setflags(&attributes, Int16(flags))

        // Setup the file actions.
      #if canImport(Darwin) || os(Android) || os(OpenBSD)
        var fileActions: posix_spawn_file_actions_t? = nil
      #else
        var fileActions = posix_spawn_file_actions_t()
      #endif
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        if let workingDirectory = workingDirectory?.pathString {
          #if os(macOS)
            // The only way to set a workingDirectory is using an availability-gated initializer, so we don't need
            // to handle the case where the posix_spawn_file_actions_addchdir_np method is unavailable. This check only
            // exists here to make the compiler happy.
            if #available(macOS 10.15, *) {
                posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)
            }
          #elseif os(Linux)
            guard SPM_posix_spawn_file_actions_addchdir_np_supported() else {
                throw Process.Error.workingDirectoryNotSupported
            }

            SPM_posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)
          #else
            throw Process.Error.workingDirectoryNotSupported
          #endif
        }

        var stdinPipe: [Int32] = [-1, -1]
        try open(pipe: &stdinPipe)

        let stdinStream = try LocalFileOutputByteStream(filePointer: fdopen(stdinPipe[1], "wb"), closeOnDeinit: true)

        // Dupe the read portion of the remote to 0.
        posix_spawn_file_actions_adddup2(&fileActions, stdinPipe[0], 0)

        // Close the other side's pipe since it was dupped to 0.
        posix_spawn_file_actions_addclose(&fileActions, stdinPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, stdinPipe[1])

        var outputPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        if outputRedirection.redirectsOutput {
            // Open the pipe.
            try open(pipe: &outputPipe)

            // Open the write end of the pipe.
            posix_spawn_file_actions_adddup2(&fileActions, outputPipe[1], 1)

            // Close the other ends of the pipe since they were dupped to 1.
            posix_spawn_file_actions_addclose(&fileActions, outputPipe[0])
            posix_spawn_file_actions_addclose(&fileActions, outputPipe[1])

            if outputRedirection.redirectStderr {
                // If merged was requested, send stderr to stdout.
                posix_spawn_file_actions_adddup2(&fileActions, 1, 2)
            } else {
                // If no redirect was requested, open the pipe for stderr.
                try open(pipe: &stderrPipe)
                posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], 2)

                // Close the other ends of the pipe since they were dupped to 2.
                posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0])
                posix_spawn_file_actions_addclose(&fileActions, stderrPipe[1])
            }
        } else {
            posix_spawn_file_actions_adddup2(&fileActions, 1, 1)
            posix_spawn_file_actions_adddup2(&fileActions, 2, 2)
        }

        var resolvedArgs = arguments
        if workingDirectory != nil {
            resolvedArgs[0] = executablePath.pathString
        }
        let argv = CStringArray(resolvedArgs)
        let env = CStringArray(environment.map({ "\($0.0)=\($0.1)" }))
        let rv = posix_spawnp(&processID, argv.cArray[0]!, &fileActions, &attributes, argv.cArray, env.cArray)

        guard rv == 0 else {
            throw SystemError.posix_spawn(rv, arguments)
        }

        // Close the local read end of the input pipe.
        try close(fd: stdinPipe[0])

        if !outputRedirection.redirectsOutput {
            // no stdout or stderr in this case
            self.stateLock.withLock {
                self.state = .outputReady(stdout: .success([]), stderr: .success([]))
            }
        } else {
            var pending: Result<[UInt8], Swift.Error>?
            let pendingLock = Lock()

            let outputClosures = outputRedirection.outputClosures

            // Close the local write end of the output pipe.
            try close(fd: outputPipe[1])

            // Create a thread and start reading the output on it.
            let stdoutThread = Thread { [weak self] in
                if let readResult = self?.readOutput(onFD: outputPipe[0], outputClosure: outputClosures?.stdoutClosure) {
                    pendingLock.withLock {
                        if let stderrResult = pending {
                            self?.stateLock.withLock {
                                self?.state = .outputReady(stdout: readResult, stderr: stderrResult)
                            }
                        } else  {
                            pending = readResult
                        }
                    }
                } else if let stderrResult = (pendingLock.withLock { pending }) {
                    // TODO: this is more of an error
                    self?.stateLock.withLock {
                        self?.state = .outputReady(stdout: .success([]), stderr: stderrResult)
                    }
                }
            }

            // Only schedule a thread for stderr if no redirect was requested.
            var stderrThread: Thread? = nil
            if !outputRedirection.redirectStderr {
                // Close the local write end of the stderr pipe.
                try close(fd: stderrPipe[1])

                // Create a thread and start reading the stderr output on it.
                stderrThread = Thread { [weak self] in
                    if let readResult = self?.readOutput(onFD: stderrPipe[0], outputClosure: outputClosures?.stderrClosure) {
                        pendingLock.withLock {
                            if let stdoutResult = pending {
                                self?.stateLock.withLock {
                                    self?.state = .outputReady(stdout: stdoutResult, stderr: readResult)
                                }
                            } else {
                                pending = readResult
                            }
                        }
                    } else if let stdoutResult = (pendingLock.withLock { pending }) {
                        // TODO: this is more of an error
                        self?.stateLock.withLock {
                            self?.state = .outputReady(stdout: stdoutResult, stderr: .success([]))
                        }
                    }
                }
            } else {
                pendingLock.withLock {
                    pending = .success([])  // no stderr in this case
                }
            }
            // first set state then start reading threads
            self.stateLock.withLock {
                self.state = .readingOutputThread(stdout: stdoutThread, stderr: stderrThread)
            }
            stdoutThread.start()
            stderrThread?.start()
        }

        return stdinStream
    #endif // POSIX implementation
    #endif // DISABLE_POSIX_SPAWNP
    }

    /// Blocks the calling process until the subprocess finishes execution.
    @discardableResult
    public func waitUntilExit() throws -> ProcessResult {
        self.stateLock.lock()
        switch self.state {
        case .idle:
            defer { self.stateLock.unlock() }
            preconditionFailure("The process is not yet launched.")
        case .complete(let result):
            defer { self.stateLock.unlock() }
            return result
        case .readingOutputThread(let stdoutThread, let stderrThread):
            self.stateLock.unlock() // unlock early since output read thread need to change state
            // If we're reading output, make sure that is finished.
            stdoutThread.join()
            stderrThread?.join()
            return try self.waitUntilExit()
        case .readingOutputPipe(let sync):
            self.stateLock.unlock() // unlock early since output read thread need to change state
            sync.wait()
            return try self.waitUntilExit()
        case .outputReady(let stdoutResult, let stderrResult):
            defer { self.stateLock.unlock() }
            // Wait until process finishes execution.
          #if os(Windows)
            precondition(_process != nil, "The process is not yet launched.")
            let p = _process!
            p.waitUntilExit()
            let exitStatusCode = p.terminationStatus
          #else
            var exitStatusCode: Int32 = 0
            var result = waitpid(processID, &exitStatusCode, 0)
            while result == -1 && errno == EINTR {
                result = waitpid(processID, &exitStatusCode, 0)
            }
            if result == -1 {
                throw SystemError.waitpid(errno)
            }
          #endif

            // Construct the result.
            let executionResult = ProcessResult(
                arguments: arguments,
                environment: environment,
                exitStatusCode: exitStatusCode,
                output: stdoutResult,
                stderrOutput: stderrResult
            )
            self.state = .complete(executionResult)
            return executionResult
        }
    }

  #if !os(Windows)
    /// Reads the given fd and returns its result.
    ///
    /// Closes the fd before returning.
    private func readOutput(onFD fd: Int32, outputClosure: OutputClosure?) -> Result<[UInt8], Swift.Error> {
        // Read all of the data from the output pipe.
        let N = 4096
        var buf = [UInt8](repeating: 0, count: N + 1)

        var out = [UInt8]()
        var error: Swift.Error? = nil
        loop: while true {
            let n = read(fd, &buf, N)
            switch n {
            case  -1:
                if errno == EINTR {
                    continue
                } else {
                    error = SystemError.read(errno)
                    break loop
                }
            case 0:
                // Close the read end of the output pipe.
                // We should avoid closing the read end of the pipe in case
                // -1 because the child process may still have content to be
                // flushed into the write end of the pipe. If the read end of the
                // pipe is closed, then a write will cause a SIGPIPE signal to
                // be generated for the calling process.  If the calling process is
                // ignoring this signal, then write fails with the error EPIPE.
                close(fd)
                break loop
            default:
                let data = buf[0..<n]
                if let outputClosure = outputClosure {
                    outputClosure(Array(data))
                } else {
                    out += data
                }
            }
        }
        // Construct the output result.
        return error.map(Result.failure) ?? .success(out)
    }
  #endif

    /// Send a signal to the process.
    ///
    /// Note: This will signal all processes in the process group.
    public func signal(_ signal: Int32) {
      #if os(Windows)
        if signal == SIGINT {
            _process?.interrupt()
        } else {
            _process?.terminate()
        }
      #else
        assert(self.launched, "The process is not yet launched.")
        _ = TSCLibc.kill(startNewProcessGroup ? -processID : processID, signal)
      #endif
    }
}

extension Process {
    /// Execute a subprocess and block until it finishes execution
    ///
    /// - Parameters:
    ///   - arguments: The arguments for the subprocess.
    ///   - environment: The environment to pass to subprocess. By default the current process environment
    ///     will be inherited.
    /// - Returns: The process result.
    @discardableResult
    static public func popen(arguments: [String], environment: [String: String] = ProcessEnv.vars) throws -> ProcessResult {
        let process = Process(arguments: arguments, environment: environment, outputRedirection: .collect)
        try process.launch()
        return try process.waitUntilExit()
    }

    @discardableResult
    static public func popen(args: String..., environment: [String: String] = ProcessEnv.vars) throws -> ProcessResult {
        return try Process.popen(arguments: args, environment: environment)
    }

    /// Execute a subprocess and get its (UTF-8) output if it has a non zero exit.
    ///
    /// - Parameters:
    ///   - arguments: The arguments for the subprocess.
    ///   - environment: The environment to pass to subprocess. By default the current process environment
    ///     will be inherited.
    /// - Returns: The process output (stdout + stderr).
    @discardableResult
    static public func checkNonZeroExit(arguments: [String], environment: [String: String] = ProcessEnv.vars) throws -> String {
        let process = Process(arguments: arguments, environment: environment, outputRedirection: .collect)
        try process.launch()
        let result = try process.waitUntilExit()
        // Throw if there was a non zero termination.
        guard result.exitStatus == .terminated(code: 0) else {
            throw ProcessResult.Error.nonZeroExit(result)
        }
        return try result.utf8Output()
    }

    @discardableResult
    static public func checkNonZeroExit(args: String..., environment: [String: String] = ProcessEnv.vars) throws -> String {
        return try checkNonZeroExit(arguments: args, environment: environment)
    }

    public convenience init(args: String..., environment: [String: String] = ProcessEnv.vars, outputRedirection: OutputRedirection = .collect) {
        self.init(arguments: args, environment: environment, outputRedirection: outputRedirection)
    }
}

// MARK: - Private helpers

#if !os(Windows)
#if os(macOS)
private typealias swiftpm_posix_spawn_file_actions_t = posix_spawn_file_actions_t?
#else
private typealias swiftpm_posix_spawn_file_actions_t = posix_spawn_file_actions_t
#endif

private func WIFEXITED(_ status: Int32) -> Bool {
    return _WSTATUS(status) == 0
}

private func _WSTATUS(_ status: Int32) -> Int32 {
    return status & 0x7f
}

private func WIFSIGNALED(_ status: Int32) -> Bool {
    return (_WSTATUS(status) != 0) && (_WSTATUS(status) != 0x7f)
}

private func WEXITSTATUS(_ status: Int32) -> Int32 {
    return (status >> 8) & 0xff
}

private func WTERMSIG(_ status: Int32) -> Int32 {
    return status & 0x7f
}

/// Open the given pipe.
private func open(pipe: inout [Int32]) throws {
    let rv = TSCLibc.pipe(&pipe)
    guard rv == 0 else {
        throw SystemError.pipe(rv)
    }
}

/// Close the given fd.
private func close(fd: Int32) throws {
    func innerClose(_ fd: inout Int32) throws {
        let rv = TSCLibc.close(fd)
        guard rv == 0 else {
            throw SystemError.close(rv)
        }
    }
    var innerFd = fd
    try innerClose(&innerFd)
}

extension Process.Error: CustomStringConvertible {
    public var description: String {
        switch self {
        case .missingExecutableProgram(let program):
            return "could not find executable for '\(program)'"
        case .workingDirectoryNotSupported:
            return "workingDirectory is not supported in this platform"
        }
    }
}

extension Process.Error: CustomNSError {
    public var errorUserInfo: [String : Any] {
        return [NSLocalizedDescriptionKey: self.description]
    }
}

#endif

extension ProcessResult.Error: CustomStringConvertible {
    public var description: String {
        switch self {
        case .illegalUTF8Sequence:
            return "illegal UTF8 sequence output"
        case .nonZeroExit(let result):
            let stream = BufferedOutputByteStream()
            switch result.exitStatus {
            case .terminated(let code):
                stream <<< "terminated(\(code)): "
#if !os(Windows)
            case .signalled(let signal):
                stream <<< "signalled(\(signal)): "
#endif
            }

            // Strip sandbox information from arguments to keep things pretty.
            var args = result.arguments
            // This seems a little fragile.
            if args.first == "sandbox-exec", args.count > 3 {
                args = args.suffix(from: 3).map({$0})
            }
            stream <<< args.map({ $0.spm_shellEscaped() }).joined(separator: " ")

            // Include the output, if present.
            if let output = try? result.utf8Output() + result.utf8stderrOutput() {
                // We indent the output to keep it visually separated from everything else.
                let indentation = "    "
                stream <<< " output:\n" <<< indentation <<< output.replacingOccurrences(of: "\n", with: "\n" + indentation)
                if !output.hasSuffix("\n") {
                    stream <<< "\n"
                }
            }

            return stream.bytes.description
        }
    }
}

#if os(Windows)
extension FileHandle: WritableByteStream {
    public var position: Int {
        return Int(offsetInFile)
    }

    public func write(_ byte: UInt8) {
        write(Data([byte]))
    }

    public func write<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        write(Data(bytes))
    }

    public func flush() {
        synchronizeFile()
    }

    public func close() throws {
        closeFile()
    }
}
#endif
