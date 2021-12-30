/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

/// Provides specialized information and services from the Swift Package Manager
/// or an IDE that supports Swift Packages. Different plugin hosts implement the
/// functionality in whatever way is appropriate for them, but should preserve
/// the same semantics described here.
public struct PackageManager {

    /// Performs a build of all or a subset of products and targets in a package.
    ///
    /// Any errors encountered during the build are reported in the build result,
    /// as is the log of the build commands that were run. This method throws an
    /// error if the input parameters are invalid or in case the build cannot be
    /// started.
    ///
    /// The SwiftPM CLI or any IDE that supports packages may show the progress
    /// of the build as it happens.
    public func build(
        _ subset: BuildSubset,
        parameters: BuildParameters
    ) throws -> BuildResult {
        // Ask the plugin host to build the specified products and targets, and wait for a response.
        // FIXME: We'll want to make this asynchronous when there is back deployment support for it.
        return try sendMessageAndWaitForReply(.buildOperationRequest(subset: subset, parameters: parameters)) {
            guard case .buildOperationResponse(let result) = $0 else { return nil }
            return result
        }
    }
    
    /// Specifies a subset of products and targets of a package to build.
    public enum BuildSubset: Encodable {
        /// Represents the subset consisting of all products and of either all
        /// targets or (if `includingTests` is false) just non-test targets.
        case all(includingTests: Bool)

        /// Represents the product with the specified name.
        case product(String)

        /// Represents the target with the specified name.
        case target(String)
    }
    
    /// Parameters and options to apply during a build.
    public struct BuildParameters: Encodable {
        /// Whether to build for debug or release.
        public var configuration: BuildConfiguration
        
        /// Controls the amount of detail in the log returned in the build result.
        public var logging: BuildLogVerbosity
        
        /// Additional flags to pass to all C compiler invocations.
        public var otherCFlags: [String] = []

        /// Additional flags to pass to all C++ compiler invocations.
        public var otherCxxFlags: [String] = []

        /// Additional flags to pass to all Swift compiler invocations.
        public var otherSwiftcFlags: [String] = []
        
        /// Additional flags to pass to all linker invocations.
        public var otherLinkerFlags: [String] = []

        public init(configuration: BuildConfiguration = .debug, logging: BuildLogVerbosity = .concise) {
            self.configuration = configuration
            self.logging = logging
        }
    }
    
    /// Represents an overall purpose of the build, which affects such things
    /// asoptimization and generation of debug symbols.
    public enum BuildConfiguration: String, Encodable {
        case debug, release
    }
    
    /// Represents the amount of detail in a build log.
    public enum BuildLogVerbosity: String, Encodable {
        case concise, verbose, debug
    }
    
    /// Represents the results of running a build.
    public struct BuildResult: Decodable {
        /// Whether the build succeeded or failed.
        public var succeeded: Bool
        
        /// Log output (the verbatim text in the initial proposal).
        public var logText: String
        
        /// The artifacts built from the products in the package. Intermediates
        /// such as object files produced from individual targets are not listed.
        public var builtArtifacts: [BuiltArtifact]
        
        /// Represents a single artifact produced during a build.
        public struct BuiltArtifact: Decodable {
            /// Full path of the built artifact in the local file system.
            public var path: Path
            
            /// The kind of artifact that was built.
            public var kind: Kind
            
            /// Represents the kind of artifact that was built. The specific file
            /// formats may vary from platform to platform — for example, on macOS
            /// a dynamic library may in fact be built as a framework.
            public enum Kind: String, Decodable {
                case executable, dynamicLibrary, staticLibrary
            }
        }
    }
    
    /// Runs all or a specified subset of the unit tests of the package, after
    /// an incremental build if necessary (the same as `swift test` does).
    ///
    /// Any test failures are reported in the test result. This method throws an
    /// error if the input parameters are invalid or in case the test cannot be
    /// started.
    ///
    /// The SwiftPM CLI or any IDE that supports packages may show the progress
    /// of the tests as they happen.
    public func test(
        _ subset: TestSubset,
        parameters: TestParameters
    ) throws -> TestResult {
        // Ask the plugin host to run the specified tests, and wait for a response.
        // FIXME: We'll want to make this asynchronous when there is back deployment support for it.
        return try sendMessageAndWaitForReply(.testOperationRequest(subset: subset, parameters: parameters)) {
            guard case .testOperationResponse(let result) = $0 else { return nil }
            return result
        }
    }
        
