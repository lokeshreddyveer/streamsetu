import Foundation
import MetricKit
import os

/// Collects the system's own smoothness numbers (scroll hitch ratio, time to first draw, hang counts) from MetricKit.
/// Only numbers, kept on the device (latest payload in Application Support, and the unified log); nothing is sent anywhere.
final class SmoothMetricsCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = SmoothMetricsCollector()
    private let log = Logger(subsystem: "app.streamsetu", category: "SmoothMetrics")

    func start() { MXMetricManager.shared.add(self) }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads {
            var summary: [String: Double] = [:]
            if let a = p.animationMetrics { summary["scrollHitchTimeRatioPct"] = a.scrollHitchTimeRatio.value }
            if let l = p.applicationLaunchMetrics, let top = l.histogrammedTimeToFirstDraw.bucketEnumerator.allObjects.compactMap({ $0 as? MXHistogramBucket<UnitDuration> }).max(by: { $0.bucketEnd.value < $1.bucketEnd.value }) {
                summary["slowestLaunchBucketEndMs"] = top.bucketEnd.converted(to: .milliseconds).value
            }
            if let h = p.applicationResponsivenessMetrics, let top = h.histogrammedApplicationHangTime.bucketEnumerator.allObjects.compactMap({ $0 as? MXHistogramBucket<UnitDuration> }).max(by: { $0.bucketEnd.value < $1.bucketEnd.value }) {
                summary["longestHangBucketEndMs"] = top.bucketEnd.converted(to: .milliseconds).value
            }
            record(summary)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let hangs = payloads.reduce(0) { $0 + ($1.hangDiagnostics?.count ?? 0) }
        if hangs > 0 { record(["hangDiagnostics": Double(hangs)]) }
    }

    private func record(_ summary: [String: Double]) {
        guard !summary.isEmpty else { return }
        log.info("smooth metrics: \(summary.map { "\($0.key)=\(Int($0.value))" }.sorted().joined(separator: " "), privacy: .public)")
        let url = StorageService.applicationSupport.appendingPathComponent("SmoothMetrics.json")
        if let data = try? JSONSerialization.data(withJSONObject: summary) { try? data.write(to: url, options: .atomic) }
    }
}
