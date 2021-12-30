/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2018-2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basics
import Foundation
import PackageGraph
import PackageLoading
import PackageModel
import PackageRegistry
import TSCBasic
import TSCUtility

// MARK: - Location

extension Workspace {
    /// Workspace location configuration
    public struct Location {
        /// Path to working directory for this workspace.
        public var workingDirectory: AbsolutePath

        /// Path to store the editable versions of dependencies.
        public var editsDirectory: AbsolutePath

        /// Path to the Package.resolved file.
        public var resolvedVersionsFile: AbsolutePath
        
        /// Path to the shared security directory
        public var sharedSecurityDirectory: AbsolutePath?

        /// Path to the shared cache directory
        public var sharedCacheDirectory: AbsolutePath?

        /// Path to the shared configuration directory
        public var sharedConfigurationDirectory: AbsolutePath?

        /// Path to the repositories clones.
        public var repositoriesDirectory: AbsolutePath {
            self.workingDirectory.appending(component: "repositories")
        }

        /// Path to the repository checkouts.
        public var repositoriesCheckoutsDirectory: AbsolutePath {
            self.workingDirectory.appending(component: "checkouts")
        }

        /// Path to the registry downloads.
        public var registryDownloadDirectory: AbsolutePath {
            self.workingDirectory.appending(components: "registry", "downloads")
        }

        /// Path to the downloaded binary artifacts.
        public var artifactsDirectory: AbsolutePath {
            self.workingDirectory.appending(component: "artifacts")
        }
        
        /// Path to the shared fingerprints directory.
        public var sharedFingerprintsDirectory: AbsolutePath? {
            self.sharedSecurityDirectory.map { $0.appending(component: "fingerprints") }
        }

        /// Path to the shared repositories cache.
        public var sharedRepositoriesCacheDirectory: AbsolutePath? {
            self.sharedCacheDirectory.map { $0.appending(component: "repositories") }
        }

        /// Path to the shared manifests cache.
        public var sharedManifestsCacheDirectory: AbsolutePath? {
            self.sharedCacheDirectory.map { DefaultLocations.manifestsDirectory(at: $0) }
        }

        /// Path to the shared mirrors configuration.
        public var sharedMirrorsConfigurationFile: AbsolutePath? {
            self.sharedConfigurationDirectory.map { DefaultLocations.mirrorsConfigurationFile(at: $0) }
        }

        /// Path to the shared registries configuration.
        public var sharedRegistriesConfigurationFile: AbsolutePath? {
            self.sharedConfigurationDirectory.map { DefaultLocations.registriesConfigurationFile(at: $0) }
        }
        
        // Path to temporary files related to running plugins in the workspace
        public var pluginWorkingDirectory: AbsolutePath {
            self.workingDirectory.appending(component: "plugins")
        }

        /// Create a new workspace location.
        ///
        /// - Parameters:
        ///   - workingDirectory: Path to working directory for this workspace.
        ///   - editsDirectory: Path to store the editable versions of dependencies.
        ///   - resolvedVersionsFile: Path to the Package.resolved file.
        ///   - sharedSecurityDirectory: Path to the shared security directory.
        ///   - sharedCacheDirectory: Path to the shared cache directory.
        ///   - sharedConfigurationDirectory: Path to the shared configuration directory.
        public init(
            workingDirectory: AbsolutePath,
            editsDirectory: AbsolutePath,
            resolvedVersionsFile: AbsolutePath,
            sharedSecurityDirectory: AbsolutePath?,
            sharedCacheDirectory: AbsolutePath?,
            sharedConfigurationDirectory: AbsolutePath?
        ) {
            self.workingDirectory = workingDirectory
            self.editsDirectory = editsDirectory
            self.resolvedVersionsFile = resolvedVersionsFile
            self.sharedSecurityDirectory = sharedSecurityDirectory
            self.sharedCacheDirectory = sharedCacheDirectory
            self.sharedConfigurationDirectory = sharedConfigurationDirectory
        }

