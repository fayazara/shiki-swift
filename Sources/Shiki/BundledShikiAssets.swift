import Foundation
import ShikiCore

/// Whether an entry in Shiki's generated language bundle is directly
/// highlightable or is loaded as an injection into another grammar.
public enum ShikiLanguageKind: String, Codable, Sendable {
    case grammar
    case injection
}

/// Lightweight metadata for a bundled TextMate grammar.
public struct ShikiLanguageInfo: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String?
    public let aliases: [String]
    public let scopeName: String
    public let kind: ShikiLanguageKind
    public let embeddedLangs: [String]
    public let embeddedLangsLazy: [String]
    public let embeddedIn: [String]
    public let injectTo: [String]
    public let resource: String
}

/// Lightweight metadata for a bundled VS Code theme.
public struct ShikiThemeInfo: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let type: ShikiThemeType
    public let resource: String
}

public enum ShikiAssetError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingManifest(String)
    case unknownLanguage(String)
    case unknownTheme(String)
    case missingResource(String)
    case invalidResource(path: String, message: String)

    public var description: String {
        switch self {
        case let .missingManifest(name):
            "The bundled Shiki manifest \(String(reflecting: name)) is missing."
        case let .unknownLanguage(name):
            "Unknown bundled Shiki language or alias \(String(reflecting: name))."
        case let .unknownTheme(name):
            "Unknown bundled Shiki theme \(String(reflecting: name))."
        case let .missingResource(path):
            "The bundled Shiki resource \(String(reflecting: path)) is missing."
        case let .invalidResource(path, message):
            "Could not decode bundled Shiki resource \(String(reflecting: path)): \(message)"
        }
    }
}

/// Access to the exact grammar and theme payloads shipped by Shiki v4.4.3.
///
/// Assets remain JSON resources instead of generated Swift source. This keeps
/// the original Oniguruma expressions intact and avoids loading the complete
/// corpus when an app uses only one language and one theme.
public final class BundledShikiAssets: @unchecked Sendable {
    public static let shared: BundledShikiAssets = {
        do {
            return try BundledShikiAssets(bundle: .module)
        } catch {
            // Package resources are generated and validated at build time. A
            // failure here means the installed package is corrupt, so mirror
            // Bundle.module's fail-fast behavior with a useful diagnostic.
            preconditionFailure("Unable to load bundled Shiki manifests: \(error)")
        }
    }()

    public let languages: [ShikiLanguageInfo]
    public let themes: [ShikiThemeInfo]

    private let bundle: Bundle
    private let aliases: [String: String]
    private let languagesByID: [String: ShikiLanguageInfo]
    private let themesByID: [String: ShikiThemeInfo]

    /// Creates a catalog from an arbitrary resource bundle. This is public so
    /// apps can package a curated asset subset with the same manifest format.
    public init(bundle: Bundle) throws {
        self.bundle = bundle

        let languageManifest: LanguageManifest = try Self.decodeManifest(
            LanguageManifest.self,
            name: "language-manifest",
            bundle: bundle
        )
        let themeManifest: ThemeManifest = try Self.decodeManifest(
            ThemeManifest.self,
            name: "theme-manifest",
            bundle: bundle
        )

        guard languageManifest.schemaVersion == 1 else {
            throw ShikiAssetError.invalidResource(
                path: "language-manifest.json",
                message: "unsupported schema version \(languageManifest.schemaVersion)"
            )
        }
        guard themeManifest.schemaVersion == 1 else {
            throw ShikiAssetError.invalidResource(
                path: "theme-manifest.json",
                message: "unsupported schema version \(themeManifest.schemaVersion)"
            )
        }

        languages = languageManifest.languages
        themes = themeManifest.themes
        aliases = languageManifest.aliases
        languagesByID = Dictionary(uniqueKeysWithValues: languages.map { ($0.id, $0) })
        themesByID = Dictionary(uniqueKeysWithValues: themes.map { ($0.id, $0) })
    }

    /// Resolves a canonical ID or any Shiki alias such as `js`, `ts`, or `sh`.
    public func canonicalLanguageID(for name: String) -> String? {
        if languagesByID[name] != nil {
            return name
        }
        return aliases[name]
    }

