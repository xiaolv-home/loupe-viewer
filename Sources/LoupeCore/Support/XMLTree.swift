import Foundation

/// A small element tree for the nested Office XML parts (DrawingML shapes, charts).
/// Names are local (the `c:` / `a:` / `xdr:` prefixes are dropped), because writers pick
/// their own prefixes — or none, like openpyxl's default-namespace charts.
public final class XMLTree: @unchecked Sendable {
    public let name: String
    public let attributes: [String: String]
    public private(set) var children: [XMLTree] = []
    public private(set) var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// The root element, or nil when the data is not well-formed XML.
    public static func parse(_ data: Data) -> XMLTree? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        return parser.parse() ? builder.root : builder.root.flatMap { $0.children.isEmpty ? nil : $0 }
    }

    public subscript(_ attribute: String) -> String? {
        if let v = attributes[attribute] { return v }
        // Attributes can be prefixed too (r:embed, r:id).
        return attributes.first { $0.key.hasSuffix(":" + attribute) }?.value
    }

    /// First direct child with this local name.
    public func child(_ name: String) -> XMLTree? { children.first { $0.name == name } }
    public func children(_ name: String) -> [XMLTree] { children.filter { $0.name == name } }

    /// Follows a path of direct children: `node.at("tx", "rich")`.
    public func at(_ path: String...) -> XMLTree? {
        var n: XMLTree? = self
        for p in path { n = n?.child(p) }
        return n
    }

    /// Every element below this one (depth first) with this local name.
    public func descendants(_ name: String) -> [XMLTree] {
        var out: [XMLTree] = []
        func walk(_ n: XMLTree) { for c in n.children { if c.name == name { out.append(c) }; walk(c) } }
        walk(self)
        return out
    }

    public func firstDescendant(_ name: String) -> XMLTree? {
        for c in children {
            if c.name == name { return c }
            if let d = c.firstDescendant(name) { return d }
        }
        return nil
    }

    /// The `val` attribute of a child, which is how DrawingML spells most settings.
    public func value(of childName: String) -> String? { child(childName)?["val"] }

    /// All text below this element, in document order.
    public var allText: String {
        children.isEmpty ? text : text + children.map(\.allText).joined()
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLTree?
        var stack: [XMLTree] = []

        private func local(_ n: String) -> String {
            guard let i = n.lastIndex(of: ":") else { return n }
            return String(n[n.index(after: i)...])
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            let node = XMLTree(name: local(name), attributes: a)
            if let parent = stack.last { parent.children.append(node) } else { root = node }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, foundCharacters s: String) { stack.last?.text += s }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
    }
}
