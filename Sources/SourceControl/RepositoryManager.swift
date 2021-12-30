/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basics
import Dispatch
import Foundation
import TSCBasic

/// Delegate to notify clients about actions being performed by RepositoryManager.
public protocol RepositoryManagerDelegate: AnyObject {
    /// Called when a repository is about to be fetched.
    func fetchingWillBegin(handle: RepositoryManager.RepositoryHandle, fetchDetails: RepositoryManager.FetchDetails?)

    /// Called when a repository has finished fetching.
    func fetchingDidFinish(handle: RepositoryManager.RepositoryHandle, fetchDetails: RepositoryManager.FetchDetails?, error: Swift.Error?, duration: DispatchTimeInterval)

    /// Called when a repository has started updating from its remote.
    func handleWillUpdate(handle: RepositoryManager.RepositoryHandle)

    /// Called when a repository has finished updating from its remote.
    func handleDidUpdate(handle: RepositoryManager.RepositoryHandle, duration: DispatchTimeInterval)

    /// Called every time the progress of a repository fetch operation updates.
    func fetchingRepository(from repository: String, objectsFetched: Int, totalObjectsToFetch: Int)
}

/// Manages a collection of bare repositories.
public class RepositoryManager {
    public typealias LookupResult = Result<RepositoryHandle, Error>
    public typealias LookupCompletion = (LookupResult) -> Void

    /// The path under which repositories are stored.
    public let path: AbsolutePath

    /// The path to the directory where all cached git repositories are stored.
    private let cachePath: AbsolutePath?

    // used in tests to disable skipping of local packages.
    private let cacheLocalPackages: Bool

    /// The repository provider.
    private let provider: RepositoryProvider

    /// The delegate interface.
    private let delegate: RepositoryManagerDelegate?

    /// Operation queue to do concurrent operations on manager.
    ///
    /// We use operation queue (and not dispatch queue) to limit the amount of
    /// concurrent operations.
    private let lookupQueue: OperationQueue

    /// The filesystem to operate on.
    private let fileSystem: FileSystem

    // storage and cache
    private let storage: RepositoryManagerStorage

    private var repositories = [String: RepositoryManager.RepositoryHandle]()
    private var repositoriesLock = Lock()

    private var pendingLookups = [RepositorySpecifier: DispatchGroup]()
    private var pendingLookupsLock = NSLock()

    /// Create a new empty manager.
    ///
    /// - Parameters:
    ///   - path: The path under which to store repositories. This should be a
    ///           directory in which the content can be completely managed by this
    ///           instance.
    ///   - provider: The repository provider.
    ///   - delegate: The repository manager delegate.
    ///   - fileSystem: The filesystem to operate on.
    public init(
        fileSystem: FileSystem,
        path: AbsolutePath,
        provider: RepositoryProvider,
        delegate: RepositoryManagerDelegate? = nil,
        cachePath: AbsolutePath? = nil,
        cacheLocalPackages: Bool? = nil
    ) {
        self.fileSystem = fileSystem
        self.path = path
        self.cachePath = cachePath
        self.cacheLocalPackages = cacheLocalPackages ?? false

        self.provider = provider
        self.delegate = delegate

        self.lookupQueue = OperationQueue()
        self.lookupQueue.name = "org.swift.swiftpm.repository-manager-lookup"
        self.lookupQueue.maxConcurrentOperationCount = Swift.min(3, Concurrency.maxOperations)

        let storagePath = path.appending(component: "checkouts-state.json")
        self.storage = RepositoryManagerStorage(path: storagePath, fileSystem: fileSystem)

        // Load the state from disk, if possible.
        do {
            self.repositories = try self.storage.load(manager: self)
        } catch {
            self.repositories = [:]
            try? self.storage.reset()
            // FIXME: We should emit a warning here using the diagnostic engine.
            TSCBasic.stderrStream.write("warning: unable to restore checkouts state: \(error)")
            TSCBasic.stderrStream.flush()
        }
    }

