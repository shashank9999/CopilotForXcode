import Foundation
import SwiftUI


public func drawFileIcon(_ file: URL?) -> Image {
    let defaultImage = Image(systemName: "doc.text")
    
    guard let file = file else { return defaultImage }
    
    let fileExtension = file.pathExtension.lowercased()
    if fileExtension == "swift" {
        if let nsImage = NSImage(named: "SwiftIcon") {
            return Image(nsImage: nsImage)
        }
    }

    return defaultImage
}
