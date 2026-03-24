import SwiftUI

struct HapticPlaybackView: View {
    @State private var currentPreset: HapticPreset = .doubleNotification
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Button {
                guard !isPlaying else { return }
                isPlaying = true
                Task {
                    await currentPreset.play()
                    isPlaying = false
                }
            } label: {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(currentPreset.color, lineWidth: 3)
                    .frame(width: 90, height: 90)
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.title)
                            .foregroundStyle(currentPreset.color)
                    )
            }
            .buttonStyle(.plain)

            Button {
                currentPreset = currentPreset.next()
            } label: {
                Text("Next")
                    .font(.footnote)
                    .fontWeight(.medium)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .stroke(currentPreset.color, lineWidth: 1.5)
                    )
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding()
    }
}
