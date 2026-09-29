import Foundation
import Shiki
import Testing
@testable import ShikiDiffs

private actor LoaderProbe {
    var calls = 0
    func load(failFirst: Bool = false) async throws -> [LanguageRegistration] {
        calls += 1
        let call = calls
        try await Task.sleep(for: .milliseconds(20))
        if failFirst && call == 1 { throw DiffError.invalidPatch("loader failure") }
        let data = Data(#"{"name":"lazy-fixture","scopeName":"source.lazy-fixture","patterns":[{"match":"hello","name":"keyword.control"}]}"#.utf8)
        return [try JSONDecoder().decode(LanguageRegistration.self, from: data)]
    }
}
private actor PreloadBarrier {
    var released = false
    var arrivals = 0
    var waiters: [CheckedContinuation<Void, Never>] = []
    func arrive() async {
        arrivals += 1
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { released = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
}
struct LazyLanguageTests {
    @Test func disposalReleasesEngineAndPreservesCustomRegistrations() async throws {
        let worker = DiffHighlighter()
        try await worker.registerCustomLanguage("dispose-fixture") {
            [LanguageRegistration(name: "dispose-fixture", grammar: RawGrammar(scopeName: "source.dispose-fixture", patterns: []))]
        }
        await worker.registerCustomTheme("dispose-theme") {
            ShikiTheme(name: "dispose-theme", type: .dark, foreground: "#ffffff", background: "#112233")
        }
        let file = FileContents(name: "f.txt", contents: "hello\n", lang: "dispose-fixture")
        var options = DiffRenderOptions(); options.theme = "dispose-theme"
        let before = try await worker.prepare(oldFile: file, newFile: file, options: options)
        await worker.disposeHighlighter()
        #expect(await !worker.isHighlighterLoaded)
        #expect(await worker.getHighlighterIfLoaded() == nil)
        #expect(await worker.attachedLanguages.isEmpty)
        #expect(await worker.attachedThemes.isEmpty)
        #expect(await worker.resolvedLanguages.isEmpty)
        #expect(await worker.resolvedThemes.isEmpty)
        #expect(await worker.registeredCustomLanguageNames.contains("dispose-fixture"))
        #expect(await worker.preparationStageMilliseconds.isEmpty)
        await worker.disposeHighlighter()
        let after = try await worker.prepare(oldFile: file, newFile: file, options: options)
        #expect(before.newTokens == after.newTokens && before.background == after.background)
        #expect(await worker.areLanguagesAttached(["dispose-fixture"]))
        #expect(await worker.areThemesAttached(["dispose-theme"]))
    }
    @Test(arguments: [false, true]) func disposalInvalidatesPendingLanguagePreparation(_ preload: Bool) async throws {
        let worker = DiffHighlighter(), barrier = PreloadBarrier()
        try await worker.registerCustomLanguage("delayed-disposal") {
            await barrier.arrive()
            return [LanguageRegistration(name: "delayed-disposal", grammar: RawGrammar(scopeName: "source.delayed-disposal", patterns: []))]
        }
        let pending = Task {
            if preload { try await worker.preload(languages: ["delayed-disposal"]) }
            else {
                let file = FileContents(name: "f.txt", contents: "hello\n", lang: "delayed-disposal")
                _ = try await worker.prepare(oldFile: file, newFile: file)
            }
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while await barrier.arrivals == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await barrier.arrivals == 1)
        await worker.disposeHighlighter()
        await barrier.release()
        do { try await pending.value; Issue.record("Disposed work must not attach resources") }
        catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(await !worker.isHighlighterLoaded)
        #expect(await !worker.areLanguagesAttached(["delayed-disposal"]))
        try await worker.preload(languages: ["delayed-disposal"])
        #expect(await worker.areLanguagesAttached(["delayed-disposal"]))
    }
    @Test func preloadStartsIndependentLanguagesAndThemesTogether() async throws {
        let worker = DiffHighlighter(), barrier = PreloadBarrier()
        for name in ["parallel-a", "parallel-b"] {
            try await worker.registerCustomLanguage(name) {
                await barrier.arrive()
                return [LanguageRegistration(name: name, grammar: RawGrammar(scopeName: "source." + name, patterns: []))]
            }
        }
        await worker.registerCustomTheme("parallel-theme") {
            await barrier.arrive()
            return ShikiTheme(name: "parallel-theme", type: .dark, foreground: "#ffffff", background: "#000000")
        }
        let task = Task { try await worker.preload(languages: ["parallel-a", "parallel-b", "parallel-a", "text", "ansi"], themes: ["parallel-theme"]) }
        let deadline = ContinuousClock.now + .seconds(2)
        while await barrier.arrivals < 3 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await barrier.arrivals == 3)
        await barrier.release()
        try await task.value
        #expect(await worker.areLanguagesAttached(["parallel-a", "parallel-b"]))
        #expect(await worker.areThemesAttached(["parallel-theme"]))
    }

    @Test func highlighterReadinessDoesNotInitializeOrLoadMissingResources() async throws {
        let worker = DiffHighlighter()
        #expect(await !worker.isHighlighterLoaded)
        #expect(await worker.getHighlighterIfLoaded() == nil)
        #expect(await !worker.isHighlighterLoaded)
        try await worker.preload(languages: ["swift"], themes: ["pierre-dark"])
        #expect(await worker.isHighlighterLoaded)
        let ready = await worker.getHighlighterIfLoaded(languages: ["swift", "text", "ansi"], themes: ["pierre-dark"])
        #expect(ready === worker)
        #expect(await worker.getHighlighterIfLoaded(languages: ["missing-language"], themes: ["pierre-dark"]) == nil)
        #expect(await !worker.hasResolvedLanguages(["missing-language"]))
        #expect(await worker.getHighlighterIfLoaded(themes: ["missing-theme"]) == nil)
        await worker.cleanUpResolvedLanguages()
        #expect(await worker.isHighlighterLoaded)
        #expect(await worker.getHighlighterIfLoaded(languages: ["swift"]) == nil)
    }

    @Test func lateInjectionInvalidatesExistingLanguageAndEditorTokens() async throws {
        let worker = DiffHighlighter()
        let base = LanguageRegistration(name: "injection-base", grammar: RawGrammar(scopeName: "source.injection-base", patterns: [RawRule(name: "keyword.control", match: "foo")]))
        try await worker.registerLanguage(base)
        let file = FileContents(name: "f", contents: "foo bar\n", lang: "injection-base")
        let diff = try parseDiffFromFile(file, file)
        let session = UUID()
        let before = try await worker.prepare(diff)
        _ = try await worker.prepare(diff)
        #expect(await worker.cacheStatistics.hits > 0)
        _ = try await worker.prepareForEditing(diff, session: session)
        let injection = LanguageRegistration(name: "late-injection", grammar: RawGrammar(scopeName: "injection.late", patterns: [RawRule(name: "constant.numeric", match: "bar")], injectionSelector: "L:source.injection-base"), injectTo: ["source.injection-base"])
        try await worker.registerCustomLanguage("late-injection") { [injection] }
        let resolved = try await worker.resolveLanguage("late-injection")
        try await worker.attachResolvedLanguages([resolved])
        let after = try await worker.prepare(diff)
        #expect(after.newTokens != before.newTokens)
        #expect(after.newTokens[0].contains { $0.content == "bar" })
        let edited = try await worker.prepareForEditing(diff, session: session)
        #expect(edited.newTokens == after.newTokens)
        #expect(await worker.editorHighlightStatistics.retokenizedLines > 0)
    }
    @Test func bulkResolutionKeepsCachedFirstAndDuplicates() async throws {
        let worker = DiffHighlighter(), probe = LoaderProbe()
        try await worker.registerCustomLanguage("lazy-fixture") { try await probe.load() }
        _ = try await worker.resolveLanguage("swift")
        let values = try await worker.resolveLanguages(["lazy-fixture", "text", "swift", "ansi", "lazy-fixture"])
        #expect(values.map(\.name) == ["swift", "lazy-fixture", "lazy-fixture"])
        #expect(await probe.calls == 1)
        #expect(await !worker.areLanguagesAttached(["lazy-fixture", "swift"]))
    }
    @Test func resolutionAttachmentAndCleanupAreSeparate() async throws {
        let worker = DiffHighlighter(), probe = LoaderProbe()
        try await worker.registerCustomLanguage("lazy-fixture") { try await probe.load() }
        #expect(await worker.areLanguagesAttached(["text", "ansi"]))
        #expect(await !worker.hasResolvedLanguages(["lazy-fixture"]))
        let resolved = try await worker.getResolvedOrResolveLanguage("lazy-fixture")
        #expect(await worker.hasResolvedLanguages(["lazy-fixture"]))
        #expect(await !worker.areLanguagesAttached(["lazy-fixture"]))
        #expect(try await worker.getResolvedLanguages(["lazy-fixture"]).first?.data == resolved.data)
        try await worker.attachResolvedLanguages([resolved])
        #expect(await worker.areLanguagesAttached(["lazy-fixture"]))
        await worker.cleanUpResolvedLanguages()
        #expect(await !worker.hasResolvedLanguages(["lazy-fixture"]))
        #expect(await !worker.areLanguagesAttached(["lazy-fixture"]))
        try await worker.preload(languages: ["lazy-fixture"])
        #expect(await probe.calls == 2)
        let bundled = try await worker.getResolvedOrResolveLanguage("swift")
        #expect(bundled.data.contains { $0.name == "swift" })
        #expect(await !worker.areLanguagesAttached(["swift"]))
        try await worker.attachResolvedLanguages([bundled])
        #expect(await worker.areLanguagesAttached(["swift"]))
        let eager = DiffHighlighter()
        try await eager.registerLanguage(resolved.data[0])
        await eager.cleanUpResolvedLanguages()
        try await eager.preload(languages: ["lazy-fixture"])
        #expect(await eager.areLanguagesAttached(["lazy-fixture"]))
    }
    @Test func validatesDeclaredAliasesAndBatchedDependencies() async throws {
        let worker = DiffHighlighter()
        let grammar = try JSONDecoder().decode(LanguageRegistration.self, from: Data(#"{"name":"primary-grammar","aliases":["requested-alias"],"scopeName":"source.primary-fixture","patterns":[{"include":"source.dependency-fixture"}]}"#.utf8))
        let dependency = try JSONDecoder().decode(LanguageRegistration.self, from: Data(#"{"name":"dependency-grammar","scopeName":"source.dependency-fixture","patterns":[{"match":"hello","name":"keyword.control"}]}"#.utf8))
        try await worker.registerCustomLanguage("requested-alias") { [grammar, dependency] }
        let file = FileContents(name: "f", contents: "hello\n", lang: "requested-alias")
        let loaded = try await worker.prepare(oldFile: file, newFile: file)
        let plainFile = setLanguageOverride(file, language: "text")
        let plain = try await worker.prepare(oldFile: plainFile, newFile: plainFile)
        #expect(loaded.newTokens != plain.newTokens)
        try await worker.registerCustomLanguage("undeclared") { [grammar] }
        do { try await worker.preload(languages: ["undeclared"]); Issue.record("Undeclared alias accepted") }
        catch { #expect(String(describing: error).contains("No returned grammar declares")) }
        try await worker.registerCustomLanguage("empty-result") { [] }
        do { try await worker.preload(languages: ["empty-result"]); Issue.record("Empty grammar set accepted") }
        catch { #expect(String(describing: error).contains("No returned grammar declares")) }
    }
    @Test func lazyLoadingDeduplicatesAndPreservesFirstRegistration() async throws {
        let worker = DiffHighlighter(), probe = LoaderProbe()
        #expect(try await worker.registerCustomLanguage("lazy-fixture") { try await probe.load() })
        #expect(try await !worker.registerCustomLanguage("lazy-fixture") { throw DiffError.invalidPatch("duplicate used") })
        #expect(await probe.calls == 0)
        let file = FileContents(name: "f", contents: "hello\n", lang: "lazy-fixture")
        async let a = worker.prepare(oldFile: file, newFile: file)
        async let b = worker.prepare(oldFile: file, newFile: file)
        let (first, second) = try await (a, b)
        #expect(first.newTokens == second.newTokens)
        #expect(await probe.calls == 1)
        try await worker.preload(languages: ["lazy-fixture"])
        #expect(await probe.calls == 1)
        let plain = try await worker.prepare(oldFile: setLanguageOverride(file, language: "text"), newFile: setLanguageOverride(file, language: "text"))
        #expect(first.newTokens != plain.newTokens)
    }
    @Test func failedLoadsRetryAndReservedNamesReject() async throws {
        let worker = DiffHighlighter(), probe = LoaderProbe()
        try await worker.registerCustomLanguage("lazy-fixture") { try await probe.load(failFirst: true) }
        do { try await worker.preload(languages: ["lazy-fixture"]); Issue.record("Expected loader failure") }
        catch {}
        try await worker.preload(languages: ["lazy-fixture"])
        #expect(await probe.calls == 2)
        for name in ["text", "ansi"] {
            do { try await worker.registerCustomLanguage(name) { [] }; Issue.record("Reserved name accepted") }
            catch {}
        }
    }
}
