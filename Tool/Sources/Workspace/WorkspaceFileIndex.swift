import Foundation
import ConversationServiceProvider

public class WorkspaceFileIndex {
    public static let shared = WorkspaceFileIndex()
    /// Maximum number of files allowed per workspace
    public static let maxFilesPerWorkspace = 1_000_000

    private var workspaceIndex: [URL: [FileReference]] = [:]
    private let queue = DispatchQueue(label: "com.copilot.workspace-file-index")

    /// Reset files for a specific workspace URL
    public func setFiles(_ files: [FileReference], for workspaceURL: URL) {
        queue.sync {
            // Enforce the file limit when setting files
            if files.count > Self.maxFilesPerWorkspace {
                self.workspaceIndex[workspaceURL] = Array(files.prefix(Self.maxFilesPerWorkspace))
            } else {
                self.workspaceIndex[workspaceURL] = files
            }
        }
    }

    /// Get all files for a specific workspace URL
    public func getFiles(for workspaceURL: URL) -> [FileReference]? {
        return workspaceIndex[workspaceURL]
    }

    /// Add a file to the workspace index
    /// - Returns: true if the file was added successfully, false if the workspace has reached the maximum file limit
    @discardableResult
    public func addFile(_ file: FileReference, to workspaceURL: URL) -> Bool {
        return queue.sync {
            if self.workspaceIndex[workspaceURL] == nil {
                self.workspaceIndex[workspaceURL] = []
            }

            // Check if we've reached the maximum file limit
            let currentFileCount = self.workspaceIndex[workspaceURL]!.count
            if currentFileCount >= Self.maxFilesPerWorkspace {
                return false
            }

            // Avoid duplicates by checking if file already exists
            if !self.workspaceIndex[workspaceURL]!.contains(file) {
                self.workspaceIndex[workspaceURL]!.append(file)
                return true
            }

            return true // File already exists, so we consider this a successful "add"
        }
    }

    /// Remove a file from the workspace index
    public func removeFile(_ file: FileReference, from workspaceURL: URL) {
        queue.sync {
            self.workspaceIndex[workspaceURL]?.removeAll { $0 == file }
        }
    }
}
