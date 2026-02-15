import SwiftUI

struct AudioWaveView: View {
    var level: CGFloat // 0...1
    var color: Color = .white

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let barLevel = barHeight(index: i, level: level)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3)
                    .frame(height: max(4, barLevel * 24))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
    }

    private func barHeight(index: Int, level: CGFloat) -> CGFloat {
        let offsets: [CGFloat] = [0.7, 0.9, 1.0, 0.85, 0.75]
        return level * offsets[index]
    }
}
