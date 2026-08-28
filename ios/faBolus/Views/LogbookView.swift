import SwiftUI
import faBolusCore

/// Logbook: the pump's on-device history-log events, decoded by TandemKit's HistoryLogParser and
/// mapped to neutral `HistoryEvent`s. Read-only. Grouped by day, newest first.
struct LogbookView: View {
    @Bindable var model: AppModel
    @State private var filter: HistoryEvent.Category? = nil

    private var filtered: [HistoryEvent] {
        guard let f = filter else { return model.historyEvents }
        return model.historyEvents.filter { $0.category == f }
    }

    /// Events grouped by calendar day, day-sections newest first.
    private var sections: [(day: Date, events: [HistoryEvent])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.date > $1.date }) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.historyEvents.isEmpty {
                    ContentUnavailableView(
                        "No history yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text(
                            "Pump history loads after connecting. Boluses, carbs, basal changes, alerts, and cartridge events appear here."
                        ))
                } else {
                    List {
                        ForEach(sections, id: \.day) { section in
                            Section(section.day.formatted(date: .abbreviated, time: .omitted)) {
                                ForEach(section.events) { LogbookRow(event: $0) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Logbook")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("All events") { filter = nil }
                        Divider()
                        ForEach(HistoryEvent.Category.allCases, id: \.self) { cat in
                            Button {
                                filter = cat
                            } label: {
                                Label(cat.rawValue.capitalized, systemImage: cat.symbol)
                            }
                        }
                    } label: {
                        Image(
                            systemName: filter == nil
                                ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    // The filled-vs-unfilled glyph is a color/shape-only cue for "a filter is
                    // active" — VoiceOver otherwise announces only the raw symbol name. Speak the
                    // control's purpose plus the current filter (or "All events") as its value.
                    .accessibilityLabel("Filter events")
                    .accessibilityValue(filter.map { $0.rawValue.capitalized } ?? "All events")
                }
            }
        }
    }
}

private struct LogbookRow: View {
    let event: HistoryEvent
    // Amber, matching the established informational-not-alarm convention elsewhere in the app
    // (e.g. BolusEntryView's advisory `exclamationmark.triangle` warnings), never red like
    // `.alarm`'s filled triangle — no fabricated urgency.
    private var iconTint: Color { event.category == .couldNotDeliver ? .orange : .secondary }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: event.category.symbol)
                .frame(width: 26)
                .foregroundStyle(iconTint)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.body)
                if !event.detail.isEmpty {
                    Text(event.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(event.date.formatted(date: .omitted, time: .shortened))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
