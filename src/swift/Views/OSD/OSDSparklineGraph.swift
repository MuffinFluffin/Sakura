// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

struct OSDSparklineGraph: View {
    let values: [Double]
    let color: Color
    var lineWidth: CGFloat = 1.2
    var maxValue: Double? = nil

    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard values.count > 1 else { return }
                let upper = maxValue ?? max(values.max() ?? 1, 1)
                let step = geo.size.width / CGFloat(values.count - 1)
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * step
                    let y = geo.size.height * (1 - CGFloat(min(v / upper, 1)))
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}
