import Testing
import AppKit
@testable import ShikiDiffs

@Suite struct HighlightingTests {
    @Test func partialHunksResetGrammarAcrossOmittedSource() async throws {
        let patch = "diff --git a/f.swift b/f.swift\n--- a/f.swift\n+++ b/f.swift\n@@ -1 +1 @@\n-/* old\n+/* new\n@@ -20 +20 @@\n-let value = 1\n+let value = 2\n"
        let diff = try #require(try parsePatchFiles(patch, throwOnError: true).first?.files.first)
        let worker = DiffHighlighter()
        let partial = try await worker.prepare(diff)
        let plainFile = FileContents(name: "f.swift", contents: "let value = 2\n")
        let reference = try await worker.prepare(oldFile: plainFile, newFile: plainFile)
        #expect(partial.newTokens[1].map(\.color) == reference.newTokens[0].map(\.color))
        #expect(partial.newTokens[1].map(\.content) == reference.newTokens[0].map(\.content))
    }
    @Test func boundedCacheRespectsSourceThemeAndLimits() async throws {
        let worker = DiffHighlighter(cacheCapacityBytes: 20_000)
        let file = FileContents(name: "f.swift", contents: "let message = \"café\"\n")
        _ = try await worker.prepare(oldFile: file, newFile: file)
        _ = try await worker.prepare(oldFile: file, newFile: file)
        #expect(await worker.cacheStatistics.hits == 1)
        var changed = file; changed.contents = "let message = \"café\"\n"
        _ = try await worker.prepare(oldFile: changed, newFile: changed)
        #expect(await worker.cacheStatistics.misses == 2)
        var options = DiffRenderOptions(); options.theme = "pierre-light"
        _ = try await worker.prepare(oldFile: file, newFile: file, options: options)
        #expect(await worker.cacheStatistics.misses == 3)
        options.tokenizeMaxLineLength = 2
        _ = try await worker.prepare(oldFile: file, newFile: file, options: options)
        #expect(await worker.cacheStatistics.misses == 4)
        for i in 0..<100 {
            let next = FileContents(name: "f.txt", contents: "value \(i)\n")
            _ = try await worker.prepare(oldFile: next, newFile: next)
        }
        let stats = await worker.cacheStatistics
        #expect(stats.entries <= 64); #expect(stats.estimatedBytes <= 20_000)
        await worker.clearCache(); #expect(await worker.cacheStatistics.entries == 0)
    }
}

@Suite(.serialized) struct LargeJSONPerformanceTests {
    @Test @MainActor func megabyteJSONPreparationAndDestinationPaint() async throws {
        var rows = ["{\n  \"items\": [\n"]
        for i in 0..<12_000 {
            rows.append("    { \"id\": \(i), \"name\": \"Item \(i)\", \"enabled\": true, \"region\": \"ap-south-1\", \"score\": 42 }" + (i == 11_999 ? "\n" : ",\n"))
        }
        rows.append("  ]\n}\n")
        let old = FileContents(name: "catalog.json", contents: rows.joined())
        for i in stride(from: 42, to: 12_000, by: 701) { rows[i] = rows[i].replacingOccurrences(of: "true", with: "false") }
        let new = FileContents(name: old.name, contents: rows.joined())
        #expect(old.contents.utf8.count > 1_000_000)
        let worker = DiffHighlighter()
        var options = DiffRenderOptions(); options.expandUnchanged = true
        let start = ContinuousClock.now
        let cold = try await worker.prepare(oldFile: old, newFile: new, options: options)
        let total = start.duration(to: .now)
        let coldStages = await worker.preparationStageMilliseconds
        #expect(abs(coldStages.values.reduce(0, +) - cold.preparationMilliseconds) < 0.001)
        let warm = try await worker.prepare(cold.diff, options: options)
        #expect(await worker.cacheStatistics.hits == 2)
        #expect(warm.newTokens.count >= 12_000)
        let edited = FileContents(name: new.name, contents: new.contents.replacingOccurrences(of: "Item 6000", with: "Updated 6000"))
        let editedResult = try await worker.prepare(oldFile: old, newFile: edited, options: options)
        print("JSON_SMALL_EDIT_MS \(editedResult.preparationMilliseconds) stages=\(await worker.preparationStageMilliseconds)")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NativeDiffView(frame: NSRect(x: 0, y: 0, width: 1100, height: 650))
        window.contentView = view; view.render(warm, options: options)
        var times: [Double] = []
        for row in [0, 11_900, 400, 9_000, 6000] {
            view.resetMetrics()
            let began = CACurrentMediaTime()
            view.scrollToRow(row)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            times.append((CACurrentMediaTime() - began) * 1000)
            #expect(view.metrics.styledLines < 100)
            #expect(view.metrics.cachedLines <= 512)
        }
        print("JSON_BENCHMARK bytes=\(old.contents.utf8.count) totalCold=\(total) highlightColdMs=\(cold.preparationMilliseconds) highlightWarmMs=\(warm.preparationMilliseconds) paintMs=\(times)")
        print("JSON_COLD_STAGES \(coldStages)")
        window.close()
    }
}

