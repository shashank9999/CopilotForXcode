import SwiftUI

struct BadgeItem {
    enum Level: String, Equatable {
        case warning = "Warning"
        case danger = "Danger"
    }
    let text: String
    let level: Level
    let icon: String?
    
    init(text: String, level: Level, icon: String? = nil) {
        self.text = text
        self.level = level
        self.icon = icon
    }
}

struct Badge: View {
    let text: String
    let level: BadgeItem.Level
    let icon: String?
    
    init(badgeItem: BadgeItem) {
        self.text = badgeItem.text
        self.level = badgeItem.level
        self.icon = badgeItem.icon
    }
    
    init(text: String, level: BadgeItem.Level, icon: String? = nil) {
        self.text = text
        self.level = level
        self.icon = icon
    }
    
    var body: some View {
        HStack(spacing: 4) {
            if let icon = icon {
                Image(systemName: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 11, height: 11)
            }
            Text(text)
                .fontWeight(.semibold)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .foregroundColor(
            Color("\(level.rawValue)ForegroundColor")
        )
        .background(
            Color("\(level.rawValue)BackgroundColor"),
            in: RoundedRectangle(
                cornerRadius: 9999,
                style: .circular
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: 9999,
                style: .circular
            )
            .stroke(Color("\(level.rawValue)StrokeColor"), lineWidth: 1)
        )
    }
}
