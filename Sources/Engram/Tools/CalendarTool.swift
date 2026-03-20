import Foundation
import EventKit

/// Native macOS Calendar access via EventKit.
/// No API, no bridge — reads directly from the system calendar store.
public struct CalendarTool: Tool {
    private let store = EKEventStore()

    public init() {}

    public var name: String { "calendar" }
    public var description: String {
        """
        Access the macOS Calendar. Actions: today (today's events), upcoming (next N days), \
        search (find events by keyword), create (add an event). Reads from all calendars.
        """
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "action": Schema.stringEnum(description: "What to do",
                values: ["today", "upcoming", "search", "create"]),
            "days": Schema.number(description: "Number of days to look ahead (default: 7, for 'upcoming')"),
            "query": Schema.string(description: "Search keyword (for 'search')"),
            "title": Schema.string(description: "Event title (for 'create')"),
            "date": Schema.string(description: "Event date YYYY-MM-DD (for 'create')"),
            "time": Schema.string(description: "Event time HH:MM (for 'create')"),
            "duration": Schema.number(description: "Duration in minutes (default: 60, for 'create')"),
        ], required: ["action"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let action = input["action"]?.stringValue else {
            return "{\"error\": \"Missing action\"}"
        }

        // Request access
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            granted = await withCheckedContinuation { cont in
                store.requestAccess(to: .event) { g, _ in cont.resume(returning: g) }
            }
        }
        guard granted else {
            return "{\"error\": \"Calendar access denied. Grant access in System Settings > Privacy > Calendars.\"}"
        }

        switch action {
        case "today":
            return fetchEvents(from: Calendar.current.startOfDay(for: Date()),
                             to: Calendar.current.startOfDay(for: Date().addingTimeInterval(86400)))
        case "upcoming":
            let days = Int(input["days"]?.numberValue ?? 7)
            return fetchEvents(from: Date(), to: Date().addingTimeInterval(Double(days) * 86400))
        case "search":
            guard let query = input["query"]?.stringValue else {
                return "{\"error\": \"Missing query\"}"
            }
            return searchEvents(query: query)
        case "create":
            return await createEvent(input: input)
        default:
            return "{\"error\": \"Unknown action: \(action)\"}"
        }
    }

    private func fetchEvents(from start: Date, to end: Date) -> String {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        if events.isEmpty { return "No events found." }

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d, h:mm a"

        return events.map { event in
            let time = formatter.string(from: event.startDate)
            let cal = event.calendar.title
            let loc = event.location.map { " @ \($0)" } ?? ""
            return "- \(time): \(event.title ?? "Untitled") [\(cal)]\(loc)"
        }.joined(separator: "\n")
    }

    private func searchEvents(query: String) -> String {
        let start = Date().addingTimeInterval(-30 * 86400)
        let end = Date().addingTimeInterval(90 * 86400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { ($0.title ?? "").localizedCaseInsensitiveContains(query) ||
                      ($0.location ?? "").localizedCaseInsensitiveContains(query) }
            .sorted { $0.startDate < $1.startDate }
            .prefix(10)

        if events.isEmpty { return "No events matching '\(query)'." }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return events.map { "- \(formatter.string(from: $0.startDate)): \($0.title ?? "Untitled")" }
            .joined(separator: "\n")
    }

    private func createEvent(input: [String: JSONValue]) async -> String {
        guard let title = input["title"]?.stringValue else {
            return "{\"error\": \"Missing title\"}"
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.calendar = store.defaultCalendarForNewEvents

        let dateStr = input["date"]?.stringValue ?? ""
        let timeStr = input["time"]?.stringValue ?? "09:00"
        let duration = input["duration"]?.numberValue ?? 60

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        if let date = formatter.date(from: "\(dateStr) \(timeStr)") {
            event.startDate = date
        } else {
            event.startDate = Date().addingTimeInterval(3600)
        }
        event.endDate = event.startDate.addingTimeInterval(duration * 60)

        do {
            try store.save(event, span: .thisEvent)
            let f = DateFormatter(); f.dateFormat = "EEE MMM d, h:mm a"
            return "Created: \(title) on \(f.string(from: event.startDate))"
        } catch {
            return "{\"error\": \"Failed to create event: \(error.localizedDescription)\"}"
        }
    }
}
