import Foundation
import Shiki
import Testing
@testable import ShikiDiffs

private actor ThemeProbe {
    var calls = 0
    func load(failFirst: Bool = false, wrongName: Bool = false) async throws -> ShikiTheme {
        calls += 1
        let call = calls
        try await Task.sleep(for: .milliseconds(20))
        if failFirst && call == 1 { throw DiffError.invalidPatch("loader failure") }
        var theme = try JSONDecoder().decode(ShikiTheme.self, from: Data(##"{"name":"lazy-theme","type":"light","colors":{"editor.foreground":"#123456","editor.background":"#ffffff","gitDecoration.modifiedResourceForeground":"#445566"},"tokenColors":[]}"##.utf8))
        if wrongName { theme.name = "wrong" }
        return theme
    }
}
struct LazyThemeTests {
    @Test func bundledRegistrationsSurviveCleanupAndCannotBeReplaced() async throws {
        let worker = DiffHighlighter()
        for name in ["pierre-light", "pierre-dark"] {
            #expect(await !worker.registerCustomTheme(name) { throw DiffError.invalidPatch("replaced Pierre") })
            _ = try await worker.resolveTheme(name)
        }
        let original = try await worker.resolveTheme("github-dark")
        #expect(await !worker.registerCustomTheme("github-dark") { throw DiffError.invalidPatch("replaced bundle") })
        await worker.cleanUpResolvedThemes()
        #expect(await !worker.registerCustomTheme("github-dark") { throw DiffError.invalidPatch("replaced after cleanup") })
        #expect(try await worker.resolveTheme("github-dark") == original)

        // A custom loader registered before bundled fallback resolution still wins.
        let fresh = DiffHighlighter()
        #expect(await fresh.registerCustomTheme("github-dark") {
            ShikiTheme(name: "github-dark", type: .light, tokenColors: [], colors: ["editor.foreground": "#123456"])
        })
        #expect(try await fresh.resolveTheme("github-dark").fg == "#123456")
    }
    @Test func seededCacheAndLoaderRegistryRemainSeparate() async throws {
        let worker = DiffHighlighter()
        let seeded = normalizeTheme(ShikiTheme(name: "seed-only", type: .light, tokenColors: []))
        try await worker.attachResolvedThemes([seeded])
        #expect(try await worker.getResolvedOrResolveTheme("seed-only") == seeded)
        do { _ = try await worker.resolveTheme("seed-only"); Issue.record("Missing loader accepted") }
        catch { #expect(String(describing: error).contains("No valid theme loader")) }
        // Bulk preflight reserves earlier valid fallbacks even if a later name fails.
        do { _ = try await worker.resolveThemes(["github-light", "missing-theme"]); Issue.record("Missing theme accepted") }
        catch { }
        #expect(await !worker.registerCustomTheme("github-light") { throw DiffError.invalidPatch("replaced preflight") })
    }
    @Test func bulkThemeResolutionPreservesOrder() async throws {
        let worker = DiffHighlighter(), probe = ThemeProbe()
        await worker.registerCustomTheme("lazy-theme") { try await probe.load() }
        _ = try await worker.resolveTheme("pierre-dark")
        let values = try await worker.resolveThemes(["lazy-theme", "pierre-dark", "lazy-theme"])
        #expect(values.map(\.name) == ["lazy-theme", "pierre-dark", "lazy-theme"])
        #expect(await probe.calls == 1)
        #expect(await !worker.areThemesAttached(["lazy-theme"]))
    }
    @Test func resolutionStateAndBundledCleanup() async throws {
        let worker = DiffHighlighter(), probe = ThemeProbe()
        await worker.registerCustomTheme("lazy-theme") { try await probe.load() }
        let theme = try await worker.resolveTheme("lazy-theme")
        #expect(await worker.hasResolvedThemes(["lazy-theme"]))
        #expect(await !worker.areThemesAttached(["lazy-theme"]))
        #expect(try await worker.getResolvedThemes(["lazy-theme"]).first == theme)
        try await worker.attachResolvedThemes(named: ["lazy-theme"])
        #expect(await worker.areThemesAttached(["lazy-theme"]))
        let bundled = try await worker.resolveTheme("github-dark")
        try await worker.attachResolvedThemes([bundled])
        await worker.cleanUpResolvedThemes()
        #expect(await !worker.hasResolvedThemes(["lazy-theme", "github-dark"]))
        #expect(await !worker.areThemesAttached(["lazy-theme", "github-dark"]))
        try await worker.preload(themes: ["lazy-theme", "github-dark", "pierre-dark"])
        #expect(await probe.calls == 2)
        #expect(await worker.areThemesAttached(["lazy-theme", "github-dark", "pierre-dark"]))
        let eager = DiffHighlighter()
        try await eager.registerTheme(try await probe.load())
        await eager.cleanUpResolvedThemes()
        try await eager.preload(themes: ["lazy-theme"])
        #expect(await eager.areThemesAttached(["lazy-theme"]))
    }
    @Test func concurrentLoadsNormalizeColorsAndRetainFirstLoader() async throws {
        let worker = DiffHighlighter(), probe = ThemeProbe()
        #expect(await worker.registerCustomTheme("lazy-theme") { try await probe.load() })
        #expect(await !worker.registerCustomTheme("lazy-theme") { throw DiffError.invalidPatch("duplicate used") })
        #expect(await probe.calls == 0)
        let file = FileContents(name: "f.txt", contents: "hello\n")
        var options = DiffRenderOptions(); options.theme = "lazy-theme"
        async let a = worker.prepare(oldFile: file, newFile: file, options: options)
        async let b = worker.prepare(oldFile: file, newFile: file, options: options)
        let (first, second) = try await (a, b)
        #expect(await probe.calls == 1)
        #expect(first.foreground == "#123456" && first.background == "#ffffff")
        #expect(first.palette.isLight && first.palette.modified == "#445566")
        #expect(first.newTokens == second.newTokens)
        try await worker.preload(themes: ["lazy-theme"])
        #expect(await probe.calls == 1)
    }
    @Test func retryAndNameValidation() async throws {
        let worker = DiffHighlighter(), probe = ThemeProbe()
        await worker.registerCustomTheme("lazy-theme") { try await probe.load(failFirst: true) }
        do { try await worker.preload(themes: ["lazy-theme"]); Issue.record("Expected failure") } catch {}
        try await worker.preload(themes: ["lazy-theme"])
        #expect(await probe.calls == 2)
        let other = DiffHighlighter()
        await other.registerCustomTheme("lazy-theme") { try await probe.load(wrongName: true) }
        do { try await other.preload(themes: ["lazy-theme"]); Issue.record("Mismatched name accepted") } catch {}
    }
}

private actor CleanupThemeProbe {
    var calls = 0
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func waitForStart() async {
        if calls > 0 { return }
        await withCheckedContinuation { started = $0 }
    }
    func finishFirstLoad() { release?.resume(); release = nil }
    func load() async -> ShikiTheme {
        calls += 1
        if calls == 1 {
            await withCheckedContinuation { continuation in
                release = continuation
                started?.resume(); started = nil
            }
        }
        return ShikiTheme(name: "cleanup-theme", type: .dark, foreground: "#ffffff", background: "#000000")
    }
}

extension LazyThemeTests {
    @Test(arguments: ["preload", "prepare", "preview"])
    func disposalRejectsOldThemeWorkWithoutDamagingReload(_ operation: String) async throws {
        let worker = DiffHighlighter(), probe = CleanupThemeProbe()
        await worker.registerCustomTheme("cleanup-theme") { await probe.load() }
        let pending = Task {
            if operation == "preload" { try await worker.preload(themes: ["cleanup-theme"]) }
            else {
                let file = FileContents(name: "f.txt", contents: "hello\n")
                let diff = try parseDiffFromFile(file, file)
                var options = DiffRenderOptions(); options.theme = "cleanup-theme"
                if operation == "preview" { _ = try await worker.preparePreview(diff, options: options, highlightedLineCount: 1) }
                else { _ = try await worker.prepare(diff, options: options) }
            }
        }
        await probe.waitForStart()
        await worker.disposeHighlighter()
        #expect(await !worker.isHighlighterLoaded)
        #expect(await !worker.hasResolvedThemes(["cleanup-theme"]))
        // The second loader completes before the cancelled first loader returns.
        try await worker.preload(themes: ["cleanup-theme"])
        #expect(await probe.calls == 2)
        await probe.finishFirstLoad()
        do { try await pending.value; Issue.record("Disposed theme work succeeded") }
        catch { #expect(error is CancellationError) }
        #expect(await worker.isHighlighterLoaded)
        #expect(await worker.areThemesAttached(["cleanup-theme"]))
        #expect(await worker.hasResolvedThemes(["cleanup-theme"]))
        #expect(await probe.calls == 2)
    }
    @Test func cleanupRejectsLateResultsAndPreservesLoader() async throws {
        let worker = DiffHighlighter(), probe = CleanupThemeProbe()
        await worker.registerCustomTheme("cleanup-theme") { await probe.load() }
        let pending = Task { try await worker.preload(themes: ["cleanup-theme"]) }
        await probe.waitForStart()
        await worker.cleanUpResolvedThemes()
        await probe.finishFirstLoad()
        do { try await pending.value; Issue.record("Stale theme was attached") }
        catch { #expect(error is CancellationError) }
        try await worker.preload(themes: ["cleanup-theme"])
        #expect(await probe.calls == 2)
        await worker.cleanUpResolvedThemes()
        try await worker.preload(themes: ["cleanup-theme"])
        #expect(await probe.calls == 3)
    }
}
