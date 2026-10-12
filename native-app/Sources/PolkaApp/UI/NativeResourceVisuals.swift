import PolkaCore
import SwiftUI

private let resourceVisualColor = Color(red: 0.48, green: 0.72, blue: 0.96)

struct NativeResourceMeter: View {
  var fraction: Double
  var label: String
  var warning = false
  var body: some View {
    let progress = fraction.isFinite ? min(1, max(0, fraction)) : 0
    let percentage =
      progress > 0 && progress < 0.001
      ? localized(
        "<{0}",
        0.001.formatted(
          .percent.precision(.fractionLength(1)).locale(AppLocalization.language.locale)))
      : progress.formatted(
        .percent.precision(.fractionLength(0...1)).locale(AppLocalization.language.locale))
    VStack(spacing: 4) {
      GeometryReader { geometry in
        Capsule().fill(.white.opacity(0.12))
          .overlay(alignment: .leading) {
            Capsule().fill(warning ? Color.orange : resourceVisualColor)
              .frame(width: geometry.size.width * progress)
          }
      }.frame(height: 5)
      HStack {
        Text(label)
        Spacer(minLength: 6)
        Text(percentage).monospacedDigit()
      }.font(.system(size: 11)).foregroundStyle(.secondary)
    }.accessibilityElement(children: .ignore).accessibilityLabel(label)
      .accessibilityValue(percentage)
  }
}

struct NativeActivityPoint {
  var time: Double
  var value: Double
}
struct NativeActivityLine {
  var points: [NativeActivityPoint]
  var upload = false
}

/// Canvas draws only the bounded samples. It has no animation or sampling timer.
struct NativeResourceActivityChart: View {
  var lines: [NativeActivityLine]
  var domain: ClosedRange<Double>
  var now: Double
  var scaleLabel: String
  var label: String
  private var duration: Double {
    let oldest = lines.flatMap(\.points).map(\.time).min() ?? now
    return min(SystemActivityHistory.duration, max(2, now - oldest))
  }
  var body: some View {
    VStack(spacing: 4) {
      Canvas { context, size in
        let plot = CGRect(
          x: 1, y: 2, width: max(1, size.width - 2), height: max(1, size.height - 4))
        var baseline = Path()
        baseline.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        baseline.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        context.stroke(baseline, with: .color(.white.opacity(0.13)), lineWidth: 1)
        for line in lines {
          let points = line.points.map { sample -> CGPoint in
            let x = min(1, max(0, (sample.time - now + duration) / duration))
            let y = min(
              1,
              max(
                0,
                (sample.value - domain.lowerBound) / max(1, domain.upperBound - domain.lowerBound)))
            return CGPoint(x: plot.minX + x * plot.width, y: plot.maxY - y * plot.height)
          }
          let color = line.upload ? Color.secondary : resourceVisualColor
          if points.count == 1, let point = points.first {
            context.fill(
              Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)),
              with: .color(color))
          } else {
            var path = Path()
            for (index, point) in points.enumerated() {
              if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(
              path, with: .color(color),
              style: StrokeStyle(
                lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: line.upload ? [3, 3] : []))
          }
        }
      }.frame(height: 30)
      HStack(spacing: 4) {
        Text(localized("{0}s ago", String(Int(duration))))
        Spacer(minLength: 2)
        Text(scaleLabel).monospacedDigit()
        Spacer(minLength: 2)
        Text(localized("Now"))
      }.font(.system(size: 11)).foregroundStyle(.secondary)
    }.accessibilityElement(children: .ignore).accessibilityLabel(label)
      .accessibilityValue(localized("{0} seconds · {1}", String(Int(duration)), scaleLabel))
  }
}

struct NativeActivityLineKey: View {
  var upload = false
  var body: some View {
    Canvas { context, size in
      var path = Path()
      path.move(to: CGPoint(x: 0, y: size.height / 2))
      path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
      context.stroke(
        path, with: .color(upload ? .secondary : resourceVisualColor),
        style: StrokeStyle(lineWidth: 1.5, dash: upload ? [3, 3] : []))
    }.frame(width: 12, height: 5).accessibilityHidden(true)
  }
}
