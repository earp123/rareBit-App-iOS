import SwiftUI

struct HapticPlaybackView: View {
    @State private var currentPreset: HapticPreset = .doubleNotification
    @State private var isPlaying = false

    var body: some View {
        VStack {
            Spacer()

            Button {
                guard !isPlaying else { return }
                let preset = currentPreset
                currentPreset = currentPreset.next()
                isPlaying = true
                Task {
                    await preset.play()
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

            Spacer()
        }
        .padding()
    }
}
