import XCTest
@testable import ECGRecorder

final class MetricsTests: XCTestCase {
    func testRMSSD() throws {
        let v = try XCTUnwrap(RMSSD().value(rr: [800, 810, 790, 800]))
        XCTAssertEqual(v, 200.0.squareRoot(), accuracy: 1e-9)
    }

    func testSDNN() throws {
        let v = try XCTUnwrap(SDNN().value(rr: [800, 820, 780, 800]))
        XCTAssertEqual(v, (800.0 / 3).squareRoot(), accuracy: 1e-9)
    }

    func testPNN50() throws {
        XCTAssertEqual(try XCTUnwrap(PNN50().value(rr: [800, 860, 800, 900])), 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(PNN50().value(rr: [800, 810, 800, 900])), 100.0 / 3, accuracy: 1e-9)
    }

    func testNeedsTwoIntervals() {
        XCTAssertNil(RMSSD().value(rr: [800]))
        XCTAssertNil(SDNN().value(rr: []))
    }

    func testPipelineWindowTrimsOldBeats() {
        var pipeline = MetricPipeline(windowSeconds: 5)
        var last: [String: Double] = [:]
        for i in 0..<20 { last = pipeline.add(rr: i.isMultiple(of: 2) ? 1000 : 1100, normal: true) }
        // A 5 s window of ~1 s beats holds at most 6 intervals, so RMSSD stays at the alternating 100 ms step.
        XCTAssertEqual(try XCTUnwrap(last["rmssd"]), 100, accuracy: 1e-9)
    }

    func testQualityFlags() {
        XCTAssertNil(RRQuality.flag(rr: 850, contact: true))
        XCTAssertNil(RRQuality.flag(rr: 850, contact: nil))
        XCTAssertEqual(RRQuality.flag(rr: 150, contact: true), "implausible_rr")
        XCTAssertEqual(RRQuality.flag(rr: 3000, contact: true), "implausible_rr")
        XCTAssertEqual(RRQuality.flag(rr: 850, contact: false), "no_contact")
    }

    // MARK: Artifacts (Lipponen & Tarvainen 2019)

    private func artifacts(_ rr: [Double]) -> [Int: ArtifactDetector.Kind] {
        var out: [Int: ArtifactDetector.Kind] = [:]
        for (i, kind) in ArtifactDetector.classify(rr).enumerated() { if let kind { out[i] = kind } }
        return out
    }

    /// Breathing-like variation: 850 ± 40 ms.
    private let breathing = (0..<60).map { 850 + 40 * sin(Double($0) / 3) }

    func testPrematureBeatAndCompensatoryPauseAreEctopic() {
        var rr = breathing
        rr[30] *= 0.6; rr[31] *= 1.4
        XCTAssertEqual(artifacts(rr), [30: .ectopic, 31: .ectopic])
    }

    func testMissedAndExtraBeats() {
        let missed = Array(breathing[..<30]) + [breathing[30] + breathing[31]] + breathing[32...]
        XCTAssertEqual(artifacts(missed), [30: .missed])
        let extra = Array(breathing[..<30]) + [breathing[30] * 0.3, breathing[30] * 0.7] + breathing[31...]
        XCTAssertEqual(artifacts(extra), [30: .extra, 31: .extra])
    }

    func testLargeBreathingSwingsAreNormal() {
        // A relaxed, high-HRV pattern from a real recording: jumps of 400 ms in one beat are sinus rhythm.
        // The previous rule (20% from the median of five) flagged 11% of such beats.
        let rsa = Array([[Double]](repeating: [1150, 1100, 1040, 960, 880, 820, 800, 830, 1200, 1180], count: 10).joined())
        XCTAssertEqual(artifacts(rsa), [:])
    }

    func testRealHeartRateChangeIsNormal() {
        let step = (0..<120).map { ($0 < 60 ? 800 : 600) + 10 * sin(Double($0)) }
        XCTAssertEqual(artifacts(step), [:])
    }

    func testTooFewBeatsAreNeverFlagged() {
        XCTAssertEqual(artifacts([800, 400, 1200]), [:])
    }

    func testDeviceFlagsAndGapsSplitTheRuns() {
        func beat(_ rr: Double, _ flag: String? = nil, gap: Bool = false) -> BeatRecord {
            BeatRecord(rr: rr, deviceFlag: flag, t: 0, hr: nil, afterGap: gap)
        }
        // 900 -> 600 would look like an artifact if the runs were joined.
        let beats = breathing.prefix(30).map { beat($0) } + [beat(300, "no_contact")] + breathing.prefix(30).map { beat($0 - 250) }
        let flags = ArtifactDetector.flags(beats)
        XCTAssertEqual(flags[30], "no_contact")
        XCTAssertEqual(flags.compactMap { $0 }, ["no_contact"])
        let gapped = breathing.prefix(30).map { beat($0) } + [beat(600, gap: true)] + breathing.prefix(29).map { beat($0 - 250) }
        XCTAssertEqual(ArtifactDetector.flags(gapped).compactMap { $0 }, [])
    }

    func testLiveNumbersIgnoreAPrematureBeat() throws {
        var live = LiveAnalyzer(windowSeconds: 60)
        var rr = (0..<90).map { 850 + 40 * sin(Double($0) / 3) }
        for (i, x) in rr.enumerated() { live.add(rr: x, deviceFlag: nil, at: Double(i)) }
        let clean = try XCTUnwrap(live.latest["rmssd"])
        rr = [rr[0] * 0.6, rr[1] * 1.4, rr[2], rr[3]]
        for (i, x) in rr.enumerated() { live.add(rr: x, deviceFlag: nil, at: Double(90 + i)) }
        XCTAssertEqual(try XCTUnwrap(live.latest["rmssd"]), clean, accuracy: 3, "premature beat must not move RMSSD")
        XCTAssertEqual(try XCTUnwrap(live.artifactShare), 2.0 / 30, accuracy: 1e-9)
    }

