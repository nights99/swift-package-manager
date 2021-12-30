/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basics
import Foundation
import PackageGraph
import PackageModel
import SPMBuildCore
import TSCBasic
import TSCUtility

/// A plugin script runner that compiles the plugin source files as an executable binary for the host platform, and invokes it as a subprocess.
public struct DefaultPluginScriptRunner: PluginScriptRunner {
    let cacheDir: AbsolutePath
    let toolchain: ToolchainConfiguration
    let enableSandbox: Bool

    private static var _hostTriple = ThreadSafeBox<Triple>()
    private static var _packageDescriptionMinimumDeploymentTarget = ThreadSafeBox<String>()
    private let sdkRootCache = ThreadSafeBox<AbsolutePath>()

    public init(cacheDir: AbsolutePath, toolchain: ToolchainConfiguration, enableSandbox: Bool = true) {
        self.cacheDir = cacheDir
        self.toolchain = toolchain
        self.enableSandbox = enableSandbox
    }
    
    /// Public protocol function that starts compiling the plugin script to an exectutable. The tools version controls the availability of APIs in PackagePlugin, and should be set to the tools version of the package that defines the plugin (not of the target to which it is being applied). This function returns immediately and then calls the completion handler on the callbackq queue when compilation ends.
    public func compilePluginScript(
        sources: Sources,
        toolsVersion: ToolsVersion,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<PluginCompilationResult, Error>) -> Void
    ) {
        self.compile(
            sources: sources,
            toolsVersion: toolsVersion,
            cacheDir: self.cacheDir,
            observabilityScope: observabilityScope,
            callbackQueue: callbackQueue,
            completion: completion)
    }

    /// A synchronous version of `compilePluginScript()`.
    public func compilePluginScript(
        sources: Sources,
        toolsVersion: ToolsVersion,
        observabilityScope: ObservabilityScope
    ) throws -> PluginCompilationResult {
        // Call the asynchronous version. In our case we don't care which queue the callback occurs on.
        return try tsc_await { self.compilePluginScript(
            sources: sources,
            toolsVersion: toolsVersion,
            observabilityScope: observabilityScope,
            callbackQueue: DispatchQueue.sharedConcurrent,
            completion: $0)
        }
    }

    /// Public protocol function that starts evaluating a plugin by compiling it and running it as a subprocess. The tools version controls the availability of APIs in PackagePlugin, and should be set to the tools version of the package that defines the plugin (not the package containing the target to which it is being applied). This function returns immediately and then repeated calls the output handler on the given callback queue as plain-text output is received from the plugin, and then eventually calls the completion handler on the given callback queue once the plugin is done.
    public func runPluginScript(
        sources: Sources,
        input: PluginScriptRunnerInput,
        toolsVersion: ToolsVersion,
        writableDirectories: [AbsolutePath],
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        delegate: PluginInvocationDelegate,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        // If needed, compile the plugin script to an executable (asynchronously).
        // TODO: Skip compiling the plugin script if it has already been compiled and hasn't changed.
        self.compile(
            sources: sources,
            toolsVersion: toolsVersion,
            cacheDir: self.cacheDir,
            observabilityScope: observabilityScope,
            callbackQueue: DispatchQueue.sharedConcurrent,
            completion: {
                dispatchPrecondition(condition: .onQueue(DispatchQueue.sharedConcurrent))
                switch $0 {
                case .success(let result):
                    // Compilation succeeded, so run the executable. We are already running on an asynchronous queue.
                    self.invoke(
                        compiledExec: result.compiledExecutable,
                        writableDirectories: writableDirectories,
                        input: input,
                        observabilityScope: observabilityScope,
                        callbackQueue: callbackQueue,
                        delegate: delegate,
                        completion: completion)
                case .failure(let error):
                    // Compilation failed, so just call the callback block on the appropriate queue.
                    callbackQueue.async { completion(.failure(error)) }
                }
            }
        )
    }

    public var hostTriple: Triple {
        return Self._hostTriple.memoize {
            Triple.getHostTriple(usingSwiftCompiler: self.toolchain.swiftCompilerPath)
        }
    }
    
    /// Helper function that starts compiling a plugin script as an executable and when done, calls the completion handler with the path of the executable and with any emitted diagnostics, etc. This function only returns an error if it wasn't even possible to start compiling the plugin — any regular compilation errors or warnings will be reflected in the returned compilation result.
    fileprivate func compile(
        sources: Sources,
        toolsVersion: ToolsVersion,
        cacheDir: AbsolutePath,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<PluginCompilationResult, Error>) -> Void
    ) {
        // FIXME: Much of this is similar to what the ManifestLoader is doing. This should be consolidated.
        do {
            // We could name the executable anything, but using the plugin name makes it more understandable.
            let execName = sources.root.basename.spm_mangledToC99ExtendedIdentifier()

            // Get access to the path containing the PackagePlugin module and library.
            let runtimePath = self.toolchain.swiftPMLibrariesLocation.pluginAPI

            // We use the toolchain's Swift compiler for compiling the plugin.
            var command = [self.toolchain.swiftCompilerPath.pathString]

            let macOSPackageDescriptionPath: AbsolutePath
            // if runtimePath is set to "PackageFrameworks" that means we could be developing SwiftPM in Xcode
            // which produces a framework for dynamic package products.
            if runtimePath.extension == "framework" {
                command += [
                    "-F", runtimePath.parentDirectory.pathString,
                    "-framework", "PackagePlugin",
                    "-Xlinker", "-rpath", "-Xlinker", runtimePath.parentDirectory.pathString,
                ]
                macOSPackageDescriptionPath = runtimePath.appending(component: "PackagePlugin")
            } else {
                command += [
                    "-L", runtimePath.pathString,
                    "-lPackagePlugin",
                ]
                #if !os(Windows)
                // -rpath argument is not supported on Windows,
                // so we add runtimePath to PATH when executing the manifest instead
                command += ["-Xlinker", "-rpath", "-Xlinker", runtimePath.pathString]
                #endif

                // note: this is not correct for all platforms, but we only actually use it on macOS.
                macOSPackageDescriptionPath = runtimePath.appending(component: "libPackagePlugin.dylib")
            }

            // Use the same minimum deployment target as the PackageDescription library (with a fallback of 10.15).
            #if os(macOS)
            let triple = self.hostTriple
            let version = try Self._packageDescriptionMinimumDeploymentTarget.memoize {
                (try Self.computeMinimumDeploymentTarget(of: macOSPackageDescriptionPath))?.versionString ?? "10.15"
            }
            command += ["-target", "\(triple.tripleString(forPlatformVersion: version))"]
            #endif

            // Add any extra flags required as indicated by the ManifestLoader.
            command += self.toolchain.swiftCompilerFlags

            // Add the Swift language version implied by the package tools version.
            command += ["-swift-version", toolsVersion.swiftLanguageVersion.rawValue]

            // Add the PackageDescription version specified by the package tools version, which controls what PackagePlugin API is seen.
            command += ["-package-description-version", toolsVersion.description]

            // if runtimePath is set to "PackageFrameworks" that means we could be developing SwiftPM in Xcode
            // which produces a framework for dynamic package products.
            if runtimePath.extension == "framework" {
                command += ["-I", runtimePath.parentDirectory.parentDirectory.pathString]
            } else {
                command += ["-I", runtimePath.pathString]
            }
            #if os(macOS)
            if let sdkRoot = self.toolchain.sdkRootPath ?? self.sdkRoot() {
                command += ["-sdk", sdkRoot.pathString]
            }
            #endif

            // Honor any module cache override that's set in the environment.
            let moduleCachePath = ProcessEnv.vars["SWIFTPM_MODULECACHE_OVERRIDE"] ?? ProcessEnv.vars["SWIFTPM_TESTS_MODULECACHE"]
            if let moduleCachePath = moduleCachePath {
                command += ["-module-cache-path", moduleCachePath]
            }

            // Parse the plugin as a library so that `@main` is supported even though there might be only a single source file.
            command += ["-parse-as-library"]

            // Add options to create a .dia file containing any diagnostics emitted by the compiler.
            let diagnosticsFile = cacheDir.appending(component: "\(execName).dia")
            command += ["-Xfrontend", "-serialize-diagnostics-path", "-Xfrontend", diagnosticsFile.pathString]

            // Add all the source files that comprise the plugin scripts.
            command += sources.paths.map { $0.pathString }

            // Add the path of the compiled executable.
#if os(Windows)
            let execSuffix = ".exe"
#else
            let execSuffix = ""
#endif
            let executableFile = cacheDir.appending(component: execName + execSuffix)
            command += ["-o", executableFile.pathString]
        
            // Create the cache directory in which we'll be placing the compiled executable if needed.
            try FileManager.default.createDirectory(at: cacheDir.asURL, withIntermediateDirectories: true, attributes: nil)
        
            // Hash the command line and the contents of the source files to decide whether we need to recompile the plugin executable.
            let compilerInputsHash: String?
            do {
                // We include the full command line, the environment, and the contents of the source files.
                let stream = BufferedOutputByteStream()
                stream <<< command
                for (key, value) in toolchain.swiftCompilerEnvironment.sorted(by: { $0.key < $1.key }) {
                    stream <<< "\(key)=\(value)\n"
                }
                for sourceFile in sources.paths {
                    try stream <<< localFileSystem.readFileContents(sourceFile).contents
                }
                compilerInputsHash = stream.bytes.sha256Checksum
                observabilityScope.emit(debug: "Computed hash of plugin compilation inputs: \(compilerInputsHash!)")
            }
            catch {
                // We failed to compute the hash. We warn about it but proceed with the compilation (a cache miss).
                observabilityScope.emit(warning: "Couldn't compute hash of plugin compilation inputs (\(error)")
                compilerInputsHash = .none
            }

            // If we already have a compiled executable, then compare its hash with the new one.
            var compilationNeeded = true
            let hashFile = executableFile.parentDirectory.appending(component: execName + ".inputhash")
            if localFileSystem.exists(executableFile) && localFileSystem.exists(hashFile) {
                do {
                    if (try localFileSystem.readFileContents(hashFile)) == compilerInputsHash {
                        compilationNeeded = false
                    }
                }
                catch {
                    // We failed to read the `.inputhash` file. We warn about it but proceed with the compilation (a cache miss).
                    observabilityScope.emit(warning: "Couldn't read previous hash of plugin compilation inputs (\(error)")
                }
            }
            if compilationNeeded {
                // We need to recompile the executable, so we do so asynchronously.
                Process.popen(arguments: command, environment: toolchain.swiftCompilerEnvironment, queue: callbackQueue) {
                    // We are now on our caller's requested callback queue, so we just call the completion handler directly.
                    dispatchPrecondition(condition: .onQueue(callbackQueue))
                    completion($0.tryMap {
                        // Emit the compiler output as observable info.
                        let compilerOutput = ((try? $0.utf8Output()) ?? "") + ((try? $0.utf8stderrOutput()) ?? "")
                        observabilityScope.emit(info: compilerOutput)

                        // We return a PluginCompilationResult for both the successful and unsuccessful cases (to convey diagnostics, etc).
                        let result = PluginCompilationResult(
                            compilerResult: $0,
                            diagnosticsFile: diagnosticsFile,
                            compiledExecutable: executableFile,
                            wasCached: false)
                        guard $0.exitStatus == .terminated(code: 0) else {
                            // Try to clean up any old executable and hash file that might still be around from before.
                            try? localFileSystem.removeFileTree(executableFile)
                            try? localFileSystem.removeFileTree(hashFile)
                            throw DefaultPluginScriptRunnerError.compilationFailed(result)
                        }

                        // We only get here if the compilation succeeded.
                        do {
                            // Write out the hash of the inputs so we can compare the next time we try to compile.
                            if let newHash = compilerInputsHash {
                                try localFileSystem.writeFileContents(hashFile, string: newHash)
                            }
                        }
                        catch {
                            // We failed to write the `.inputhash` file. We warn about it but proceed.
                            observabilityScope.emit(warning: "Couldn't write new hash of plugin compilation inputs (\(error)")
                        }
                        return result
                    })
                }
            }
            else {
                // There is no need to recompile the executable, so we just call the completion handler with the results from last time.
                let result = PluginCompilationResult(
                    compilerResult: .none,
                    diagnosticsFile: diagnosticsFile,
                    compiledExecutable: executableFile,
                    wasCached: true)
                callbackQueue.async {
                    completion(.success(result))
                }
            }
        }
        catch {
            // We get here if we didn't even get far enough to invoke the compiler before hitting an error.
            callbackQueue.async { completion(.failure(DefaultPluginScriptRunnerError.compilationPreparationFailed(error: error))) }
        }
    }

    /// Returns path to the sdk, if possible.
    // FIXME: This is copied from ManifestLoader.  This should be consolidated when ManifestLoader is cleaned up.
    private func sdkRoot() -> AbsolutePath? {
        if let sdkRoot = self.sdkRootCache.get() {
            return sdkRoot
        }

        var sdkRootPath: AbsolutePath?
        // Find SDKROOT on macOS using xcrun.
        #if os(macOS)
        let foundPath = try? Process.checkNonZeroExit(
            args: "/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"
        )
        guard let sdkRoot = foundPath?.spm_chomp(), !sdkRoot.isEmpty else {
            return nil
        }
        let path = AbsolutePath(sdkRoot)
        sdkRootPath = path
        self.sdkRootCache.put(path)
        #endif

        return sdkRootPath
    }

    // FIXME: This is copied from ManifestLoader.  This should be consolidated when ManifestLoader is cleaned up.
    static func computeMinimumDeploymentTarget(of binaryPath: AbsolutePath) throws -> PlatformVersion? {
        let runResult = try Process.popen(arguments: ["/usr/bin/xcrun", "vtool", "-show-build", binaryPath.pathString])
        guard let versionString = try runResult.utf8Output().components(separatedBy: "\n").first(where: { $0.contains("minos") })?.components(separatedBy: " ").last else { return nil }
        return PlatformVersion(versionString)
    }
    
    /// Private function that invokes a compiled plugin executable and communicates with it until it finishes.
    fileprivate func invoke(
        compiledExec: AbsolutePath,
        writableDirectories: [AbsolutePath],
        input: PluginScriptRunnerInput,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        delegate: PluginInvocationDelegate,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
#if os(iOS) || os(watchOS) || os(tvOS)
        callbackQueue.async {
            completion(.failure(DefaultPluginScriptRunnerError.pluginUnavailable(reason: "subprocess invocations are unavailable on this platform")))
        }
#else
        // Construct the command line. Currently we just invoke the executable built from the plugin without any parameters.
        var command = [compiledExec.pathString]

        // Optionally wrap the command in a sandbox, which places some limits on what it can do. In particular, it blocks network access and restricts the paths to which the plugin can make file system changes.
        if self.enableSandbox {
            command = Sandbox.apply(command: command, writableDirectories: writableDirectories + [self.cacheDir], strictness: .writableTemporaryDirectory)
        }

        // Create and configure a Process. We set the working directory to the cache directory, so that relative paths end up there.
        let process = Process()
        process.executableURL = Foundation.URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.environment = ProcessInfo.processInfo.environment
        process.currentDirectoryURL = self.cacheDir.asURL
        
        // Set up a pipe for sending structured messages to the plugin on its stdin.
        let stdinPipe = Pipe()
        let outputHandle = stdinPipe.fileHandleForWriting
        let outputQueue = DispatchQueue(label: "plugin-send-queue")
        process.standardInput = stdinPipe

        // Private message handler method. Always invoked on the callback queue.
        var emittedAtLeastOneError = false
        func handle(message: PluginToHostMessage) throws {
            dispatchPrecondition(condition: .onQueue(callbackQueue))
            switch message {
                
            case .emitDiagnostic(let severity, let message, let file, let line):
                let metadata: ObservabilityMetadata? = file.map {
                    var metadata = ObservabilityMetadata()
                    // FIXME: We should probably report some kind of protocol error if the path isn't valid.
                    metadata.fileLocation = try? .init(.init(validating: $0), line: line)
                    return metadata
                }
                let diagnostic: Basics.Diagnostic
                switch severity {
                case .error:
                    emittedAtLeastOneError = true
                    diagnostic = .error(message, metadata: metadata)
                case .warning:
                    diagnostic = .warning(message, metadata: metadata)
                case .remark:
                    diagnostic = .info(message, metadata: metadata)
                }
                delegate.pluginEmittedDiagnostic(diagnostic)
                
            case .defineBuildCommand(let config, let inputFiles, let outputFiles):
                delegate.pluginDefinedBuildCommand(
                    displayName: config.displayName,
                    executable: try AbsolutePath(validating: config.executable),
                    arguments: config.arguments,
                    environment: config.environment,
                    workingDirectory: try config.workingDirectory.map{ try AbsolutePath(validating: $0) },
                    inputFiles: try inputFiles.map{ try AbsolutePath(validating: $0) },
                    outputFiles: try outputFiles.map{ try AbsolutePath(validating: $0) })
                
            case .definePrebuildCommand(let config, let outputFilesDir):
                delegate.pluginDefinedPrebuildCommand(
                    displayName: config.displayName,
                    executable: try AbsolutePath(validating: config.executable),
                    arguments: config.arguments,
                    environment: config.environment,
                    workingDirectory: try config.workingDirectory.map{ try AbsolutePath(validating: $0) },
                    outputFilesDirectory: try AbsolutePath(validating: outputFilesDir))

            case .buildOperationRequest(let subset, let parameters):
                delegate.pluginRequestedBuildOperation(subset: subset, parameters: parameters) {
                    switch $0 {
                    case .success(let result):
                        outputQueue.async { try? outputHandle.writePluginMessage(.buildOperationResponse(result: result)) }
                    case .failure(let error):
                        outputQueue.async { try? outputHandle.writePluginMessage(.errorResponse(error: String(describing: error))) }
                    }
                }

            case .testOperationRequest(let subset, let parameters):
                delegate.pluginRequestedTestOperation(subset: subset, parameters: parameters) {
                    switch $0 {
                    case .success(let result):
                        outputQueue.async { try? outputHandle.writePluginMessage(.testOperationResponse(result: result)) }
                    case .failure(let error):
                        outputQueue.async { try? outputHandle.writePluginMessage(.errorResponse(error: String(describing: error))) }
                    }
                }

            case .symbolGraphRequest(let targetName, let options):
                // The plugin requested symbol graph information for a target. We ask the delegate and then send a response.
                delegate.pluginRequestedSymbolGraph(forTarget: targetName, options: options) {
                    switch $0 {
                    case .success(let result):
                        outputQueue.async { try? outputHandle.writePluginMessage(.symbolGraphResponse(result: result)) }
                    case .failure(let error):
                        outputQueue.async { try? outputHandle.writePluginMessage(.errorResponse(error: String(describing: error))) }
                    }
                }
            }
        }

        // Set up a pipe for receiving structured messages from the plugin on its stdout.
        let stdoutPipe = Pipe()
        let stdoutLock = Lock()
        stdoutPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            // Parse the next message and pass it on to the delegate.
            stdoutLock.withLock {
                while let message = try? fileHandle.readPluginMessage() {
                    // FIXME: We should handle errors here.
                    callbackQueue.async { try? handle(message: message) }
                }
            }
        }
        process.standardOutput = stdoutPipe

        // Set up a pipe for receiving free-form text output from the plugin on its stderr.
        let stderrPipe = Pipe()
        let stderrLock = Lock()
        var stderrData = Data()
        stderrPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            // Pass on any available data to the delegate.
            stderrLock.withLock {
                let newData = fileHandle.availableData
                if newData.isEmpty { return }
                stderrData.append(contentsOf: newData)
                callbackQueue.async { delegate.pluginEmittedOutput(newData) }
            }
        }
        process.standardError = stderrPipe
        
        // Set up a handler to deal with the exit of the plugin process.
        process.terminationHandler = { process in
            // Close the output handle through which we talked to the plugin.
            try? outputHandle.close()

            // Read and pass on any remaining free-form text output from the plugin.
            stderrPipe.fileHandleForReading.readabilityHandler?(stderrPipe.fileHandleForReading)

            // Read and pass on any remaining messages from the plugin.
            stdoutPipe.fileHandleForReading.readabilityHandler?(stdoutPipe.fileHandleForReading)

            // Call the completion block with a result that depends on how the process ended.
            callbackQueue.async {
                completion(Result {
                    // We throw an error if the plugin ended with a signal.
                    if process.terminationReason == .uncaughtSignal {
                        throw DefaultPluginScriptRunnerError.invocationEndedBySignal(
                            signal: process.terminationStatus,
                            command: command,
                            output: String(decoding: stderrData, as: UTF8.self))
                    }
                    // Otherwise we return a result based on its exit code. If
                    // the plugin exits with an error but hasn't already emitted
                    // an error, we do so for it.
                    let success = (process.terminationStatus == 0)
                    if !success && !emittedAtLeastOneError {
                        delegate.pluginEmittedDiagnostic(
                            .error("Plugin ended with exit code \(process.terminationStatus)")
                        )
                    }
                    return success
                })
            }
        }
 
        // Start the plugin process.
        do {
            try process.run()
        }
        catch {
            callbackQueue.async {
                completion(.failure(DefaultPluginScriptRunnerError.invocationFailed(error: error, command: command)))
            }
        }

        /// Send an initial message to the plugin to ask it to perform its action based on the input data.
        outputQueue.async {
            try? outputHandle.writePluginMessage(.performAction(input: input))
        }
