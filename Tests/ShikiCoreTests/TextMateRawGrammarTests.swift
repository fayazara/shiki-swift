import Foundation
import XCTest
@testable import ShikiCore

final class TextMateRawGrammarTests: XCTestCase {
    func testNumericApplyEndPatternLastMatchesJavaScriptTruthiness() throws {
        let enabled = try JSONDecoder().decode(
            RawRule.self,
            from: Data(#"{"applyEndPatternLast":1}"#.utf8)
        )
        let disabled = try JSONDecoder().decode(
            RawRule.self,
            from: Data(#"{"applyEndPatternLast":0}"#.utf8)
        )

        XCTAssertEqual(enabled.applyEndPatternLast, true)
        XCTAssertEqual(disabled.applyEndPatternLast, false)
    }

    func testCaptureCollectionsAcceptTextMateArrayFormAndPreserveIt() throws {
        let source = Data(
            #"{"captures":[{"name":"punctuation.first"},null,{"name":"entity.third"}]}"#.utf8
        )
        let rule = try JSONDecoder().decode(RawRule.self, from: source)

        XCTAssertEqual(rule.captures?["0"]?.name, "punctuation.first")
        XCTAssertNil(rule.captures?["1"])
        XCTAssertEqual(rule.captures?["2"]?.name, "entity.third")

        let encoded = try JSONEncoder().encode(rule)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let captures = try XCTUnwrap(object["captures"] as? [Any])
        XCTAssertEqual(captures.count, 3)
        XCTAssertTrue(captures[1] is NSNull)
    }

    func testMalformedCaptureValuesBecomeInertRulesLikeJavaScriptPropertyAccess() throws {
        let rule = try JSONDecoder().decode(
            RawRule.self,
            from: Data(
                #"{"captures":{"0":"punctuation.end","1":[{"name":"ignored"}]}}"#.utf8
            )
        )

        XCTAssertEqual(rule.captures?["0"], RawRule())
        XCTAssertEqual(rule.captures?["1"], RawRule())
    }



    func testDecodesRecursiveGrammarAndShikiRegistrationExtensions() throws {
        let json = #"""
        {
          "name": "typescript",
          "displayName": "TypeScript",
          "scopeName": "source.ts",
          "aliases": ["ts"],
          "fileTypes": ["ts", "mts"],
          "firstLineMatch": "^#!.*\\bnode",
          "embeddedLangs": ["javascript"],
          "embeddedLanguages": ["javascriptreact"],
          "embeddedLangsLazy": ["html"],
          "balancedBracketSelectors": ["*"],
          "unbalancedBracketSelectors": ["string", "comment"],
          "foldingStartMarker": "^\\s*// region",
          "foldingStopMarker": "^\\s*// endregion",
          "injectTo": ["source.js"],
          "injectionSelector": "L:source.ts",
          "patterns": [
            { "include": "#main" }
          ],
          "repository": {
            "$vscodeTextmateLocation": { "filename": "typescript.tmLanguage.json", "line": 4, "char": 2 },
            "main": {
              "begin": "(function)",
              "beginCaptures": {
                "$vscodeTextmateLocation": { "filename": "typescript.tmLanguage.json", "line": 9, "char": 8 },
                "1": { "name": "storage.type.function.ts" }
              },
              "end": "(?=})",
              "while": "^\\s+",
              "applyEndPatternLast": true,
              "patterns": [
                { "match": "[A-Za-z_$][\\w$]*", "name": "entity.name.function.ts" }
              ]
            }
          },
          "injections": {
            "L:source.ts string": { "match": "TODO", "name": "keyword.other.todo" }
          },
          "$vscodeTextmateLocation": { "filename": "typescript.tmLanguage.json", "line": 1, "char": 0 }
        }
        """#

        let registration = try JSONDecoder().decode(
            LanguageRegistration.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(registration.name, "typescript")
        XCTAssertEqual(registration.displayName, "TypeScript")
        XCTAssertEqual(registration.scopeName, "source.ts")
        XCTAssertEqual(registration.aliases, ["ts"])
        XCTAssertEqual(registration.embeddedLangs, ["javascript"])
        XCTAssertEqual(registration.embeddedLanguages, ["javascriptreact"])
        XCTAssertEqual(registration.embeddedLangsLazy, ["html"])
        XCTAssertEqual(registration.balancedBracketSelectors, ["*"])
        XCTAssertEqual(registration.unbalancedBracketSelectors, ["string", "comment"])
        XCTAssertEqual(registration.injectTo, ["source.js"])
        XCTAssertEqual(registration.location?.character, 0)

        let grammar = registration.rawGrammar
        XCTAssertEqual(grammar.name, "typescript")
        XCTAssertEqual(grammar.repository.location?.line, 4)
        XCTAssertEqual(grammar.repository.location?.character, 2)

        let main = try XCTUnwrap(grammar.repository["main"])
        XCTAssertEqual(main.begin, "(function)")
        XCTAssertEqual(main.whilePattern, #"^\s+"#)
        XCTAssertEqual(main.applyEndPatternLast, true)
        XCTAssertEqual(main.beginCaptures?.location?.character, 8)
        XCTAssertEqual(main.beginCaptures?["1"]?.name, "storage.type.function.ts")
        XCTAssertEqual(main.patterns?.first?.name, "entity.name.function.ts")
        XCTAssertEqual(grammar.injections?["L:source.ts string"]?.match, "TODO")
    }

    func testLanguageRegistrationRoundTripsItsFlattenedJSONShape() throws {
        let grammar = RawGrammar(
            scopeName: "source.example",
            repository: ["word": RawRule(name: "word.example", match: #"\w+"#)],
            patterns: [RawRule(include: "#word")],
            fileTypes: ["example"]
        )
        let expected = LanguageRegistration(
            name: "example",
            grammar: grammar,
            displayName: "Example",
            aliases: ["ex"],
            embeddedLangs: ["javascript"],
            balancedBracketSelectors: ["*"],
            injectTo: ["text.html"]
        )

        let encoded = try JSONEncoder().encode(expected)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["scopeName"] as? String, "source.example")
        XCTAssertEqual(object["name"] as? String, "example")
        XCTAssertNil(object["grammar"])

        let decoded = try JSONDecoder().decode(LanguageRegistration.self, from: encoded)
        XCTAssertEqual(decoded, expected)
    }

    func testRawGrammarDefaultsOptionalCollectionsToEmpty() throws {
        let grammar = try JSONDecoder().decode(
            RawGrammar.self,
            from: Data(#"{"scopeName":"source.empty"}"#.utf8)
        )

        XCTAssertTrue(grammar.repository.isEmpty)
        XCTAssertTrue(grammar.patterns.isEmpty)
    }

    func testGrammarConfigurationUsesTextMateTokenTypes() throws {
        let expected = GrammarConfiguration(
            embeddedLanguages: ["meta.embedded.block.html": 2],
            tokenTypes: ["comment": .comment, "string.regexp": .regex],
            balancedBracketSelectors: ["*"],
            unbalancedBracketSelectors: ["comment"]
        )

        let data = try JSONEncoder().encode(expected)
        XCTAssertEqual(try JSONDecoder().decode(GrammarConfiguration.self, from: data), expected)
    }
}