    public func languageInfo(named name: String) -> ShikiLanguageInfo? {
        guard let id = canonicalLanguageID(for: name) else { return nil }
        return languagesByID[id]
    }

    public func themeInfo(named name: String) -> ShikiThemeInfo? {
        themesByID[name]
    }

    /// Decodes one raw TextMate grammar on demand.
    public func loadLanguage(named name: String) throws -> LanguageRegistration {
        guard let info = languageInfo(named: name) else {
            throw ShikiAssetError.unknownLanguage(name)
        }
        return try decode(LanguageRegistration.self, resource: info.resource)
    }

    /// Decodes and normalizes one raw VS Code theme on demand.
    public func loadTheme(named name: String) throws -> ShikiResolvedTheme {
        guard let info = themeInfo(named: name) else {
            throw ShikiAssetError.unknownTheme(name)
        }
        return normalizeTheme(try decode(ShikiTheme.self, resource: info.resource))
    }

    /// Returns the eager dependency closure in deterministic depth-first order,
    /// ending with the requested language itself. Lazy document embeddings are
    /// included only when requested, matching Shiki's bundle-loading split.
    public func dependencyOrder(
        for name: String,
        includingLazyDependencies: Bool = false
    ) throws -> [ShikiLanguageInfo] {
        guard let root = languageInfo(named: name) else {
            throw ShikiAssetError.unknownLanguage(name)
        }

        var visiting: Set<String> = []
        var visited: Set<String> = []
        var result: [ShikiLanguageInfo] = []

        func visit(_ info: ShikiLanguageInfo) throws {
            guard !visited.contains(info.id) else { return }
            // Grammar dependency cycles are legal. The currently visiting item
            // will be appended by its outer invocation.
            guard visiting.insert(info.id).inserted else { return }

            var dependencies = info.embeddedLangs
            if includingLazyDependencies {
                dependencies.append(contentsOf: info.embeddedLangsLazy)
            }
            for dependencyName in dependencies {
                guard let dependency = languageInfo(named: dependencyName) else {
                    throw ShikiAssetError.unknownLanguage(dependencyName)
                }
                try visit(dependency)
            }

            visiting.remove(info.id)
            visited.insert(info.id)
            result.append(info)
        }

        try visit(root)
        return result
    }

    public func loadLanguageClosure(
        named name: String,
        includingLazyDependencies: Bool = false
    ) throws -> [LanguageRegistration] {
        let infos = try dependencyOrder(
            for: name,
            includingLazyDependencies: includingLazyDependencies
        )
        return try infos.map { try decode(LanguageRegistration.self, resource: $0.resource) }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, resource: String) throws -> Value {
        let resourcePath = resource as NSString
        let file = resourcePath.lastPathComponent as NSString
        let subdirectory = resourcePath.deletingLastPathComponent
        let fileExtension = file.pathExtension
        let baseName = file.deletingPathExtension

        let url = bundle.url(
            forResource: baseName,
            withExtension: fileExtension,
            subdirectory: subdirectory.isEmpty ? nil : subdirectory
        ) ?? bundle.url(
            forResource: baseName,
            withExtension: fileExtension
        )

        guard let url else {
            throw ShikiAssetError.missingResource(resource)
        }

        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: url))
        } catch {
            throw ShikiAssetError.invalidResource(path: resource, message: String(describing: error))
        }
    }

    private static func decodeManifest<Value: Decodable>(
        _ type: Value.Type,
        name: String,
        bundle: Bundle
    ) throws -> Value {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw ShikiAssetError.missingManifest("\(name).json")
        }
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: url))
        } catch {
            throw ShikiAssetError.invalidResource(
                path: "\(name).json",
                message: String(describing: error)
            )
        }
    }
}

private struct LanguageManifest: Decodable {
    let schemaVersion: Int
    let aliases: [String: String]
    let languages: [ShikiLanguageInfo]
}

private struct ThemeManifest: Decodable {
    let schemaVersion: Int
    let themes: [ShikiThemeInfo]
}
