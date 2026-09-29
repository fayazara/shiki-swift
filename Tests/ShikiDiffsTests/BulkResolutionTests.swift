import Shiki
import Testing
@testable import ShikiDiffs

private actor SlowLoadGate {
    private var release: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false
    var forced = false
    private var finished = false
    var calls = 0
    func suspend() async {
        calls += 1
        if finished { return }
        await withCheckedContinuation { continuation in
            release = continuation; didStart = true
            started?.resume(); started = nil
        }
    }
    func waitForStart() async {
        if didStart { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(forced: Bool = false) { finished = true; self.forced = forced; release?.resume(); release = nil }
}
struct BulkResolutionTests {
    @Test func languageCleanupPreservesPendingBulkLoad() async throws {
        let worker = DiffHighlighter(), gate = SlowLoadGate()
        try await worker.registerCustomLanguage("slow") { await gate.suspend(); return [] }
        let pending = Task { try await worker.resolveLanguages(["text", "slow", "ansi"]) }
        await gate.waitForStart()
        await worker.cleanUpResolvedLanguages()
        #expect(await !worker.hasResolvedLanguages(["slow"]))
        await gate.finish()
        #expect(try await pending.value.map(\.name) == ["slow"])
        #expect(await worker.hasResolvedLanguages(["slow"]))
        #expect(await !worker.areLanguagesAttached(["slow"]))
        _ = try await worker.getResolvedOrResolveLanguage("slow")
        #expect(await gate.calls == 1)
    }
    @Test func themeCleanupRejectsPendingBulkLoadAndAllowsRetry() async throws {
        let worker = DiffHighlighter(), gate = SlowLoadGate()
        await worker.registerCustomTheme("slow") { await gate.suspend(); return ShikiTheme(name: "slow", type: .dark) }
        let pending = Task { try await worker.resolveThemes(["slow"]) }
        await gate.waitForStart()
        await worker.cleanUpResolvedThemes()
        await gate.finish()
        do { _ = try await pending.value; Issue.record("Stale bulk theme accepted") }
        catch { #expect(error is CancellationError) }
        #expect(await !worker.hasResolvedThemes(["slow"]))
        #expect(await !worker.areThemesAttached(["slow"]))
        _ = try await worker.resolveThemes(["slow"])
        #expect(await gate.calls == 2)
        #expect(await worker.hasResolvedThemes(["slow"]))
    }
    @Test func languageFailureDoesNotWaitForEarlierSlowLoad() async throws {
        let worker = DiffHighlighter(), gate = SlowLoadGate()
        try await worker.registerCustomLanguage("slow") { await gate.suspend(); return [] }
        try await worker.registerCustomLanguage("failure") { await gate.waitForStart(); throw DiffError.invalidPatch("expected") }
        let watchdog = Task { try await Task.sleep(for: .seconds(2)); await gate.finish(forced: true) }
        do { _ = try await worker.resolveLanguages(["slow", "failure"]); Issue.record("Expected failure") } catch {}
        #expect(await !gate.forced)
        watchdog.cancel(); await gate.finish()
        _ = try await worker.getResolvedOrResolveLanguage("slow")
        #expect(await worker.hasResolvedLanguages(["slow"]))
    }
    @Test func themeFailureDoesNotCancelIndependentLoad() async throws {
        let worker = DiffHighlighter(), gate = SlowLoadGate()
        await worker.registerCustomTheme("slow") { await gate.suspend(); return ShikiTheme(name: "slow", type: .dark) }
        await worker.registerCustomTheme("failure") { await gate.waitForStart(); throw DiffError.invalidPatch("expected") }
        let watchdog = Task { try await Task.sleep(for: .seconds(2)); await gate.finish(forced: true) }
        do { _ = try await worker.resolveThemes(["slow", "failure"]); Issue.record("Expected failure") } catch {}
        #expect(await !gate.forced)
        watchdog.cancel(); await gate.finish()
        _ = try await worker.resolveTheme("slow")
        #expect(await worker.hasResolvedThemes(["slow"]))
    }
}
