//
//  EventModel.swift
//  Calendr
//
//  Created by Paker on 24/12/20.
//  Original source: https://github.com/pakerwreah/Calendr
//  Modified by Alexander on 2025-05-18.
//

import Foundation

struct EventModel: Equatable, Identifiable {
    let id: String
    let start: Date
    let end: Date
    let title: String
    let location: String?
    let notes: String?
    let url: URL?
    let isAllDay: Bool
    let type: EventType
    let calendar: CalendarModel
    let participants: [Participant]
    let timeZone: TimeZone?
    let hasRecurrenceRules: Bool
    let priority: Priority?
}

enum AttendanceStatus: Comparable {
    case accepted
    case maybe
    case pending
    case declined
    case unknown

    private var comparisonValue: Int {
        switch self {
        case .accepted: return 1
        case .maybe: return 2
        case .declined: return 3
        case .pending: return 4
        case .unknown: return 5
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        return lhs.comparisonValue < rhs.comparisonValue
    }
}

enum EventType: Equatable {
    case event(AttendanceStatus)
    case birthday
    case reminder(completed: Bool)
}

enum EventStatus: Equatable {
    case upcoming
    case inProgress
    case ended
}

extension EventType {
    var isEvent: Bool { if case .event = self { return true } else { return false } }
    var isBirthday: Bool { self ~= .birthday }
    var isReminder: Bool { if case .reminder = self { return true } else { return false } }
}

extension EventModel {
    
    var eventStatus: EventStatus {
        if start > Date() {
            return .upcoming
        } else if end > Date() {
            return .inProgress
        } else {
            return .ended
        }
    }
        
    var attendance: AttendanceStatus { if case .event(let attendance) = type { return attendance } else { return .unknown } }

    var isMeeting: Bool { !participants.isEmpty }

    /// The link that joins this meeting, if the invitation carries one.
    ///
    /// Invitations do not agree on where to put it: Google Calendar fills in
    /// the event's URL field, Outlook writes it into the body, and people
    /// paste it into the location by hand. All three are read, in that order,
    /// and the first recognised link wins.
    var meetingURL: URL? {
        if let url, Self.isMeetingLink(url) { return url }
        for text in [location, notes].compactMap({ $0 }) {
            if let found = Self.firstMeetingLink(in: text) { return found }
        }
        return nil
    }

    /// Hosts whose links join a call rather than open a page. Deliberately a
    /// short list of exact hosts: matching anything that merely looks like a
    /// meeting would put a Join button on invitations that have no call, and
    /// a button that sometimes goes nowhere is worse than no button.
    private static let meetingHosts = [
        "teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft",
        "meet.google.com", "zoom.us", "webex.com", "whereby.com", "meet.jit.si",
    ]

    static func isMeetingLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        // The leading dot matters: without it "notzoom.us" would match.
        return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// `NSDataDetector` rather than a regular expression of our own: finding
    /// URLs inside prose is a solved problem, and invitation bodies are full
    /// of wrapped lines, trailing punctuation and HTML that a hand-rolled
    /// pattern gets wrong.
    static func firstMeetingLink(in text: String) -> URL? {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(
                  types: NSTextCheckingResult.CheckingType.link.rawValue
              )
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            if let url = match.url, isMeetingLink(url) { return url }
        }
        return nil
    }

    func calendarAppURL() -> URL? {

        guard let id = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }

        guard !type.isReminder else {
            return URL(string: "x-apple-reminderkit://remcdreminder/\(id)")
        }

        let date: String
        if hasRecurrenceRules {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            if !isAllDay {
                formatter.timeZone = .init(secondsFromGMT: 0)
            }
            if let formattedDate = formatter.string(for: start) {
                date = "/\(formattedDate)"
            } else {
                return nil
            }
        } else {
            date =  ""
        }
        return URL(string: "ical://ekevent\(date)/\(id)?method=show&options=more")
    }
}

struct Participant: Hashable {
    let name: String
    let status: AttendanceStatus
    let isOrganizer: Bool
    let isCurrentUser: Bool
}

enum Priority {
    case high
    case medium
    case low
}
