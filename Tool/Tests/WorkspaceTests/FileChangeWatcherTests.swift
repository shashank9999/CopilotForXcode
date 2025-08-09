import ConversationServiceProvider
import CoreServices
import Foundation
import LanguageServerProtocol
@testable import Workspace
import XCTest

// MARK: - Mocks for Testing

class MockFSEventProvider: FSEventProvider {
    var createdStream: FSEventStreamRef?
    var didStartStream = false
    var didStopStream = false
    var didInvalidateStream = false
    var didReleaseStream = false
    var didSetDispatchQueue = false
    var registeredCallback: FSEventStreamCallback?
    var registeredContext: UnsafeMutablePointer<FSEventStreamContext>?
    
    var simulatedFiles: [String] = []
    
    func createEventStream(
        paths: CFArray,
        latency: CFTimeInterval,
        flags: UInt32,
        callback: @escaping FSEventStreamCallback,
        context: UnsafeMutablePointer<FSEventStreamContext>
    ) -> FSEventStreamRef? {
        registeredCallback = callback
        registeredContext = context
        let stream = unsafeBitCast(1, to: FSEventStreamRef.self)
        createdStream = stream
        return stream
    }
    
    func startStream(_ stream: FSEventStreamRef) {
        didStartStream = true
    }
    
    func stopStream(_ stream: FSEventStreamRef) {
        didStopStream = true
    }
    
    func invalidateStream(_ stream: FSEventStreamRef) {
        didInvalidateStream = true
    }
    
    func releaseStream(_ stream: FSEventStreamRef) {
        didReleaseStream = true
    }
    
    func setDispatchQueue(_ stream: FSEventStreamRef, queue: DispatchQueue) {
        didSetDispatchQueue = true
    }
}

class MockWorkspaceFileProvider: WorkspaceFileProvider {
    var subprojects: [URL] = []
    var filesInWorkspace: [FileReference] = []
    var xcProjectPaths: Set<String> = []
    var xcWorkspacePaths: Set<String> = []
    
    func getProjects(by workspaceURL: URL) -> [URL] {
        return subprojects
    }
    
    func getFilesInActiveWorkspace(workspaceURL: URL, workspaceRootURL: URL) -> [FileReference] {
        return filesInWorkspace
    }
    
    func isXCProject(_ url: URL) -> Bool {
        return xcProjectPaths.contains(url.path)
    }
    
    func isXCWorkspace(_ url: URL) -> Bool {
        return xcWorkspacePaths.contains(url.path)
    }

    func fileExists(atPath: String) -> Bool {
        return true
    }
}

class MockFileWatcher: FileWatcherProtocol {
    var fileURL: URL
    var dispatchQueue: DispatchQueue?
    var onFileModified: (() -> Void)?
    var onFileDeleted: (() -> Void)?
    var onFileRenamed: (() -> Void)?

    static var watchers = [URL: MockFileWatcher]()

    init(fileURL: URL, dispatchQueue: DispatchQueue? = nil, onFileModified: (() -> Void)? = nil, onFileDeleted: (() -> Void)? = nil, onFileRenamed: (() -> Void)? = nil) {
        self.fileURL = fileURL
        self.dispatchQueue = dispatchQueue
        self.onFileModified = onFileModified
        self.onFileDeleted = onFileDeleted
        self.onFileRenamed = onFileRenamed
        MockFileWatcher.watchers[fileURL] = self
    }

    func startWatching() -> Bool {
        return true
    }

    func stopWatching() {
        MockFileWatcher.watchers[fileURL] = nil
    }

    static func triggerFileDelete(for fileURL: URL) {
        guard let watcher = watchers[fileURL] else { return }
        watcher.onFileDeleted?()
    }
}

class MockFileWatcherFactory: FileWatcherFactory {
    func createFileWatcher(fileURL: URL, dispatchQueue: DispatchQueue?, onFileModified: (() -> Void)?, onFileDeleted: (() -> Void)?, onFileRenamed: (() -> Void)?) -> FileWatcherProtocol {
        return MockFileWatcher(fileURL: fileURL, dispatchQueue: dispatchQueue, onFileModified: onFileModified, onFileDeleted: onFileDeleted, onFileRenamed: onFileRenamed)
    }
    
    func createDirectoryWatcher(watchedPaths: [URL], changePublisher: @escaping PublisherType, publishInterval: TimeInterval) -> DirectoryWatcherProtocol {
        return BatchingFileChangeWatcher(
            watchedPaths: watchedPaths,
            changePublisher: changePublisher,
            fsEventProvider: MockFSEventProvider()
        )
    }
}

// MARK: - Tests for BatchingFileChangeWatcher

final class BatchingFileChangeWatcherTests: XCTestCase {
    var mockFSEventProvider: MockFSEventProvider!
    var publishedEvents: [[FileEvent]] = []
    