    /// Get a handle to a repository.
    ///
    /// This will initiate a clone of the repository automatically, if necessary.
    ///
    /// Note: Recursive lookups are not supported i.e. calling lookup inside
    /// completion block of another lookup will block.
    ///
    /// - Parameters:
    ///   - repository: The repository to look up.
    ///   - skipUpdate: If a repository is available, skip updating it.
    ///   - completion: The completion block that should be called after lookup finishes.
    public func lookup(
        repository: RepositorySpecifier,
        skipUpdate: Bool = false,
        on queue: DispatchQueue,
        completion: @escaping LookupCompletion
    ) {
        self.lookupQueue.addOperation {
            // First look for a cached version of the handle.
            // Also check state file / storage for resiliency.
            let cachedHandle = self.storage.fileExists() ? self.repositoriesLock.withLock {
                return self.repositories[repository.location.description]
            } : nil

            if let handle = cachedHandle {
                let result = LookupResult(catching: {
                    let start = DispatchTime.now()
                    // Update the repository when it is being looked up.
                    let repo = try handle.open()

                    // Skip update if asked to.
                    if skipUpdate {
                        return handle
                    }

                    queue.async {
                        self.delegate?.handleWillUpdate(handle: handle)
                    }

                    try repo.fetch()

                    let duration = start.distance(to: .now())
                    queue.async {
                        self.delegate?.handleDidUpdate(handle: handle, duration: duration)
                    }

                    return handle
                })

                return queue.async {
                    completion(result)
                }
            }

            // next we check if there is a pending lookup
            self.pendingLookupsLock.lock()
            if let pendingLookup = self.pendingLookups[repository] {
                self.pendingLookupsLock.unlock()
                // chain onto the pending lookup
                pendingLookup.notify(queue: queue) {
                    // at this point the previous lookup should be complete and we can re-lookup
                    self.lookup(repository: repository, on: queue, completion: completion)
                }
            } else {
                // record the pending lookup
                assert(self.pendingLookups[repository] == nil)
                let group = DispatchGroup()
                group.enter()
                self.pendingLookups[repository] = group
                self.pendingLookupsLock.unlock()

                let subpath = RelativePath(repository.fileSystemIdentifier)
                let handle = RepositoryHandle(manager: self, repository: repository, subpath: subpath)
                let repositoryPath = self.path.appending(handle.subpath)

                // Change the state to pending.
                // Make sure destination is free.
                try? self.fileSystem.removeFileTree(repositoryPath)
                let isCached = self.cachePath.map{ self.fileSystem.exists($0.appending(handle.subpath)) } ?? false

                // Inform delegate.
                queue.async {
                    let details = FetchDetails(fromCache: isCached, updatedCache: false)
                    self.delegate?.fetchingWillBegin(handle: handle, fetchDetails: details)
                }

                let result: LookupResult
                let start = DispatchTime.now()

                // Fetch the repo.
                var fetchError: Swift.Error? = nil
                var fetchDetails: FetchDetails? = nil
                do {
                    // Start fetching.
                    fetchDetails = try self.fetchAndPopulateCache(handle: handle, repositoryPath: repositoryPath, delegateQueue: queue)

                    // Update status to available.
                    result = .success(handle)
                } catch {
                    fetchError = error
                    result = .failure(error)
                }

                // Inform delegate.
                let duration = start.distance(to: .now())
                queue.async {
                    self.delegate?.fetchingDidFinish(handle: handle, fetchDetails: fetchDetails, error: fetchError, duration: duration)
                }

                // if successful, save and cache state
                if case .success = result {
                    do {
                        // Update the serialized repositories map.
                        //
                        // We do this so we don't have to read the other
                        // handles when saving the state of this handle.
                        try self.repositoriesLock.withLock {
                            self.repositories[handle.repository.location.description] = handle
                            try self.storage.save(repositories: self.repositories)
                        }
                    } catch {
                        // FIXME: Handle failure gracefully, somehow.
                        fatalError("unable to save manager state \(error)")
                    }
                }

                // remove the pending lookup
                self.pendingLookupsLock.lock()
                self.pendingLookups[repository]?.leave()
                self.pendingLookups[repository] = nil
                self.pendingLookupsLock.unlock()

                queue.async {
                    completion(result)
                }
            }
        }
    }