    /// Specifies what tests in a package to run.
    public enum TestSubset: Encodable {
        /// Represents all tests in the package.
        case all

        /// Represents one or more tests filtered by regular expression, with the
        /// format <test-target>.<test-case> or <test-target>.<test-case>/<test>.
        /// This is the same as the `--filter` option of `swift test`.
        case filtered([String])
    }
    
    /// Parameters that control how the tests are run.
    public struct TestParameters: Encodable {
        /// Whether to collect code coverage information while running the tests.
        public var enableCodeCoverage: Bool
        
        public init(enableCodeCoverage: Bool = false) {
            self.enableCodeCoverage = enableCodeCoverage
        }
    }
    
    /// Represents the result of running unit tests.
    public struct TestResult: Decodable {
        /// Whether the test run succeeded or failed.
        public var succeeded: Bool
        
        /// Results for all the test targets that were run (filtered based on
        /// the input subset passed when running the test).
        public var testTargets: [TestTarget]
        
        /// Path of a generated `.profdata` file suitable for processing using
        /// `llvm-cov`, if `enableCodeCoverage` was set in the test parameters.
        public var codeCoverageDataFile: Path?

        /// Represents the results of running some or all of the tests in a
        /// single test target.
        public struct TestTarget: Decodable {
            public var name: String
            public var testCases: [TestCase]
            
            /// Represents the results of running some or all of the tests in
            /// a single test case.
            public struct TestCase: Decodable {
                public var name: String
                public var tests: [Test]

                /// Represents the results of running a single test.
                public struct Test: Decodable {
                    public var name: String
                    public var result: Result
                    public var duration: Double

                    /// Represents the result of running a single test.
                    public enum Result: String, Decodable {
                        case succeeded, skipped, failed
                    }
                }
            }
        }
    }
    
    /// Return a directory containing symbol graph files for the given target
    /// and options. If the symbol graphs need to be created or updated first,
    /// they will be. SwiftPM or an IDE may generate these symbol graph files
    /// in any way it sees fit.
    public func getSymbolGraph(
        for target: Target,
        options: SymbolGraphOptions
    ) throws -> SymbolGraphResult {
        // Ask the plugin host for symbol graph information for the target, and wait for a response.
        // FIXME: We'll want to make this asynchronous when there is back deployment support for it.
        return try sendMessageAndWaitForReply(.symbolGraphRequest(targetName: target.name, options: options)) {
            guard case .symbolGraphResponse(let result) = $0 else { return nil }
            return result
        }
    }

    /// Represents options for symbol graph generation.
    public struct SymbolGraphOptions: Encodable {
        /// The symbol graph will include symbols at this access level and higher.
        public var minimumAccessLevel: AccessLevel

        /// Represents a Swift access level.
        public enum AccessLevel: String, CaseIterable, Encodable {
            case `private`, `fileprivate`, `internal`, `public`, `open`
        }

        /// Whether to include synthesized members.
        public var includeSynthesized: Bool
        
        /// Whether to include symbols marked as SPI.
        public var includeSPI: Bool
        
        public init(minimumAccessLevel: AccessLevel = .public, includeSynthesized: Bool = false, includeSPI: Bool = false) {
            self.minimumAccessLevel = minimumAccessLevel
            self.includeSynthesized = includeSynthesized
            self.includeSPI = includeSPI
        }
    }

    /// Represents the result of symbol graph generation.
    public struct SymbolGraphResult: Decodable {
        /// The directory that contains the symbol graph files for the target.
        public var directoryPath: Path
    }
    
    /// Private helper function that sends a message to the host and waits for a reply. The reply handler should return nil for any reply message it doesn't recognize.
    fileprivate func sendMessageAndWaitForReply<T>(_ message: PluginToHostMessage, replyHandler: (HostToPluginMessage) -> T?) throws -> T {
        try pluginHostConnection.sendMessage(message)
        guard let reply = try pluginHostConnection.waitForNextMessage() else {
            throw PackageManagerProxyError.unspecified("internal error: unexpected lack of response message")
        }
        if case .errorResponse(let message) = reply {
            throw PackageManagerProxyError.unspecified(message)
        }
        if let result = replyHandler(reply) {
            return result
        }
        throw PackageManagerProxyError.unspecified("internal error: unexpected response message \(message)")
    }
}

public enum PackageManagerProxyError: Error {
    /// Indicates that the functionality isn't implemented in the plugin host.
    case unimlemented(_ message: String)
    
    /// An unspecified other kind of error from the Package Manager proxy.
    case unspecified(_ message: String)
}
