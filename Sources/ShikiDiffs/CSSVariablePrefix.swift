/// Namespaces used by upstream theme variables and token color variables.
public enum CSSVariablePrefixType: Sendable { case global, token }

/// Preserves upstream variable names for theme import/export and host adapters.
/// Returning a prefix does not imply native support for CSS variable resolution.
public func formatCSSVariablePrefix(_ type: CSSVariablePrefixType) -> String {
    switch type {
    case .global: return "--diffs-"
    case .token: return "--diffs-token-"
    }
}