    /// Fetches the repository into the cache. If no `cachePath` is set or an error occurred fall back to fetching the repository without populating the cache.
    /// - Parameters:
    ///   - handle: The specifier of the repository to fetch.
    ///   - repositoryPath: The path where the repository should be fetched to.
    ///   - update: Update a repository that is already cached or alternatively fetch the repository into the cache.
    /// - Throws:
    /// - Returns: Details about the performed fetch.
    @discardableResult
    func fetchAndPopulateCache(handle: RepositoryHandle, repositoryPath: AbsolutePath, delegateQueue: DispatchQueue) throws -> FetchDetails {
        var cacheUsed = false
        var cacheUpdated = false

        func updateFetchProgress(progress: FetchProgress) -> Void {
            if let total = progress.totalSteps {
                delegateQueue.async {
                    self.delegate?.fetchingRepository(from: handle.repository.location.description,
                                                      objectsFetched: progress.step,
                                                      totalObjectsToFetch: total)
                }
            }
        }

        // We are expecting handle.repository.url to always be a resolved absolute path.
        let shouldCacheLocalPackages = ProcessEnv.vars["SWIFTPM_TESTS_PACKAGECACHE"] == "1" || cacheLocalPackages

        if let cachePath = self.cachePath, !(handle.repository.isLocal && !shouldCacheLocalPackages) {
            let cachedRepositoryPath = cachePath.appending(component: handle.repository.fileSystemIdentifier)
            do {
                try self.initializeCacheIfNeeded(cachePath: cachePath)
                try fileSystem.withLock(on: cachePath, type: .shared) {
                    try fileSystem.withLock(on: cachedRepositoryPath, type: .exclusive) {
                        // Fetch the repository into the cache.
                        if (fileSystem.exists(cachedRepositoryPath)) {
                            let repo = try self.provider.open(repository: handle.repository, at: cachedRepositoryPath)
                            try repo.fetch(progress: updateFetchProgress(progress:))
                            cacheUsed = true
                        } else {
                            try self.provider.fetch(repository: handle.repository, to: cachedRepositoryPath, progressHandler: updateFetchProgress(progress:))
                        }
                        cacheUpdated = true
                        // Copy the repository from the cache into the repository path.
                        try fileSystem.createDirectory(repositoryPath.parentDirectory, recursive: true)
                        try self.provider.copy(from: cachedRepositoryPath, to: repositoryPath)
                    }
                }
            } catch {
                cacheUsed = false
                // Fetch without populating the cache in the case of an error.
                print("Skipping cache due to an error: \(error)")
                // It is possible that we already created the directory before failing, so clear leftover data if present.
                try fileSystem.removeFileTree(repositoryPath)
                try self.provider.fetch(repository: handle.repository, to: repositoryPath, progressHandler: updateFetchProgress(progress:))
            }
        } else {
            // Fetch without populating the cache when no `cachePath` is set.
            try self.provider.fetch(repository: handle.repository, to: repositoryPath, progressHandler: updateFetchProgress(progress:))
        }
        return FetchDetails(fromCache: cacheUsed, updatedCache: cacheUpdated)
    }

    public func openWorkingCopy(at path: AbsolutePath) throws -> WorkingCheckout {
        try self.provider.openWorkingCopy(at: path)
    }

    /// Open a repository from a handle.
    private func open(_ handle: RepositoryHandle) throws -> Repository {
        try self.provider.open(
            repository: handle.repository,
            at: self.path.appending(handle.subpath)
        )
    }

    /// Create a working copy of the repository from a handle.
    private func createWorkingCopy(
        _ handle: RepositoryHandle,
        at destinationPath: AbsolutePath,
        editable: Bool
    ) throws -> WorkingCheckout {
        try self.provider.createWorkingCopy(
            repository: handle.repository,
            sourcePath: self.path.appending(handle.subpath),
            at: destinationPath,
            editable: editable)
    }

    /// Removes the repository.
    public func remove(repository: RepositorySpecifier) throws {
        try self.repositoriesLock.withLock {
            // If repository isn't present, we're done.
            guard let handle = self.repositories.removeValue(forKey: repository.location.description) else {
                return
            }
            try self.storage.save(repositories: self.repositories)

            let repositoryPath = self.path.appending(handle.subpath)
            try self.fileSystem.removeFileTree(repositoryPath)
        }
    }

    /// Returns true if the directory is valid git location.
    public func isValidDirectory(_ directory: AbsolutePath) -> Bool {
        self.provider.isValidDirectory(directory)
    }

    /// Returns true if the git reference name is well formed.
    public func isValidRefFormat(_ ref: String) -> Bool {
        self.provider.isValidRefFormat(ref)
    }

    /// Reset the repository manager.
    ///
    /// Note: This also removes the cloned repositories from the disk.
    public func reset() throws {
        try self.repositoriesLock.withLock {
            self.repositories.removeAll()
            try self.storage.reset()
            try self.fileSystem.removeFileTree(self.path)
        }
    }

    /// Sets up the cache directories if they don't already exist.
    public func initializeCacheIfNeeded(cachePath: AbsolutePath) throws {
        // Create the supplied cache directory.
        if !self.fileSystem.exists(cachePath) {
            try self.fileSystem.createDirectory(cachePath, recursive: true)
        }
    }

    /// Purges the cached repositories from the cache.
    public func purgeCache() throws {
        guard let cachePath = self.cachePath else { return }
        try self.fileSystem.withLock(on: cachePath, type: .exclusive) {
            let cachedRepositories = try self.fileSystem.getDirectoryContents(cachePath)
            for repoPath in cachedRepositories {
                try self.fileSystem.removeFileTree(cachePath.appending(component: repoPath))
            }
        }
    }
}

extension RepositoryManager {
    /// Handle to a managed repository.
    public struct RepositoryHandle {
        /// The manager this repository is owned by.
        private unowned let manager: RepositoryManager

        /// The repository specifier.
        public let repository: RepositorySpecifier

        /// The subpath of the repository within the manager.
        ///
        /// This is intentionally hidden from the clients so that the manager is
        /// allowed to move repositories transparently.
        fileprivate let subpath: RelativePath

