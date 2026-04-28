import Foundation

enum StatsPeriod: Hashable, CaseIterable, Identifiable {
    case day
    case week
    case month
    case year
    case all
    case custom(DateInterval)

    var id: String {
        switch self {
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .year: return "year"
        case .all: return "all"
        case .custom: return "custom"
        }
    }

    static var allCases: [StatsPeriod] {
        [.day, .week, .month, .year, .all]
    }

    var shortTitle: String {
        switch self {
        case .day: return String(localized: "День")
        case .week: return String(localized: "Неделя")
        case .month: return String(localized: "Месяц")
        case .year: return String(localized: "Год")
        case .all: return String(localized: "Всё")
        case .custom: return String(localized: "Свой")
        }
    }

    func interval(now: Date = .now, calendar: Calendar = .current, minDate: Date? = nil) -> DateInterval {
        switch self {
        case .day:
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
            return DateInterval(start: start, end: end)
        case .week:
            let start = weekStart(for: now, calendar: calendar)
            let end = calendar.date(byAdding: .day, value: 7, to: start) ?? now
            return DateInterval(start: start, end: end)
        case .month:
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
            let end = calendar.date(byAdding: .month, value: 1, to: start) ?? now
            return DateInterval(start: start, end: end)
        case .year:
            let start = calendar.date(from: calendar.dateComponents([.year], from: now)) ?? now
            let end = calendar.date(byAdding: .year, value: 1, to: start) ?? now
            return DateInterval(start: start, end: end)
        case .all:
            let fallbackStart = calendar.date(byAdding: .year, value: -1, to: now) ?? now
            return DateInterval(start: minDate ?? fallbackStart, end: now.addingTimeInterval(1))
        case .custom(let interval):
            return interval
        }
    }

    func previousInterval(current: DateInterval, calendar: Calendar = .current) -> DateInterval? {
        switch self {
        case .day:
            guard let start = calendar.date(byAdding: .day, value: -1, to: current.start) else { return nil }
            return DateInterval(start: start, end: current.start)
        case .week:
            guard let start = calendar.date(byAdding: .day, value: -7, to: current.start) else { return nil }
            return DateInterval(start: start, end: current.start)
        case .month:
            guard let start = calendar.date(byAdding: .month, value: -1, to: current.start) else { return nil }
            return DateInterval(start: start, end: current.start)
        case .year:
            guard let start = calendar.date(byAdding: .year, value: -1, to: current.start) else { return nil }
            return DateInterval(start: start, end: current.start)
        case .custom(let interval):
            let duration = interval.duration
            let end = current.start
            let start = end.addingTimeInterval(-duration)
            return DateInterval(start: start, end: end)
        case .all:
            return nil
        }
    }

    func timelineComponent(for interval: DateInterval) -> Calendar.Component {
        let days = max(1, Int(interval.duration / 86_400))

        switch self {
        case .day:
            return .hour
        case .week:
            return .day
        case .month:
            return .day
        case .custom:
            if days <= 45 {
                return .day
            }
            if days <= 370 {
                return .weekOfYear
            }
            return .month
        default:
            return .month
        }
    }

    private func weekStart(for date: Date, calendar: Calendar) -> Date {
        var cal = calendar
        cal.firstWeekday = 2

        let weekday = cal.component(.weekday, from: date)
        let offset = (weekday + 5) % 7
        let rawStart = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: date)) ?? date
        return cal.startOfDay(for: rawStart)
    }
}