    // MARK: Signal quality

    func testKurtosisSeparatesECGFromNoise() throws {
        // Spikes once a second on a breathing baseline, against Gaussian-like noise.
        let n = 130 * 10
        let ecg = (0..<n).map { i -> Float in (i % 130 < 3 ? 1000 : 0) + Float(200 * sin(Double(i) / 80)) }
        var seed: UInt64 = 42
        let noise = (0..<n).map { _ -> Float in
            (0..<6).reduce(Float(0)) { acc, _ in
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return acc + Float(seed >> 40) / Float(1 << 24) - 0.5
            } * 300
        }
        XCTAssertGreaterThan(try XCTUnwrap(SignalQuality.kurtosis(ecg)), 10)
        XCTAssertLessThan(try XCTUnwrap(SignalQuality.kurtosis(noise)), SignalQuality.cleanKurtosis)
        XCTAssertNil(SignalQuality.kurtosis(Array(ecg.prefix(n - 1))), "needs 10 s")
        XCTAssertFalse(SignalQuality.isNoisy(kurtosis: 18, artifactShare: 2.0 / 30))
        XCTAssertTrue(SignalQuality.isNoisy(kurtosis: 3, artifactShare: nil))
        XCTAssertTrue(SignalQuality.isNoisy(kurtosis: 18, artifactShare: 0.3))
    }

    // MARK: Successive differences, warm-up and gaps

    private func run(_ pipeline: inout MetricPipeline, _ beats: [(Double, Bool)]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (rr, normal) in beats { out = pipeline.add(rr: rr, normal: normal) }
        return out
    }

    func testFlaggedBeatBreaksTheSuccessiveDifference() throws {
        // 40 alternating beats (diff 20 ms), a flagged beat, then more. Without adjacency, the 800 -> 900 jump
        // across the flagged beat would count as a successive difference of 100 ms.
        var pipeline = MetricPipeline(windowSeconds: 600)
        let before = (0..<40).map { (i: Int) -> (Double, Bool) in (i.isMultiple(of: 2) ? 800 : 820, true) }
        let after = (0..<40).map { (i: Int) -> (Double, Bool) in (i.isMultiple(of: 2) ? 900 : 920, true) }
        let out = run(&pipeline, before + [(400, false)] + after)
        XCTAssertEqual(try XCTUnwrap(out["rmssd"]), 20, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(out["pnn50"]), 0, accuracy: 1e-9)
    }

    func testNothingIsReportedUntilThereIsEnoughCleanData() {
        var pipeline = MetricPipeline(windowSeconds: 60)       // needs 30 s of NN intervals
        let beats = [(Double, Bool)](repeating: (1000, true), count: 29)
        XCTAssertTrue(run(&pipeline, beats).isEmpty, "RMSSD from under 30 s of beats is noise")
        XCTAssertNotNil(pipeline.add(rr: 1000, normal: true)["rmssd"])
        pipeline.reset()
        XCTAssertTrue(pipeline.add(rr: 1000, normal: true).isEmpty, "a gap starts the warm-up over")
    }

    func testMostlyFlaggedWindowReportsNothing() {
        var pipeline = MetricPipeline(windowSeconds: 60)
        let beats = (0..<120).map { (i: Int) -> (Double, Bool) in (1000, i.isMultiple(of: 3)) }   // two thirds flagged
        XCTAssertTrue(run(&pipeline, beats).isEmpty)
    }

    func testSummaryUsesAdjacentPairsAndMeanNN() throws {
        var summary = NNSummary()
        for i in 0..<40 { summary.add(rr: i.isMultiple(of: 2) ? 1000 : 1010, flag: nil) }
        summary.add(rr: 300, flag: "implausible_rr")
        for i in 0..<40 { summary.add(rr: i.isMultiple(of: 2) ? 1200 : 1210, flag: nil) }
        XCTAssertEqual(try XCTUnwrap(summary.rmssd), 10, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(summary.meanHR), 60_000 / 1105, accuracy: 1e-9)
        XCTAssertEqual(summary.intervals, 81)
        XCTAssertEqual(summary.flagged, 1)
        XCTAssertTrue(summary.note.contains(";rmssd_ms=10.0;"))
        XCTAssertTrue(summary.note.hasSuffix(";rr_count=81;rr_flagged=1;rr_implausible_rr=1"))
    }

    func testSummaryNeedsThirtySeconds() {
        var summary = NNSummary()
        for _ in 0..<20 { summary.add(rr: 1000, flag: nil) }
        XCTAssertNil(summary.rmssd)
        XCTAssertNotNil(summary.meanHR)
    }

    func testSilenceBetweenArrivalsIsAGap() {
        var analyzer = LiveAnalyzer(windowSeconds: 60)
        for i in 0..<40 { analyzer.add(rr: 1000 + 40 * sin(Double(i) / 3), deviceFlag: nil, at: Double(i)) }
        XCTAssertNotNil(analyzer.latest["rmssd"])
        analyzer.add(rr: 1000, deviceFlag: nil, at: 39 + BeatTiming.gapSeconds + 1)
        XCTAssertNil(analyzer.latest["rmssd"], "beats after lost data start a new window")
    }

    func testRRRoundingMatchesTheFile() {
        let raw = 833.0 * 1000 / 1024                          // 813.4765625 ms from the H10's 1/1024 s count
        XCTAssertEqual(RRQuality.rounded(raw), 813.5)
        XCTAssertEqual(String(format: "%.1f", RRQuality.rounded(raw)), "813.5")
    }
}
