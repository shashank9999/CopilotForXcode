import JSONRPC
import Combine
import Workspace
import XcodeInspector
import Foundation
import ConversationServiceProvider

public protocol WatchedFilesHandler {
    func handleWatchedFiles(_ request: WatchedFilesRequest, workspaceURL: URL, completion: @escaping (AnyJSONRPCResponse) -> Void, service: GitHubCopilotService?)
}

public final class WatchedFilesHandlerImpl: WatchedFilesHandler {
    public static let shared = WatchedFilesHandlerImpl()

    public func handleWatchedFiles(_ request: WatchedFilesRequest, workspaceURL: URL, completion: @escaping (AnyJSONRPCResponse) -> Void, service: GitHubCopilotService?) {
        guard let params = request.params, params.workspaceFolder.uri != "/" else { return }

        let projectURL = WorkspaceXcodeWindowInspector.extractProjectURL(workspaceURL: workspaceURL, documentURL: nil) ?? workspaceURL
        
        let files = WorkspaceFile.getWatchedFiles(
            workspaceURL: workspaceURL,
            projectURL: projectURL,
            excludeGitIgnoredFiles: params.excludeGitignoredFiles,
            excludeIDEIgnoredFiles: params.excludeIDEIgnoredFiles
        )
        WorkspaceFileIndex.shared.setFiles(files, for: workspaceURL)

        let fileUris = files.prefix(10000).map { $0.url.absoluteString } // Set max number of indexing file to 10000
        
        let batchSize = BatchingFileChangeWatcher.maxEventPublishSize
        /// only `batchSize`(100) files to complete this event for setup watching workspace in CLS side
        let jsonResult: JSONValue = .array(fileUris.prefix(batchSize).map { .hash(["uri": .string($0)]) })
        let jsonValue: JSONValue = .hash(["files": jsonResult])
        
        completion(AnyJSONRPCResponse(id: request.id, result: jsonValue))
        
        Task {
            if fileUris.count > batchSize {
                for startIndex in stride(from: batchSize, to: fileUris.count, by: batchSize) {
                    let endIndex = min(startIndex + batchSize, fileUris.count)
                    let batch = Array(fileUris[startIndex..<endIndex])
                    try? await service?.notifyDidChangeWatchedFiles(.init(
                        workspaceUri: params.workspaceFolder.uri,
                        changes: batch.map { .init(uri: $0, type: .created)}
                    ))
                    
                    try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                }
            }
        }
        
        startFileChangeWatcher(workspaceURL: workspaceURL, projectURL: projectURL, service: service)
    }

    func startFileChangeWatcher(workspaceURL: URL, projectURL: URL, service: GitHubCopilotService?) {
        Task {
            await FileChangeWatcherServicePool.shared.watch(
                for: workspaceURL
            ) { fileEvents in
                // Update the local file index with file events
                fileEvents.forEach { event in
                    let fileURL = URL(string: event.uri)!
                    let relativePath = fileURL.path.replacingOccurrences(of: projectURL.path, with: "")
                    let fileName = fileURL.lastPathComponent
                    let file = FileReference(url: fileURL, relativePath: relativePath, fileName: fileName)
                    if event.type == .deleted {
                        WorkspaceFileIndex.shared.removeFile(file, from: workspaceURL)
                    } else {
                        WorkspaceFileIndex.shared.addFile(file, to: workspaceURL)
                    }
                }

                Task {
                    try? await service?.notifyDidChangeWatchedFiles(
                        .init(workspaceUri: projectURL.path, changes: fileEvents))
                }
            }
        }
    }
}
