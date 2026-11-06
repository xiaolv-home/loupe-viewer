import SwiftUI
import AppKit
import LoupeCore

/// Crop marks around a rectangle, drawn as a SwiftUI shape. `extend` grows the marks
/// (used as the drop affordance).
struct CropMarks: Shape {
    var gap: CGFloat = 6
    var length: CGFloat = 14
    var animatableData: CGFloat {
        get { length }
        set { length = newValue }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        for (x, y, dx, dy) in [(r.minX, r.minY, -1.0, -1.0), (r.maxX, r.minY, 1.0, -1.0),
                               (r.minX, r.maxY, -1.0, 1.0), (r.maxX, r.maxY, 1.0, 1.0)] {
            p.move(to: CGPoint(x: x + dx * gap, y: y)); p.addLine(to: CGPoint(x: x + dx * (gap + length), y: y))
            p.move(to: CGPoint(x: x, y: y + dy * gap)); p.addLine(to: CGPoint(x: x, y: y + dy * (gap + length)))
        }
        return p
    }
}

/// Format mark: a square ink swatch followed by the letter-spaced type token.
struct FormatBadge: View {
    let token: String
    let category: FormatCategory
    var size: CGFloat = 9.5

    var body: some View {
        HStack(spacing: 5) {
            Rectangle().fill(Theme.tint(category)).frame(width: size * 0.85, height: size * 0.85)
            Text(token.prefix(7))
                .font(.system(size: size, weight: .bold, design: .default))
                .tracking(1.6)
                .foregroundStyle(.primary.opacity(0.85))
        }
        .fixedSize()
    }
}

/// Printer's registration mark (circle + cross), drawn small.
struct RegistrationMark: View {
    var size: CGFloat = 11
    var color: Color = .primary.opacity(0.45)
    var body: some View {
        Canvas { ctx, sz in
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let r = min(sz.width, sz.height) / 2 * 0.62
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color), lineWidth: 0.9)
            var p = Path()
            p.move(to: CGPoint(x: 0, y: c.y)); p.addLine(to: CGPoint(x: sz.width, y: c.y))
            p.move(to: CGPoint(x: c.x, y: 0)); p.addLine(to: CGPoint(x: c.x, y: sz.height))
            ctx.stroke(p, with: .color(color), lineWidth: 0.9)
        }
        .frame(width: size, height: size)
    }
}

/// Printer's colour bar: a row of swatches stepping down in density.
struct ColorBar: View {
    let category: FormatCategory
    var body: some View {
        HStack(spacing: 0) {
            ForEach([1.0, 0.7, 0.45, 0.25], id: \.self) { o in
                Rectangle().fill(Theme.tint(category).opacity(o)).frame(width: 7, height: 7)
            }
            Rectangle().fill(Color.primary.opacity(0.85)).frame(width: 7, height: 7)
            Rectangle().fill(Theme.ember).frame(width: 7, height: 7)
        }
    }
}

/// Small-caps style section label.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(2.2)
            .foregroundStyle(.secondary)
    }
}

/// Compact icon button used in the lens bar and status strip.
struct LensButton: View {
    let symbol: String
    var help: String = ""
    var active: Bool = false
    var enabled: Bool = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 28, height: 24)
                .foregroundStyle(active ? Theme.ember : (hover ? Color.primary : Color.primary.opacity(0.72)))
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? Theme.emberSoft : (hover ? Color.primary.opacity(0.08) : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Text toggle pill (e.g. "渲染 | 源码").
struct LensSegment: View {
    let options: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                Button { selection = i } label: {
                    Text(options[i])
                        .font(.system(size: 11, weight: selection == i ? .semibold : .regular))
                        .padding(.horizontal, 9).frame(height: 22)
                        .foregroundStyle(selection == i ? Theme.ember : Color.primary.opacity(0.7))
                        .background(RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .fill(selection == i ? Theme.emberSoft : .clear))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

struct LensDivider: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 14).padding(.horizontal, 3) }
}

/// Monospaced numeric readout ("125%", "3 / 12").
struct Readout: View {
    let text: String
    var minWidth: CGFloat = 0
    var body: some View {
        Text(text).font(Theme.mono(11, .medium)).foregroundStyle(.secondary)
            .frame(minWidth: minWidth).monospacedDigit()
    }
}