        /// Create a new workspace location.
        ///
        /// - Parameters:
        ///   - rootPath: Path to the root of the package, from which other locations can be derived.
        public init(forRootPackage rootPath: AbsolutePath, fileSystem: FileSystem) {
            self.init(
                workingDirectory: DefaultLocations.workingDirectory(forRootPackage: rootPath),
                editsDirectory: DefaultLocations.editsDirectory(forRootPackage: rootPath),
                resolvedVersionsFile: DefaultLocations.resolvedVersionsFile(forRootPackage: rootPath),
                sharedSecurityDirectory: fileSystem.swiftPMSecurityDirectory,
                sharedCacheDirectory: fileSystem.swiftPMCacheDirectory,
                sharedConfigurationDirectory: fileSystem.swiftPMConfigurationDirectory
            )
        }
    }
}

// MARK: - Default locations

extension Workspace {
    /// Workspace default locations utilities
    public struct DefaultLocations {
        public static func workingDirectory(forRootPackage rootPath: AbsolutePath) -> AbsolutePath {
            rootPath.appending(component: ".build")
        }

        public static func editsDirectory(forRootPackage rootPath: AbsolutePath) -> AbsolutePath {
            rootPath.appending(component: "Packages")
        }

        public static func resolvedVersionsFile(forRootPackage rootPath: AbsolutePath) -> AbsolutePath {
            rootPath.appending(component: "Package.resolved")
        }

        public static func configurationDirectory(forRootPackage rootPath: AbsolutePath) -> AbsolutePath {
            rootPath.appending(components: ".swiftpm", "configuration")
        }

        public static func mirrorsConfigurationFile(forRootPackage rootPath: AbsolutePath) -> AbsolutePath {
            mirrorsConfigurationFile(at: configurationDirectory(forRootPackage: rootPath))
        }

        public static func mirrorsConfigurationFile(at path: AbsolutePath) -> AbsolutePath {
            path.appending(component: "mirrors.json")
        }

        public static func registriesConfigurationFile(forRootPackage rootPath: AbsolutePath) -> AbsolutePath {
            registriesConfigurationFile(at: configurationDirectory(forRootPackage: rootPath))
        }

        public static func registriesConfigurationFile(at path: AbsolutePath) -> AbsolutePath {
            path.appending(component: "registries.json")
        }

        public static func manifestsDirectory(at path: AbsolutePath) -> AbsolutePath {
            path.appending(component: "manifests")
        }
    }
}

// MARK: - Mirrors

extension Workspace.Configuration {
    public struct Mirrors {
        private let localMirrors: MirrorsStorage
        private let sharedMirrors: MirrorsStorage?
        private let fileSystem: FileSystem

        private var _mirrors: DependencyMirrors
        private let lock = Lock()

        /// The mirrors in this configuration
        public var mirrors: DependencyMirrors {
            self.lock.withLock {
                self._mirrors
            }
        }

        /// A convenience initializer for creating a workspace mirrors configuration for the given root
        /// package path.
        ///
        /// - Parameters:
        ///   - forRootPackage: The path for the root package.
        ///   - sharedMirrorFile: Path to the shared mirrors configuration file, defaults to the standard location.
        ///   - fileSystem: The file system to use.
        public init(
            forRootPackage rootPath: AbsolutePath,
            sharedMirrorFile: AbsolutePath?,
            fileSystem: FileSystem
        ) throws {
            let localMirrorConfigFile = Workspace.DefaultLocations.mirrorsConfigurationFile(forRootPackage: rootPath)
            try self.init(
                localMirrorFile: localMirrorConfigFile,
                sharedMirrorFile: sharedMirrorFile,
                fileSystem: fileSystem
            )
        }

