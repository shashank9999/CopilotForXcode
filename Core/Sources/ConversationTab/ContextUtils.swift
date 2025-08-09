import ConversationServiceProvider
import XcodeInspector
import Foundation
import Logger
import Workspace
import SystemUtils

public struct ContextUtils {

    public static func getFilesFromWorkspaceIndex(workspaceURL: URL?) -> [FileReference]? {
        guard let workspaceURL = workspaceURL else { return [] }
        return WorkspaceFileIndex.shared.getFiles(for: workspaceURL)
    }

    public static func getFilesInActiveWorkspace(workspaceURL: URL?) -> [FileReference] {
        if let workspaceURL = workspaceURL, let info = WorkspaceFile.getWorkspaceInfo(workspaceURL: workspaceURL) {
            return WorkspaceFile.getFilesInActiveWorkspace(workspaceURL: info.workspaceURL, workspaceRootURL: info.projectURL)
        }

        guard let workspaceURL = XcodeInspector.shared.realtimeActiveWorkspaceURL,
              let workspaceRootURL = XcodeInspector.shared.realtimeActiveProjectURL else {
            return []
        }
        
        let files = WorkspaceFile.getFilesInActiveWorkspace(workspaceURL: workspaceURL, workspaceRootURL: workspaceRootURL)
        
        return files
    }
    
    public static let workspaceReadabilityErrorMessageProvider: FileUtils.ReadabilityErrorMessageProvider = { status in
        switch status {
        case .readable: return nil
        case .notFound: 
            return "Copilot can't access this workspace. It may have been removed or is temporarily unavailable."
        case .permissionDenied: 
            return "Copilot can't access this workspace. Enable \"Files & Folders\" access in [System Settings](x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders)"
        }
    }
}