#endif
    }
}

/// The result of compiling a plugin. The executable path will only be present if the compilation succeeds, while the other properties are present in all cases.
public struct PluginCompilationResult {
    /// Process result of invoking the Swift compiler to produce the executable (contains command line, environment, exit status, and any output).
    public var compilerResult: ProcessResult?
    
    /// Path of the libClang diagnostics file emitted by the compiler (even if compilation succeded, it might contain warnings).
    public var diagnosticsFile: AbsolutePath
    
    /// Path of the compiled executable.
    public var compiledExecutable: AbsolutePath

    /// Whether the compilation result was cached.
    public var wasCached: Bool
}

extension PluginCompilationResult: CustomStringConvertible {
    public var description: String {
        return """
            <PluginCompilationResult(
                exitStatus: \(compilerResult.map{ "\($0.exitStatus)" } ?? "-"),
                stdout: \((try? compilerResult?.utf8Output()) ?? ""),
                stderr: \((try? compilerResult?.utf8stderrOutput()) ?? ""),
                executable: \(compiledExecutable.prettyPath())
            )>
            """
    }
}


/// An error encountered by the default plugin runner.
public enum DefaultPluginScriptRunnerError: Error, CustomStringConvertible {
    /// The plugin is not available for some reason.
    case pluginUnavailable(reason: String)

