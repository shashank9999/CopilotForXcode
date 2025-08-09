import SwiftUI
import ConversationServiceProvider
import ComposableArchitecture
import Combine
import ChatService

struct ProgressStep: View {
    let steps: [ConversationProgressStep]
    
    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(steps) { StatusItemView(step: $0) }
            }
            .foregroundStyle(.secondary)
        }
    }
}


struct StatusItemView: View {
    
    let step: ConversationProgressStep
    
    @AppStorage(\.chatFontSize) var chatFontSize
    
    var statusIcon: some View {
        Group {
            switch step.status {
            case .running:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
                    .scaleEffect(0.7)
            case .completed:
                Image(systemName: "checkmark")
                    .foregroundColor(.green)
            case .failed:
                Image(systemName: "xmark.circle")
                    .foregroundColor(.red)
            case .cancelled:
                Image(systemName: "slash.circle")
                    .foregroundColor(.gray)
            }
        }
    }
    
    var statusTitle: some View {
        var title = step.title
        if step.id == ProjectContextSkill.ProgressID && step.status == .failed {
            title = step.error?.message ?? step.title
        }
        return Text(title)
    }
    
    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 4) {
                statusIcon
                    .frame(width: 16, height: 16)
                
                statusTitle
                    .font(.system(size: chatFontSize))
                    .lineLimit(1)
                
                Spacer()
            }
        }
    }
}

struct ProgressStep_Preview: PreviewProvider {
    static let steps: [ConversationProgressStep] = [
        .init(id: "001", title: "running step", description: "this is running step", status: .running, error: nil),
        .init(id: "002", title: "completed step", description: "this is completed step", status: .completed, error: nil),
        .init(id: "003", title: "failed step", description: "this is failed step", status: .failed, error: nil),
        .init(id: "004", title: "cancelled step", description: "this is cancelled step", status: .cancelled, error: nil)
    ]
    static var previews: some View {
        ProgressStep(steps: steps)
            .frame(width: 300, height: 300)
    }
}
