import Foundation

/// A predicate produced from a TextMate scope selector.
public typealias Matcher<Input> = (Input) -> Bool

/// A selector predicate and its injection ordering priority.
public struct MatcherWithPriority<Input> {
    public let matcher: Matcher<Input>

    /// `-1` for `L:`, `1` for `R:`, and `0` when no priority was specified.
    public let priority: Int

    public init(matcher: @escaping Matcher<Input>, priority: Int) {
        self.matcher = matcher
        self.priority = priority
    }
}

/// Parses the selector expression language used by TextMate injections.
///
/// This intentionally retains the permissive behavior of
/// `vscode-textmate`'s `matcher.ts`: unrecognized characters are skipped,
/// malformed operands simply do not match, juxtaposition means AND, and `|`
/// or `,` inside parentheses means OR. A top-level comma creates a separate
/// matcher so each alternative can carry its own `L:`/`R:` priority.
public func createMatchers<Input>(
    _ selector: String,
    matchesName: @escaping (_ identifiers: [String], _ input: Input) -> Bool
) -> [MatcherWithPriority<Input>] {
    TextMateScopeSelectorParser(selector: selector, matchesName: matchesName).parse()
}

/// TextMate's standard hierarchical scope-stack matching behavior.
public func matchesScopeNames(_ identifiers: [String], scopes: [String]) -> Bool {
    guard scopes.count >= identifiers.count else {
        return false
    }

    var nextScopeIndex = 0
    for identifier in identifiers {
        var found = false
        while nextScopeIndex < scopes.count {
            let scope = scopes[nextScopeIndex]
            nextScopeIndex += 1
            if scopeName(scope, matches: identifier) {
                found = true
                break
            }
        }
        if !found {
            return false
        }
    }
    return true
}

/// Convenience entry point for matching TextMate scope stacks.
public enum ScopeSelector {
    public static func parse(_ selector: String) -> [MatcherWithPriority<[String]>] {
        createMatchers(selector, matchesName: matchesScopeNames)
    }

    public static func matches(_ selector: String, scopes: [String]) -> Bool {
        parse(selector).contains { $0.matcher(scopes) }
    }
}

private func scopeName(_ actualScope: String, matches selectorScope: String) -> Bool {
    guard !actualScope.isEmpty else {
        return false
    }
    if actualScope == selectorScope {
        return true
    }
    guard actualScope.count > selectorScope.count,
          actualScope.hasPrefix(selectorScope) else {
        return false
    }
    let boundary = actualScope.index(actualScope.startIndex, offsetBy: selectorScope.count)
    return actualScope[boundary] == "."
}

private final class TextMateScopeSelectorParser<Input> {
    private let tokenizer: TextMateScopeSelectorTokenizer
    private let matchesName: ([String], Input) -> Bool
    private var token: String?

    init(selector: String, matchesName: @escaping ([String], Input) -> Bool) {
        tokenizer = TextMateScopeSelectorTokenizer(selector)
        self.matchesName = matchesName
        token = tokenizer.next()
    }

    func parse() -> [MatcherWithPriority<Input>] {
        var result: [MatcherWithPriority<Input>] = []

        while token != nil {
            var priority = 0
            if let token, token.utf16.count == 2, token.hasSuffix(":") {
                switch token.first {
                case "R": priority = 1
                case "L": priority = -1
                default: break
                }
                advance()
            }

            result.append(MatcherWithPriority(matcher: parseConjunction(), priority: priority))
            guard token == "," else {
                break
            }
            advance()
        }

        return result
    }

    private func parseOperand() -> Matcher<Input>? {
        if token == "-" {
            advance()
            guard let expression = parseOperand() else {
                return { _ in false }
            }
            return { input in !expression(input) }
        }

        if token == "(" {
            advance()
            let expression = parseInnerExpression()
            if token == ")" {
                advance()
            }
            return expression
        }

        guard isIdentifier(token) else {
            return nil
        }

        var identifiers: [String] = []
        while let current = token, isIdentifier(current) {
            identifiers.append(current)
            advance()
        }
        let matchesName = self.matchesName
        return { input in matchesName(identifiers, input) }
    }

    private func parseConjunction() -> Matcher<Input> {
        var matchers: [Matcher<Input>] = []
        while let matcher = parseOperand() {
            matchers.append(matcher)
        }
        return { input in matchers.allSatisfy { $0(input) } }
    }

    private func parseInnerExpression() -> Matcher<Input> {
        var matchers: [Matcher<Input>] = [parseConjunction()]
        while token == "|" || token == "," {
            repeat {
                advance()
            } while token == "|" || token == ","
            matchers.append(parseConjunction())
        }
        return { input in matchers.contains { $0(input) } }
    }

    private func advance() {
        token = tokenizer.next()
    }

    private func isIdentifier(_ token: String?) -> Bool {
        guard let token else {
            return false
        }
        return token.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 48...57, 65...90, 95, 97...122, 46, 58:
                true
            default:
                false
            }
        }
    }
}

private final class TextMateScopeSelectorTokenizer {
    private static let expression = try! NSRegularExpression(
        pattern: #"([LR]:|[A-Za-z0-9_\.:][A-Za-z0-9_\.\:\-]*|[,|\-()])"#
    )

    private let source: NSString
    private let matches: [NSTextCheckingResult]
    private var index = 0

    init(_ input: String) {
        source = input as NSString

        // `NSRange` and `NSString` deliberately make this range UTF-16 based,
        // matching JavaScript RegExp and Shiki even around non-BMP scalars.
        let range = NSRange(location: 0, length: input.utf16.count)
        matches = Self.expression.matches(in: input, range: range)
    }

    func next() -> String? {
        guard index < matches.count else {
            return nil
        }
        defer { index += 1 }
        return source.substring(with: matches[index].range)
    }
}
