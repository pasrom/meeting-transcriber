import AppKit
import SwiftUI

/// Surfaces average per-stage processing durations from `stage_timing.jsonl` so
/// the user can tell whether a long-running transcription/diarization is normal.
/// The JSONL file remains the source of truth; this view is read-only.
struct ProcessingStatsView: View {
    // swiftlint:disable:next discouraged_optional_collection
    @State private var aggregates: [StageConfig: StageTimingStats.StageAggregate]?
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
                    ForEach(aggregates.keys.sorted(by: StageConfig.displayedBefore), id: \.self) { config in
                        if let agg = aggregates[config] {
                            statRow(config, agg)
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

    private func statRow(_ config: StageConfig, _ agg: StageTimingStats.StageAggregate) -> some View {
        LabeledContent(config.label) {
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
        aggregates = StageTimingStats.aggregateByConfig(events: events)
    }
}

/// How a config is shown in the stats table. Off the view so the label and
/// the row order can be pinned without instantiating it.
extension StageConfig {
    /// "Stage · mode · engine" (mode omitted when nil, e.g. transcription);
    /// the trailing `Engine` suffix is trimmed for brevity. A stage the engine
    /// does not scope (echo cancellation) is the bare stage name, not
    /// "· unknown": its events carry no engine on purpose, while a scoped
    /// event without one is an anomaly worth showing as such.
    var label: String {
        guard stage.isEngineScoped else { return stage.label }
        let raw = engine ?? "unknown"
        let trimmed = raw.hasSuffix("Engine") ? String(raw.dropLast("Engine".count)) : raw
        var parts = [stage.label]
        if let diarizerMode { parts.append(diarizerMode) }
        parts.append(trimmed)
        return parts.joined(separator: " · ")
    }

    /// Stage order first (the `StageKind` declaration order: echo cancellation
    /// → transcribe → diarize → protocol), then engine, then mode — a total
    /// order over distinct configs (no label rebuilds), so rows are stable and
    /// grouped.
    static func displayedBefore(_ a: StageConfig, _ b: StageConfig) -> Bool {
        let ia = StageKind.allCases.firstIndex(of: a.stage) ?? 0
        let ib = StageKind.allCases.firstIndex(of: b.stage) ?? 0
        if ia != ib { return ia < ib }
        if a.engine != b.engine { return (a.engine ?? "") < (b.engine ?? "") }
        return (a.diarizerMode ?? "") < (b.diarizerMode ?? "")
    }
}