    override func setUp() {
        super.setUp()
        mockFSEventProvider = MockFSEventProvider()
        publishedEvents = []
    }
    
    func createWatcher(projectURL: URL = URL(fileURLWithPath: "/test/project")) -> BatchingFileChangeWatcher {
        return BatchingFileChangeWatcher(
            watchedPaths: [projectURL],
            changePublisher: { [weak self] events in
                self?.publishedEvents.append(events)
            },
            publishInterval: 0.1,
            fsEventProvider: mockFSEventProvider
        )
    }
    
    func testInitSetsUpTimerAndFileWatching() {
        let _ = createWatcher()
        
        XCTAssertNotNil(mockFSEventProvider.createdStream)
        XCTAssertTrue(mockFSEventProvider.didStartStream)
    }
    
    func testDeinitCleansUpResources() {
        var watcher: BatchingFileChangeWatcher? = createWatcher()
        weak var weakWatcher = watcher
        
        watcher = nil
        
        // Wait for the watcher to be deallocated
        let startTime = Date()
        let timeout: TimeInterval = 1.0
        
        while weakWatcher != nil && Date().timeIntervalSince(startTime) < timeout {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        
        XCTAssertTrue(mockFSEventProvider.didStopStream)
        XCTAssertTrue(mockFSEventProvider.didInvalidateStream)
        XCTAssertTrue(mockFSEventProvider.didReleaseStream)
    }
    
    func testAddingEventsAndPublishing() {
        let watcher = createWatcher()
        let fileURL = URL(fileURLWithPath: "/test/project/file.swift")
        
        watcher.onFileCreated(file: fileURL)
        
        // No events should be published yet
        XCTAssertTrue(publishedEvents.isEmpty)
        
        XCTAssertTrue(waitForPublishedEvents(), "No events were published within timeout")
        
        // Only verify array contents if we have events
        guard !publishedEvents.isEmpty else { return }
        
        XCTAssertEqual(publishedEvents[0].count, 1)
        XCTAssertEqual(publishedEvents[0][0].uri, fileURL.absoluteString)
        XCTAssertEqual(publishedEvents[0][0].type, .created)
    }
    
    func testProcessingFSEvents() {
        let watcher = createWatcher()
        let fileURL = URL(fileURLWithPath: "/test/project/file.swift")
        
        // Test file creation - directly call methods instead of simulating FS events
        watcher.onFileCreated(file: fileURL)
        XCTAssertTrue(waitForPublishedEvents(), "No events were published within timeout")
        
        guard !publishedEvents.isEmpty else { return }
        XCTAssertEqual(publishedEvents[0].count, 1)
        XCTAssertEqual(publishedEvents[0][0].type, .created)
        
        // Test file modification
        publishedEvents = []
        watcher.onFileChanged(file: fileURL)
        
        XCTAssertTrue(waitForPublishedEvents(), "No events were published within timeout")
        
        guard !publishedEvents.isEmpty else { return }
        XCTAssertEqual(publishedEvents[0].count, 1)
        XCTAssertEqual(publishedEvents[0][0].type, .changed)
        
        // Test file deletion
        publishedEvents = []
        watcher.onFileDeleted(file: fileURL)
        XCTAssertTrue(waitForPublishedEvents(), "No events were published within timeout")
        
        guard !publishedEvents.isEmpty else { return }
        XCTAssertEqual(publishedEvents[0].count, 1)
        XCTAssertEqual(publishedEvents[0][0].type, .deleted)
    }
}

extension BatchingFileChangeWatcherTests {
    func waitForPublishedEvents(timeout: TimeInterval = 1.0) -> Bool {
        let start = Date()
        while publishedEvents.isEmpty && Date().timeIntervalSince(start) < timeout {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        return !publishedEvents.isEmpty
    }
}

// MARK: - Tests for FileChangeWatcherService

final class FileChangeWatcherServiceTests: XCTestCase {
    var mockWorkspaceFileProvider: MockWorkspaceFileProvider!
    var publishedEvents: [[FileEvent]] = []
    
    override func setUp() {
        super.setUp()
        mockWorkspaceFileProvider = MockWorkspaceFileProvider()
        publishedEvents = []
    }
    
    func createService(workspaceURL: URL = URL(fileURLWithPath: "/test/workspace")) -> FileChangeWatcherService {
        return FileChangeWatcherService(
            workspaceURL,
            publisher: { [weak self] events in
                self?.publishedEvents.append(events)
            },
            publishInterval: 0.1,
            workspaceFileProvider: mockWorkspaceFileProvider,
            watcherFactory: MockFileWatcherFactory()
        )
    }
    