        /// Initialize the workspace mirrors configuration
        ///
        /// - Parameters:
        ///   - localMirrorFile: Path to the workspace mirrors configuration file
        ///   - sharedMirrorFile: Path to the shared mirrors configuration file, defaults to the standard location.
        ///   - fileSystem: The file system to use.
        public init(
            localMirrorFile: AbsolutePath,
            sharedMirrorFile: AbsolutePath?,
            fileSystem: FileSystem
        ) throws {
            self.localMirrors = .init(path: localMirrorFile, fileSystem: fileSystem, deleteWhenEmpty: true)
            self.sharedMirrors = sharedMirrorFile.map { .init(path: $0, fileSystem: fileSystem, deleteWhenEmpty: false) }
            self.fileSystem = fileSystem
            // computes the initial mirrors
            self._mirrors = DependencyMirrors()
            try self.computeMirrors()
        }

        @discardableResult
        public func applyLocal(handler: (inout DependencyMirrors) throws -> Void) throws -> DependencyMirrors {
            try self.localMirrors.apply(handler: handler)
            try self.computeMirrors()
            return self.mirrors
        }

        @discardableResult
        public func applyShared(handler: (inout DependencyMirrors) throws -> Void) throws -> DependencyMirrors {
            guard let sharedMirrors = self.sharedMirrors else {
                throw InternalError("shared mirrors not configured")
            }
            try sharedMirrors.apply(handler: handler)
            try self.computeMirrors()
            return self.mirrors
        }

        // mutating the state we hold since we are passing it by reference to the workspace
        // access should be done using a lock
        private func computeMirrors() throws {
            try self.lock.withLock {
                self._mirrors.removeAll()

                // prefer local mirrors to shared ones
                let local = try self.localMirrors.get()
                if !local.isEmpty {
                    self._mirrors.append(contentsOf: local)
                    return
                }

                // use shared if local was not found or empty
                if let shared = try self.sharedMirrors?.get(), !shared.isEmpty {
                    self._mirrors.append(contentsOf: shared)
                }
            }
        }
    }
}

extension Workspace.Configuration {
    public struct MirrorsStorage {
        private let path: AbsolutePath
        private let fileSystem: FileSystem
        private let deleteWhenEmpty: Bool

        public init(path: AbsolutePath, fileSystem: FileSystem, deleteWhenEmpty: Bool) {
            self.path = path
            self.fileSystem = fileSystem
            self.deleteWhenEmpty = deleteWhenEmpty
        }

        /// The mirrors in this configuration
        public func get() throws -> DependencyMirrors {
            guard self.fileSystem.exists(self.path) else {
                return DependencyMirrors()
            }
            return try self.fileSystem.withLock(on: self.path.parentDirectory, type: .shared) {
                return DependencyMirrors(try Self.load(self.path, fileSystem: self.fileSystem))
            }
        }


        /// Apply a mutating handler on the mirrors in this configuration
        @discardableResult
        public func apply(handler: (inout DependencyMirrors) throws -> Void) throws -> DependencyMirrors {
            if !self.fileSystem.exists(self.path.parentDirectory) {
                try self.fileSystem.createDirectory(self.path.parentDirectory, recursive: true)
            }
            return try self.fileSystem.withLock(on: self.path.parentDirectory, type: .exclusive) {
                let mirrors = DependencyMirrors(try Self.load(self.path, fileSystem: self.fileSystem))
                var updatedMirrors = DependencyMirrors(mirrors.mapping)
                try handler(&updatedMirrors)
                if updatedMirrors != mirrors {
                    try Self.save(updatedMirrors.mapping, to: self.path, fileSystem: self.fileSystem, deleteWhenEmpty: self.deleteWhenEmpty)
                }
                return updatedMirrors
            }
        }

        private static func load(_ path: AbsolutePath, fileSystem: FileSystem) throws -> [String: String] {
            guard fileSystem.exists(path) else {
                return [:]
            }
            let data: Data = try fileSystem.readFileContents(path)
            let decoder = JSONDecoder.makeWithDefaults()
            let mirrors = try decoder.decode(MirrorsStorage.self, from: data)
            let mirrorsMap = Dictionary(mirrors.object.map({ ($0.original, $0.mirror) }), uniquingKeysWith: { first, _ in first })
            return mirrorsMap
        }

