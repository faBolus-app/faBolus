import PhoneApp
import SwiftUI
import faBolusCore

/// The pump's history as a logbook, newest first, by day. It's saved on the phone, so it's there at launch
/// before the pump is reached.
struct LogbookView: View {
    @Bindable var model: AppModel
    @State private var filter: HistoryEvent.Category?

    private var filtered: [HistoryEvent] {
        filter.map { f in model.logbook.filter { $0.category == f } } ?? model.logbook
    }

    private var sections: [(day: Date, events: [HistoryEvent])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { day in (day, (groups[day] ?? []).sorted { $0.date > $1.date }) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.logbook.isEmpty {
                    ContentUnavailableView(
                        "No history yet", systemImage: "clock.arrow.circlepath",
                        description: Text(
                            "Pump history loads after connecting. Boluses, carbs, basal changes, alerts and cartridge events appear here."
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
            .refreshable { await model.syncHistory() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("All events") { filter = nil }
                        Divider()
                        ForEach(HistoryEvent.Category.allCases, id: \.self) { category in
                            Button {
                                filter = category
                            } label: {
                                Label(category.rawValue.capitalized, systemImage: category.symbol)
                            }
                        }
                    } label: {
                        Image(
                            systemName: filter == nil
                                ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Filter events")
                    .accessibilityValue(filter.map { $0.rawValue.capitalized } ?? "All events")
                }
            }
        }
    }
}

struct LogbookRow: View {
    let event: HistoryEvent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: event.category.symbol).frame(width: 26)
                .foregroundStyle(event.category == .couldNotDeliver ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.body)
                if !event.detail.isEmpty { Text(event.detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(event.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