    /// An error occurred while preparing to compile the plugin script.
    case compilationPreparationFailed(error: Error)

    /// An error occurred while compiling the plugin script (e.g. syntax error).
    /// The diagnostics are available in the plugin compilation result.
    case compilationFailed(PluginCompilationResult)

    /// The plugin invocation couldn't be started.
    case invocationFailed(error: Error, command: [String])

    /// The plugin invocation ended by a signal.
    case invocationEndedBySignal(signal: Int32, command: [String], output: String)

    /// The plugin invocation ended with a non-zero exit code.
    case invocationEndedWithNonZeroExitCode(exitCode: Int32, command: [String], output: String)

    /// There was an error communicating with the plugin.
    case pluginCommunicationError(message: String, command: [String], output: String)

    public var description: String {
        func makeContextString(_ command: [String], _ output: String) -> String {
            return "<command: \(command.map{ $0.spm_shellEscaped() }.joined(separator: " "))>, <output:\n\(output.spm_shellEscaped())>"
        }
        switch self {
        case .pluginUnavailable(let reason):
            return "plugin is unavailable: \(reason)"
        case .compilationPreparationFailed(let error):
            return "plugin compilation preparation failed: \(error)"
        case .compilationFailed(let result):
            return "plugin compilation failed: \(result)"
        case .invocationFailed(let error, let command):
            return "plugin invocation failed: \(error) \(makeContextString(command, ""))"
        case .invocationEndedBySignal(let signal, let command, let output):
            return "plugin process ended by an uncaught signal: \(signal) \(makeContextString(command, output))"
        case .invocationEndedWithNonZeroExitCode(let exitCode, let command, let output):
            return "plugin process ended with a non-zero exit code: \(exitCode) \(makeContextString(command, output))"
        case .pluginCommunicationError(let message, let command, let output):
            return "plugin communication error: \(message) \(makeContextString(command, output))"
        }
    }
}