        private static func save(_ mirrors: [String: String], to path: AbsolutePath, fileSystem: FileSystem, deleteWhenEmpty: Bool) throws {
            if mirrors.isEmpty {
                if deleteWhenEmpty && fileSystem.exists(path)  {
                    // deleteWhenEmpty is a backward compatibility mode
                    return try fileSystem.removeFileTree(path)
                } else if !fileSystem.exists(path)  {
                    // nothing to do
                    return
                }
            }

            let encoder = JSONEncoder.makeWithDefaults()
            let mirrors = MirrorsStorage(version: 1, object: mirrors.map { .init(original: $0, mirror: $1) })
            let data = try encoder.encode(mirrors)
            if !fileSystem.exists(path.parentDirectory) {
                try fileSystem.createDirectory(path.parentDirectory, recursive: true)
            }
            try fileSystem.writeFileContents(path, data: data)
        }

        // structure is for backwards compatibility
        private struct MirrorsStorage: Codable {
            var version: Int
            var object: [Mirror]

            struct Mirror: Codable {
                var original: String
                var mirror: String
            }
        }
    }
}

// MARK: - Registries

extension Workspace.Configuration {
    public class Registries {
        private let localRegistries: RegistriesStorage
        private let sharedRegistries: RegistriesStorage?
        private let fileSystem: FileSystem

        private var _configuration = RegistryConfiguration()
        private let lock = Lock()

        /// The registry configuration
        public var configuration: RegistryConfiguration {
            self.lock.withLock {
                return self._configuration
            }
        }

        /// Initialize the workspace registries configuration
        ///
        /// - Parameters:
        ///   - localRegistriesFile: Path to the workspace registries configuration file
        ///   - sharedRegistriesFile: Path to the shared registries configuration file, defaults to the standard location.
        ///   - fileSystem: The file system to use.
        public init(
            localRegistriesFile: AbsolutePath,
            sharedRegistriesFile: AbsolutePath?,
            fileSystem: FileSystem
        ) throws {
            self.localRegistries = .init(path: localRegistriesFile, fileSystem: fileSystem)
            self.sharedRegistries = sharedRegistriesFile.map { .init(path: $0, fileSystem: fileSystem) }
            self.fileSystem = fileSystem
            try self.computeRegistries()
        }

        @discardableResult
        public func updateLocal(with handler: (inout RegistryConfiguration) throws -> Void) throws -> RegistryConfiguration {
            try self.localRegistries.update(with: handler)
            try self.computeRegistries()
            return self.configuration
        }

        @discardableResult
        public func updateShared(with handler: (inout RegistryConfiguration) throws -> Void) throws -> RegistryConfiguration {
            guard let sharedRegistries = self.sharedRegistries else {
                throw InternalError("shared registries not configured")
            }
            try sharedRegistries.update(with: handler)
            try self.computeRegistries()
            return self.configuration
        }

        // mutating the state we hold since we are passing it by reference to the workspace
        // access should be done using a lock
        private func computeRegistries() throws {
            try self.lock.withLock {
                var configuration = RegistryConfiguration()

                if let sharedConfiguration = try sharedRegistries?.load() {
                    configuration.merge(sharedConfiguration)
                }

                let localConfiguration = try localRegistries.load()
                configuration.merge(localConfiguration)

                self._configuration = configuration
            }
        }
    }
}

extension Workspace.Configuration {
    private struct RegistriesStorage {
        private let path: AbsolutePath
        private let fileSystem: FileSystem

        public init(path: AbsolutePath, fileSystem: FileSystem) {
            self.path = path
            self.fileSystem = fileSystem
        }