    func testStartWatchingCreatesWatchersForProjects() {
        let project1 = URL(fileURLWithPath: "/test/workspace/project1")
        let project2 = URL(fileURLWithPath: "/test/workspace/project2")
        mockWorkspaceFileProvider.subprojects = [project1, project2]
        
        let service = createService()
        service.startWatching()
        
        XCTAssertNotNil(service.watcher)
        XCTAssertEqual(service.watcher?.paths().count, 2)
        XCTAssertEqual(service.watcher?.paths(), [project1, project2])
    }
    
    func testStartWatchingDoesNotCreateWatcherForRootDirectory() {
        let service = createService(workspaceURL: URL(fileURLWithPath: "/"))
        service.startWatching()
        
        XCTAssertNil(service.watcher)
    }
    
    func testProjectMonitoringDetectsAddedProjects() {
        let workspace = URL(fileURLWithPath: "/test/workspace")
        let project1 = URL(fileURLWithPath: "/test/workspace/project1")
        mockWorkspaceFileProvider.subprojects = [project1]
        mockWorkspaceFileProvider.xcWorkspacePaths = [workspace.path]
        
        let service = createService(workspaceURL: workspace)
        service.startWatching()
        
        XCTAssertNotNil(service.watcher)
        
        // Simulate adding a new project
        let project2 = URL(fileURLWithPath: "/test/workspace/project2")
        mockWorkspaceFileProvider.subprojects = [project1, project2]
        
        // Set up mock files for the added project
        let file1URL = URL(fileURLWithPath: "/test/workspace/project2/file1.swift")
        let file1 = FileReference(
            url: file1URL,
            relativePath: file1URL.relativePath,
            fileName: file1URL.lastPathComponent
        )
        let file2URL = URL(fileURLWithPath: "/test/workspace/project2/file2.swift")
        let file2 = FileReference(
            url: file2URL,
            relativePath: file2URL.relativePath,
            fileName: file2URL.lastPathComponent
        )
        mockWorkspaceFileProvider.filesInWorkspace = [file1, file2]

        MockFileWatcher.triggerFileDelete(for: workspace.appendingPathComponent("contents.xcworkspacedata"))
        
        XCTAssertTrue(waitForPublishedEvents(), "No events were published within timeout")
        
        guard !publishedEvents.isEmpty else { return }
        
        // Verify file events were published
        XCTAssertEqual(publishedEvents[0].count, 2)
        
        // Verify both files were reported as created
        XCTAssertEqual(publishedEvents[0][0].type, .created)
        XCTAssertEqual(publishedEvents[0][1].type, .created)
    }
    
    func testProjectMonitoringDetectsRemovedProjects() {
        let workspace = URL(fileURLWithPath: "/test/workspace")
        let project1 = URL(fileURLWithPath: "/test/workspace/project1")
        let project2 = URL(fileURLWithPath: "/test/workspace/project2")
        mockWorkspaceFileProvider.subprojects = [project1, project2]
        mockWorkspaceFileProvider.xcWorkspacePaths = [workspace.path]
        
        let service = createService(workspaceURL: workspace)
        service.startWatching()
        
        XCTAssertNotNil(service.watcher)
        
        // Simulate removing a project
        mockWorkspaceFileProvider.subprojects = [project1]
        
        // Set up mock files for the removed project
        let file1URL = URL(fileURLWithPath: "/test/workspace/project2/file1.swift")
        let file1 = FileReference(
            url: file1URL,
            relativePath: file1URL.relativePath,
            fileName: file1URL.lastPathComponent
        )
        let file2URL = URL(fileURLWithPath: "/test/workspace/project2/file2.swift")
        let file2 = FileReference(
            url: file2URL,
            relativePath: file2URL.relativePath,
            fileName: file2URL.lastPathComponent
        )
        mockWorkspaceFileProvider.filesInWorkspace = [file1, file2]
        
        // Clear published events from setup
        publishedEvents = []

        MockFileWatcher.triggerFileDelete(for: workspace.appendingPathComponent("contents.xcworkspacedata"))
                
        XCTAssertTrue(waitForPublishedEvents(), "No events were published within timeout")
            
        guard !publishedEvents.isEmpty else { return }
        
        // Verify file events were published
        XCTAssertEqual(publishedEvents[0].count, 2)
        
        // Verify both files were reported as deleted
        XCTAssertEqual(publishedEvents[0][0].type, .deleted)
        XCTAssertEqual(publishedEvents[0][1].type, .deleted)
    }
}

extension FileChangeWatcherServiceTests {
    func waitForPublishedEvents(timeout: TimeInterval = 3.0) -> Bool {
        let start = Date()
        while publishedEvents.isEmpty && Date().timeIntervalSince(start) < timeout {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        return !publishedEvents.isEmpty
    }
}