/// A message that the host can send to the plugin.
enum HostToPluginMessage: Encodable {
    /// The host is requesting that the plugin perform one of its declared plugin actions.
    case performAction(input: PluginScriptRunnerInput)
    
    /// A response to a request to run a build operation.
    case buildOperationResponse(result: PluginInvocationBuildResult)

    /// A response to a request to run a test.
    case testOperationResponse(result: PluginInvocationTestResult)

    /// A response to a request for symbol graph information for a target.
    case symbolGraphResponse(result: PluginInvocationSymbolGraphResult)
    
    /// A response of an error while trying to complete a request.
    case errorResponse(error: String)
}

/// A message that the plugin can send to the host.
enum PluginToHostMessage: Decodable {
    /// The plugin emits a diagnostic.
    case emitDiagnostic(severity: DiagnosticSeverity, message: String, file: String?, line: Int?)

    enum DiagnosticSeverity: String, Decodable {
        case error, warning, remark
    }
    
    /// The plugin defines a build command.
    case defineBuildCommand(configuration: CommandConfiguration, inputFiles: [String], outputFiles: [String])

    /// The plugin defines a prebuild command.
    case definePrebuildCommand(configuration: CommandConfiguration, outputFilesDirectory: String)
    
    struct CommandConfiguration: Decodable {
        var displayName: String?
        var executable: String
        var arguments: [String]
        var environment: [String: String]
        var workingDirectory: String?
    }