        /// Create a handle.
        fileprivate init(manager: RepositoryManager, repository: RepositorySpecifier, subpath: RelativePath) {
            self.manager = manager
            self.repository = repository
            self.subpath = subpath
        }

        /// Open the given repository.
        public func open() throws -> Repository {
            return try self.manager.open(self)
        }

        /// Create a working copy at on the local file system.
        ///
        /// - Parameters:
        ///   - path: The path at which to create the working copy; it is
        ///           expected to be non-existent when called.
        ///
        ///   - editable: The clone is expected to be edited by user.
        public func createWorkingCopy(at path: AbsolutePath, editable: Bool) throws -> WorkingCheckout {
            return try self.manager.createWorkingCopy(self, at: path, editable: editable)
        }
    }
}

extension RepositoryManager {
    /// Additional information about a fetch
    public struct FetchDetails: Equatable {
        /// Indicates if the repository was fetched from the cache or from the remote.
        public let fromCache: Bool
        /// Indicates wether the wether the repository was already present in the cache and updated or if a clean fetch was performed.
        public let updatedCache: Bool
    }
}

extension RepositoryManager.RepositoryHandle: CustomStringConvertible {
    public var description: String {
        return "<\(type(of: self)) subpath:\(subpath)>"
    }
}


// MARK: - Serialization

fileprivate struct RepositoryManagerStorage {
    private let path: AbsolutePath
    private let fileSystem: FileSystem
    private let encoder = JSONEncoder.makeWithDefaults()
    private let decoder = JSONDecoder.makeWithDefaults()

    init(path: AbsolutePath, fileSystem: FileSystem) {
        self.path = path
        self.fileSystem = fileSystem
    }

    func load(manager: RepositoryManager) throws -> [String: RepositoryManager.RepositoryHandle] {
        if !self.fileSystem.exists(self.path) {
            return [:]
        }

        return try self.fileSystem.withLock(on: self.path, type: .shared) {
            let version = try decoder.decode(path: self.path, fileSystem: self.fileSystem, as: Version.self)
            switch version.version {
            case 1:
                let v1 = try self.decoder.decode(path: self.path, fileSystem: self.fileSystem, as: V1.self)
                return try v1.object.repositories.mapValues{ try .init($0, manager: manager) }
            default:
                throw StringError("unknown 'RepositoryManagerStorage' version '\(version.version)' at '\(self.path)'")
            }
        }
    }

    func save(repositories: [String: RepositoryManager.RepositoryHandle]) throws {
        if !self.fileSystem.exists(self.path.parentDirectory) {
            try self.fileSystem.createDirectory(self.path.parentDirectory)
        }

        try self.fileSystem.withLock(on: self.path, type: .exclusive) {
            let storage = V1(repositories: repositories)
            let data = try self.encoder.encode(storage)
            try self.fileSystem.writeFileContents(self.path, data: data)
        }
    }

    func reset() throws {
        if !self.fileSystem.exists(self.path.parentDirectory) {
            return
        }
        try self.fileSystem.withLock(on: self.path, type: .exclusive) {
            try self.fileSystem.removeFileTree(self.path)
        }
    }

    func fileExists() -> Bool {
        return self.fileSystem.exists(self.path)
    }

    // version reader
    struct Version: Codable {
        let version: Int
    }

    // v1 storage format
    struct V1: Codable {
        let version: Int
        let object: Container

        init(repositories: [String: RepositoryManager.RepositoryHandle]) {
            self.version = 1
            self.object = .init(repositories: repositories.mapValues { .init($0) })
        }

        struct Container: Codable {
            var repositories: [String: Repository]
        }

        struct Repository: Codable {
            let repositoryURL: String
            let subpath: String

            init(_ repository: RepositoryManager.RepositoryHandle) {
                self.repositoryURL = repository.repository.location.description
                self.subpath = repository.subpath.pathString
            }
        }
    }
}

extension RepositoryManager.RepositoryHandle {
    fileprivate init(_ repository: RepositoryManagerStorage.V1.Repository, manager: RepositoryManager) throws {
        // FIXME: encode the type
        let repositorySpecifier: RepositorySpecifier
        if let path = try? AbsolutePath(validating: repository.repositoryURL) {
            repositorySpecifier = .init(path: path)
        } else if let url = URL(string: repository.repositoryURL) {
            repositorySpecifier = .init(url: url)
        } else {
            throw StringError("invalid location :\(repository.repositoryURL)")
        }

        self.init(
            manager: manager,
            repository: repositorySpecifier,
            subpath: RelativePath(repository.subpath)
        )
    }
}

extension RepositorySpecifier {
    fileprivate var isLocal: Bool {
        switch self.location {
        case .path:
            return true
        case .url:
            return false
        }
    }
}