        public func load() throws -> RegistryConfiguration {
            guard fileSystem.exists(path) else {
                return RegistryConfiguration()
            }

            let data: Data = try fileSystem.readFileContents(path)
            let decoder = JSONDecoder.makeWithDefaults()
            return try decoder.decode(RegistryConfiguration.self, from: data)
        }

        public func save(_ configuration: RegistryConfiguration) throws {
            let encoder = JSONEncoder.makeWithDefaults()
            let data = try encoder.encode(configuration)

            if !fileSystem.exists(path.parentDirectory) {
                try fileSystem.createDirectory(path.parentDirectory, recursive: true)
            }
            try fileSystem.writeFileContents(path, bytes: ByteString(data), atomically: true)
        }

        @discardableResult
        public func update(with handler: (inout RegistryConfiguration) throws -> Void) throws -> RegistryConfiguration {
            let configuration = try load()
            var updatedConfiguration = configuration
            try handler(&updatedConfiguration)
            if updatedConfiguration != configuration {
                try save(updatedConfiguration)
            }

            return updatedConfiguration
        }
    }
}

// MARK: - Deprecated 8/20201

extension Workspace {
    /// Manages a package workspace's configuration.
    // FIXME change into enum after deprecation grace period
    public final class Configuration {
        /// The path to the mirrors file.
        private let configFile: AbsolutePath?

        /// The filesystem to manage the mirrors file on.
        private var fileSystem: FileSystem?

        /// Persistence support.
        private let persistence: SimplePersistence?

        /// The schema version of the config file.
        ///
        /// * 1: Initial version.
        static let schemaVersion: Int = 1

        /// The mirrors.
        public private(set) var mirrors: DependencyMirrors = DependencyMirrors()

        @available(*, deprecated)
        public convenience init(path: AbsolutePath, fs: FileSystem = localFileSystem) throws {
            try self.init(path: path, fileSystem: fs)
        }

        /// Creates a new, persisted package configuration with a configuration file.
        /// - Parameters:
        ///   - path: A path to the configuration file.
        ///   - fileSystem: The filesystem on which the configuration file is located.
        /// - Throws: `StringError` if the configuration file is corrupted or malformed.
        @available(*, deprecated, message: "use Configuration.Mirrors instead")
        public init(path: AbsolutePath, fileSystem: FileSystem) throws {
            self.configFile = path
            self.fileSystem = fileSystem
            let persistence = SimplePersistence(
                fileSystem: fileSystem,
                schemaVersion: Self.schemaVersion,
                statePath: path,
                prettyPrint: true
            )

            do {
                self.persistence = persistence
                _ = try persistence.restoreState(self)
            } catch SimplePersistence.Error.restoreFailure(_, let error) {
                throw StringError("Configuration file is corrupted or malformed; fix or delete the file to continue: \(error)")
            }
        }

        /// Load the configuration from disk.
        @available(*, deprecated, message: "use Configuration.Mirrors instead")
        public func restoreState() throws {
            _ = try self.persistence?.restoreState(self)
        }

        /// Persists the current configuration to disk.
        ///
        /// If the configuration is empty, any persisted configuration file is removed.
        ///
        /// - Throws: If the configuration couldn't be persisted.
        @available(*, deprecated, message: "use Configuration.Mirrors instead")
        public func saveState() throws {
            guard let persistence = self.persistence else { return }

            // Remove the configuration file if there aren't any mirrors.
            if mirrors.isEmpty,
               let fileSystem = self.fileSystem,
               let configFile = self.configFile
            {
                return try fileSystem.removeFileTree(configFile)
            }

            try persistence.saveState(self)
        }
    }
}

@available(*, deprecated, message: "use Configuration.Mirrors instead")
extension Workspace.Configuration: JSONSerializable {
    public func toJSON() -> JSON {
        return mirrors.toJSON()
    }
}

@available(*, deprecated, message: "use Configuration.Mirrors instead")
extension Workspace.Configuration: SimplePersistanceProtocol {
    public func restore(from json: JSON) throws {
        self.mirrors = try DependencyMirrors(json: json)
    }
}
