import SwiftUI

struct GitStatusBadge: View {
    let status: String

    private var color: Color {
        switch status {
        case "A": .green
        case "M", "T": .orange
        case "U": .cyan
        case "D": .red
        case "R", "C": .purple
        default: .secondary
        }
    }

    private var meaning: String {
        switch status {
        case "A": "Added"
        case "M": "Modified"
        case "U": "Untracked or conflicted"
        case "D": "Deleted"
        case "R": "Renamed"
        case "C": "Copied"
        case "T": "File type changed"
        default: "Git status \(status)"
        }
    }

    var body: some View {
        Text(status)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
            .help(meaning)
            .accessibilityLabel("\(status): \(meaning)")
    }
}
