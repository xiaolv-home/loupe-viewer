import Foundation

/// Everything drawn on top of a sheet's cells: charts, pictures, shapes, text boxes.
public struct SheetDrawing: Sendable {
    public var anchor: DrawingAnchor
    public var items: [DrawingItem]
    public init(anchor: DrawingAnchor, items: [DrawingItem]) { self.anchor = anchor; self.items = items }
}

/// Where a drawing sits. Lengths are in Excel's screen pixels (96 per inch, 9525 EMU each),
/// the same unit as SheetMetrics column and row sizes.
public struct DrawingAnchor: Sendable, Equatable {
    public struct Marker: Sendable, Equatable {
        public var row: Int, col: Int
        public var rowOffset: Double, colOffset: Double
        public init(row: Int, col: Int, rowOffset: Double = 0, colOffset: Double = 0) {
            self.row = row; self.col = col; self.rowOffset = rowOffset; self.colOffset = colOffset
        }
    }
    /// Top-left cell (two- and one-cell anchors).
    public var from: Marker?
    /// Bottom-right cell (two-cell anchors).
    public var to: Marker?
    /// Size, when the anchor gives one instead of an end cell.
    public var width: Double?
    public var height: Double?
    /// Absolute position from the sheet's top-left corner (absolute anchors).
    public var x: Double?
    public var y: Double?
    public init() {}

    public static let emuPerPixel = 9525.0
}

/// One object inside an anchor, positioned as a fraction of the anchor's rectangle
/// (groups place their children this way; a plain object fills the whole anchor).
public struct DrawingItem: Sendable {
    public var frame = UnitRect.full
    public var rotation: Double = 0
    public var flipH = false
    public var flipV = false
    public var content: DrawingContent
    public init(content: DrawingContent) { self.content = content }
}

public struct UnitRect: Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public static let full = UnitRect(x: 0, y: 0, width: 1, height: 1)
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    /// This rectangle placed inside another unit rectangle.
    public func within(_ outer: UnitRect) -> UnitRect {
        UnitRect(x: outer.x + x * outer.width, y: outer.y + y * outer.height, width: width * outer.width, height: height * outer.height)
    }
}

public enum DrawingContent: Sendable {
    case chart(ChartSpec)
    case picture(DrawingPicture)
    case shape(DrawingShape)
    /// Something Loupe does not draw (SmartArt, ink, OLE objects…), shown as a labelled box
    /// so the sheet does not look as if nothing were there.
    case placeholder(String)
}

public struct DrawingPicture: Sendable {
    public var data: Data
    public var name: String
    public init(data: Data, name: String) { self.data = data; self.name = name }
}

public struct DrawingShape: Sendable {
    /// Preset geometry name (rect, roundRect, ellipse, line, rightArrow…).
    public var geometry = "rect"
    public var fill: RGBA?
    public var noFill = false
    public var line: DrawingLine?
    /// A connector or line: drawn as a stroke from corner to corner.
    public var isLine = false
    public var paragraphs: [DrawingParagraph] = []
    /// t, ctr or b.
    public var verticalAnchor = "t"
    public var vertical = false
    public init() {}
}

public struct DrawingParagraph: Sendable {
    /// l, ctr, r or just.
    public var alignment = "l"
    public var runs: [DrawingRun] = []
    public init() {}
    public var text: String { runs.map(\.text).joined() }
}

public struct DrawingRun: Sendable {
    public var text: String
    public var size: Double?
    public var bold = false
    public var italic = false
    public var underline = false
    public var color: RGBA?
    public init(text: String) { self.text = text }
}
