import SwiftUI

final class NotchModel: ObservableObject {
    @Published var state = BeaconState.empty
    @Published var connected = false
    var onAcknowledge: () -> Void = {}
}

/// A black capsule that extends the notch to the right: pulsing light, then the number of sessions
/// asking you. Click to mark them seen.
struct NotchView: View {
    @ObservedObject var model: NotchModel
    let notchWidth: CGFloat
    let height: CGFloat
    @State private var pulse = false

    private let color = Color(red: 245 / 255, green: 170 / 255, blue: 0)  // amber, same as the menu bar

    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: notchWidth)
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
                    .shadow(color: color, radius: pulse ? 9 : 3)
                Text("\(model.state.waiting)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(color)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .onTapGesture { model.onAcknowledge() }
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 14)
                .fill(Color.black)
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
