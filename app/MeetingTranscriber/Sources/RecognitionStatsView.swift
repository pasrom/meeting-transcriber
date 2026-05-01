import AppKit
import SwiftUI

/// Surfaces aggregate counts from `recognition_log.jsonl` so the user can
/// verify whether `SpeakerMatcher` quality drifts over time. The JSONL file
/// remains the source of truth; this view is read-only.
struct RecognitionStatsView: View {
    @State private var aggregate: RecognitionStats.Aggregate?
    @State private var windowDays: WindowChoice = .thirty

    private let log: RecognitionStatsLog

    init(log: RecognitionStatsLog) {
        self.log = log
    }

    enum WindowChoice: Int, CaseIterable, Identifiable {
        case seven = 7, thirty = 30, ninety = 90
        var id: Int {
            rawValue
        }

        var label: String {
            "Last \(rawValue) days"
        }
    }

    var body: some View {
        Section("Recognition Stats") {
            Picker("Window", selection: $windowDays) {
                ForEach(WindowChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            if let aggregate {
                if aggregate.total > 0 {
                    statsBody(aggregate)
                } else {
                    Text("No data yet — confirm a meeting to start collecting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, alignment: .center)
            }

            HStack {
                Button("Open Log Folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([RecognitionStatsLog.defaultPath])
                }
                Spacer()
                Button("Reload") {
                    Task { await reload() }
                }
            }
        }
        .task(id: windowDays) { await reload() }
    }

    @ViewBuilder
    private func statsBody(_ agg: RecognitionStats.Aggregate) -> some View {
        LabeledContent("Total confirmations", value: "\(agg.total)")
        statRow(.accepted, count: agg.counts[.accepted] ?? 0, total: agg.total)
        statRow(.corrected, count: agg.counts[.corrected] ?? 0, total: agg.total)
        statRow(.added, count: agg.counts[.added] ?? 0, total: agg.total)
        statRow(.skipped, count: agg.counts[.skipped] ?? 0, total: agg.total)
        statRow(.dismissed, count: agg.counts[.dismissed] ?? 0, total: agg.total)
    }

    @ViewBuilder
    private func statRow(_ action: RecognitionAction, count: Int, total: Int) -> some View {
        let pct = Int((Double(count) / Double(total) * 100).rounded())
        LabeledContent(action.rawValue.capitalized) {
            HStack(spacing: 8) {
                Text("\(count)")
                Text("(\(pct)%)").foregroundStyle(.secondary).font(.caption)
                ProgressView(value: Double(count), total: Double(total))
                    .frame(width: 80)
            }
        }
    }

    private func reload() async {
        let now = Date()
        let interval = TimeInterval(windowDays.rawValue * 86400)
        let events = await log.loadRecent(within: interval, now: now)
        aggregate = RecognitionStats.aggregate(
            events: events,
            from: now.addingTimeInterval(-interval),
            to: now,
        )
    }
}
