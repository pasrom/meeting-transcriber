import AppKit
import SwiftUI

/// Surfaces average per-stage processing durations from `stage_timing.jsonl` so
/// the user can tell whether a long-running transcription/diarization is normal.
/// The JSONL file remains the source of truth; this view is read-only.
struct ProcessingStatsView: View {
    // swiftlint:disable:next discouraged_optional_collection
    @State private var aggregates: [StageKind: StageTimingStats.StageAggregate]?
    @State private var windowDays: WindowChoice = .thirty

    private let log: StageTimingLog

    init(log: StageTimingLog) {
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
        Section("Processing Stats") {
            Picker("Window", selection: $windowDays) {
                ForEach(WindowChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            if let aggregates {
                if aggregates.isEmpty {
                    Text("No data yet — process a meeting to start collecting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(StageKind.allCases, id: \.self) { stage in
                        if let agg = aggregates[stage] {
                            statRow(stage, agg)
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, alignment: .center)
            }

            HStack {
                Button("Open Log Folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([StageTimingLog.defaultPath])
                }
                Spacer()
                Button("Reload") {
                    Task { await reload() }
                }
            }
        }
        .task(id: windowDays) { await reload() }
    }

    private func statRow(_ stage: StageKind, _ agg: StageTimingStats.StageAggregate) -> some View {
        LabeledContent(stage.label) {
            HStack(spacing: 8) {
                Text("Ø \(formattedTime(agg.avgWallClockSeconds))")
                if let rtf = agg.avgRTF {
                    // RTF is processing-seconds per audio-second; ×60 reads as
                    // "processing seconds per minute of audio" — the intuitive form.
                    Text(String(format: "%.1f s/audio-min", rtf * 60))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Text("(n=\(agg.count))")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    private func reload() async {
        let interval = TimeInterval(windowDays.rawValue * 86400)
        let events = await log.loadRecent(within: interval)
        aggregates = StageTimingStats.aggregate(events: events)
    }
}
