import Foundation
import SwiftParser
import SwiftSyntax

/// One interactive control found in source.
public struct Hit: Sendable, Equatable {
    public enum Kind: String, Sendable { case control, iconOnly }
    public var file: String          // path relative to the repository root
    public var line: Int
    public var construct: String     // "Button", "onTapGesture", ...
    public var symbol: String        // enclosing type and member, "HomeScreen.body"
    public var kind: Kind
    public var marker: String?       // id from .atlas("id") or .atlasCovers("id")
    public var documented: Bool      // enclosing declaration has a `/// atlas:` line
    public var folder: String
    /// UTF-8 offset where the postfix chain of this control ends (for tooling that inserts a marker there).
    public var chainEnd: Int = 0
}

public enum Scanner {
    public static let constructs: Set<String> = ["Button", "Toggle", "Picker", "Menu", "NavigationLink", "IconButton", "PrimaryButton", "SecondaryButton"]
    public static let modifiers: Set<String> = ["onTapGesture", "contextMenu", "swipeActions", "keyboardShortcut", "onLongPressGesture"]
    static let labelModifiers: Set<String> = ["accessibilityLabel", "help", "accessibilityHint"]

    public static func scan(source: String, file: String, folder: String) -> [Hit] {
        let tree = Parser.parse(source: source)
        let v = Visitor(file: file, folder: folder, converter: SourceLocationConverter(fileName: file, tree: tree))
        v.walk(tree)
        return v.hits
    }

    final class Visitor: SyntaxVisitor {
        let file: String, folder: String, converter: SourceLocationConverter
        var hits: [Hit] = []
        init(file: String, folder: String, converter: SourceLocationConverter) {
            self.file = file; self.folder = folder; self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            var name: String?
            if let r = node.calledExpression.as(DeclReferenceExprSyntax.self), Scanner.constructs.contains(r.baseName.text) { name = r.baseName.text }
            else if let m = node.calledExpression.as(MemberAccessExprSyntax.self), m.base != nil, Scanner.modifiers.contains(m.declName.baseName.text) { name = m.declName.baseName.text }
            guard let name else { return .visitChildren }
            let chain = Chain(of: node)
            let line = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
            let marker = chain.marker ?? Scanner.enclosingMarker(node)
            let end = chain.end
            let documented = Scanner.documented(node)
            hits.append(Hit(file: file, line: line, construct: name, symbol: Scanner.symbol(node), kind: .control, marker: marker, documented: documented, folder: folder, chainEnd: end))
            if name == "Button", Scanner.isIconOnly(node), !chain.names.contains(where: Scanner.labelModifiers.contains) {
                hits.append(Hit(file: file, line: line, construct: "Button", symbol: Scanner.symbol(node), kind: .iconOnly, marker: marker, documented: documented, folder: folder, chainEnd: end))
            }
            return .visitChildren
        }
    }

    /// The postfix chain a call sits in: every modifier above it and the calls below it (`Button{}.buttonStyle(x).atlas("a")`).
    struct Chain {
        var names: [String] = []
        var marker: String?
        var end = 0
        init(of node: FunctionCallExprSyntax) {
            var top: ExprSyntax = ExprSyntax(node)
            while let m = top.parent?.as(MemberAccessExprSyntax.self), m.base?.id == top.id,
                  let c = m.parent?.as(FunctionCallExprSyntax.self), c.calledExpression.id == m.id { top = ExprSyntax(c) }
            end = top.endPositionBeforeTrailingTrivia.utf8Offset
            var cur: ExprSyntax? = top
            while let e = cur {
                if let c = e.as(FunctionCallExprSyntax.self) {
                    if let m = c.calledExpression.as(MemberAccessExprSyntax.self) {
                        let n = m.declName.baseName.text
                        names.append(n)
                        if (n == "atlas" || n == "atlasCovers"), marker == nil,
                           let s = c.arguments.first?.expression.as(StringLiteralExprSyntax.self) { marker = s.representedLiteralValue ?? "?" }
                        cur = m.base
                    } else { cur = nil }
                } else if let m = e.as(MemberAccessExprSyntax.self) { cur = m.base } else { cur = nil }
            }
        }
    }

    /// A control inside a helper call that takes an `atlas: "id"` argument (a settings row) is marked by that argument: the helper puts `.atlas(id)` on the row once.
    static func enclosingMarker(_ node: some SyntaxProtocol) -> String? {
        var p: Syntax? = Syntax(node).parent
        while let s = p {
            if s.is(StructDeclSyntax.self) || s.is(ClassDeclSyntax.self) { return nil }
            if let c = s.as(FunctionCallExprSyntax.self), let a = c.arguments.first(where: { $0.label?.text == "atlas" }) {
                if let lit = a.expression.as(StringLiteralExprSyntax.self) { return lit.representedLiteralValue ?? "?" }
                if a.expression.is(DeclReferenceExprSyntax.self) { return "(passed through)" }   // a helper that forwards its own `atlas` parameter
            }
            p = s.parent
        }
        return nil
    }

    static func documented(_ node: some SyntaxProtocol) -> Bool {
        var p: Syntax? = Syntax(node)
        while let s = p {
            if let d = s.asProtocol(DeclSyntaxProtocol.self) {
                let text = d.leadingTrivia.pieces.compactMap { piece -> String? in
                    if case .docLineComment(let t) = piece { return t }
                    return nil
                }
                if text.contains(where: { $0.lowercased().hasPrefix("/// atlas:") }) { return true }
            }
            p = s.parent
        }
        return false
    }

    static func symbol(_ node: some SyntaxProtocol) -> String {
        var parts: [String] = []
        var p: Syntax? = Syntax(node)
        while let s = p {
            if let d = s.as(StructDeclSyntax.self) { parts.append(d.name.text) }
            else if let d = s.as(ClassDeclSyntax.self) { parts.append(d.name.text) }
            else if let d = s.as(EnumDeclSyntax.self) { parts.append(d.name.text) }
            else if let d = s.as(ExtensionDeclSyntax.self) { parts.append(d.extendedType.trimmedDescription) }
            else if let d = s.as(FunctionDeclSyntax.self) { parts.append(d.name.text) }
            else if let d = s.as(VariableDeclSyntax.self), let b = d.bindings.first?.pattern.as(IdentifierPatternSyntax.self) { parts.append(b.identifier.text) }
            p = s.parent
        }
        return parts.reversed().joined(separator: ".")
    }

    /// A Button whose label has an SF Symbol image and no text.
    static func isIconOnly(_ call: FunctionCallExprSyntax) -> Bool {
        var labelText = ""
        if let t = call.trailingClosure { labelText = t.statements.trimmedDescription }
        for a in call.arguments where a.label?.text == "label" { labelText = a.expression.trimmedDescription }
        for t in call.additionalTrailingClosures where t.label.text == "label" { labelText = t.closure.statements.trimmedDescription }
        if labelText.isEmpty { return false }
        // `Button(action: x) { ... }` and `Button("Title") { }`: a title argument means text.
        if call.arguments.first.map({ $0.label == nil && $0.expression.is(StringLiteralExprSyntax.self) }) == true { return false }
        return labelText.contains("Image(systemName") && !labelText.contains("Text(") && !labelText.contains("Label(")
    }
}