    /// The plugin is requesting that a build operation be run.
    case buildOperationRequest(subset: PluginInvocationBuildSubset, parameters: PluginInvocationBuildParameters)
    
    /// The plugin is requesting that a test operation be run.
    case testOperationRequest(subset: PluginInvocationTestSubset, parameters: PluginInvocationTestParameters)

    /// The plugin is requesting symbol graph information for a given target and set of options.
    case symbolGraphRequest(targetName: String, options: PluginInvocationSymbolGraphOptions)
}

fileprivate extension FileHandle {
    
    func writePluginMessage(_ message: HostToPluginMessage) throws {
        // Encode the message as JSON.
        let payload = try JSONEncoder().encode(message)
        
        // Write the header (a 64-bit length field in little endian byte order).
        var count = UInt64(littleEndian: UInt64(payload.count))
        let header = Swift.withUnsafeBytes(of: &count) { Data($0) }
        assert(header.count == 8)
        try self.write(contentsOf: header)
        
        // Write the payload.
        try self.write(contentsOf: payload)
    }
    
    func readPluginMessage() throws -> PluginToHostMessage? {
        // Read the header (a 64-bit length field in little endian byte order).
        guard let header = try self.read(upToCount: 8) else { return nil }
        guard header.count == 8 else {
            throw PluginMessageError.truncatedHeader
        }
        
        // Decode the count.
        let count = header.withUnsafeBytes{ $0.load(as: UInt64.self).littleEndian }
        guard count >= 2 else {
            throw PluginMessageError.invalidPayloadSize
        }

        // Read the JSON payload.
        guard let payload = try self.read(upToCount: Int(count)), payload.count == count else {
            throw PluginMessageError.truncatedPayload
        }

        // Decode and return the message.
        return try JSONDecoder().decode(PluginToHostMessage.self, from: payload)
    }

    enum PluginMessageError: Swift.Error {
        case truncatedHeader
        case invalidPayloadSize
        case truncatedPayload
    }
}