@Suite(.serialized) struct CustomLanguageTests {
    @Test func mappingChangesDoNotReusePreviousLanguageTokens() async throws {
        let previous = getCustomExtensionsMap()
        defer { replaceCustomExtensions(version: getCustomExtensionsVersion() + 1, map: previous) }
        let worker = DiffHighlighter()
        let file = FileContents(name: "sample.cache-language-fixture", contents: "let value = 42\n")
        setCustomExtension("cache-language-fixture", language: "text")
        let plain = try await worker.prepare(oldFile: file, newFile: file)
        setCustomExtension("cache-language-fixture", language: "swift")
        let mapped = try await worker.prepare(oldFile: file, newFile: file)
        let explicit = setLanguageOverride(file, language: "swift")
        let reference = try await worker.prepare(oldFile: explicit, newFile: explicit)
        #expect(mapped.newTokens == reference.newTokens)
        #expect(mapped.newTokens != plain.newTokens)
        setCustomExtension("cache-language-fixture", language: "text")
        let restored = try await worker.prepare(oldFile: file, newFile: file)
        #expect(restored.newTokens == plain.newTokens)
        let explicitAfterChange = try await worker.prepare(oldFile: explicit, newFile: explicit)
        #expect(explicitAfterChange.newTokens == reference.newTokens)
    }
    @Test func versionedCustomMappingsAndPrecedence() {
        let previous = getCustomExtensionsMap()
        defer { replaceCustomExtensions(version: getCustomExtensionsVersion() + 1, map: previous) }
        let version = getCustomExtensionsVersion()
        #expect(setCustomExtension("native-diff-fixture", language: "swift"))
        #expect(!setCustomExtension("native-diff-fixture", language: "swift"))
        #expect(getFiletypeFromFileName("f.native-diff-fixture") == "swift")
        #expect(getCustomExtensionsVersion() == version + 1)
        #expect(!replaceCustomExtensions(version: version, map: [:]))
        #expect(getFiletypeFromFileName("dir/f.component.ts") == "angular-ts")
        #expect(getFiletypeFromFileName("f.swift.") == "text")
        #expect(getFiletypeFromFileName("Dockerfile") == "dockerfile")
        #expect(getFiletypeFromFileName("folder/Dockerfile") == "text")
        #expect(setCustomExtension("\u{301}native", language: "swift"))
        #expect(getFiletypeFromFileName("file.\u{301}native") == "swift")
        #expect(setCustomExtension("\u{301}component.ts", language: "json"))
        #expect(getFiletypeFromFileName("dir/file.\u{301}component.ts") == "json")
        #expect(setCustomExtension("", language: "text"))
        #expect(getFiletypeFromFileName("no-extension") == "text")

    }
}
