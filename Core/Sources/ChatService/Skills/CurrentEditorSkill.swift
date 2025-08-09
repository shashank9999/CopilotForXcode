import ConversationServiceProvider
import Foundation
import GitHubCopilotService
import JSONRPC
import SystemUtils

public class CurrentEditorSkill: ConversationSkill {
    public static let ID = "current-editor"
    public let currentFile: FileReference
    public var id: String {
        return CurrentEditorSkill.ID
    }
    public var currentFilePath: String { currentFile.url.path }
    
    public init(
        currentFile: FileReference
    ) {
        self.currentFile = currentFile
    }

    public func applies(params: ConversationContextParams) -> Bool {
        return params.skillId == self.id
    }
    
    public static let readabilityErrorMessageProvider: FileUtils.ReadabilityErrorMessageProvider = { status in
        switch status {
        case .readable:
            return nil
        case .notFound:
            return "Copilot can’t find the current file, so it's not included."
        case .permissionDenied:
            return "Copilot can't access the current file. Enable \"Files & Folders\" access in [System Settings](x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders)."
        }
    }
    
    public func resolveSkill(request: ConversationContextRequest, completion: JSONRPCResponseHandler){
        let uri: String? = self.currentFile.url.absoluteString
        completion(
            AnyJSONRPCResponse(id: request.id,
                               result: JSONValue.array([
                                    JSONValue.hash(["uri" : .string(uri ?? "")]),
                                    JSONValue.null
                               ]))
        )
    }
}
