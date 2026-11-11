import Foundation

/// Fictional people and places for demo mode. Deterministic: fixed IDs, fixed scripts.
/// Every person here is invented. Nothing in this file is ever sent to the live backend.
enum DemoWorld {
    static let village = UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!
    static let leavey = UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!
    static let tutor = UUID(uuidString: "00000000-0000-0000-0000-00000000A003")!
    static let hackathon = UUID(uuidString: "00000000-0000-0000-0000-00000000A004")!
    static let mixer = UUID(uuidString: "00000000-0000-0000-0000-00000000A005")!

    static let demoCode = "123456"

    static func spaces(now: Date) -> [CampusSpace] {
        [
            CampusSpace(id: village, name: "USC Village", kind: .place, subtitle: "Courtyard, dining & shops"),
            CampusSpace(id: leavey, name: "Leavey Library", kind: .place, subtitle: "Open 24 hours"),
            CampusSpace(id: tutor, name: "Tutor Campus Center", kind: .place, subtitle: "Food court & lounges"),
            CampusSpace(id: hackathon, name: "Trojan Hacks", kind: .event, subtitle: "Hackathon · Ronald Tutor Hall",
                        startsAt: now.addingTimeInterval(-3600), endsAt: now.addingTimeInterval(45 * 60)),
            CampusSpace(id: mixer, name: "Iovine & Young Fall Mixer", kind: .event, subtitle: "Mixer · code IYA2026",
                        startsAt: now.addingTimeInterval(-1800), endsAt: now.addingTimeInterval(3 * 3600))
        ]
    }

    /// Event codes resolved by `enterSpaceCode`.
    static let eventCodes: [String: UUID] = ["IYA2026": mixer, "HACKSC": hackathon]

    /// How a fictional person behaves in the scenario.
    struct Script {
        var spaceID: UUID?
        /// Session length from demo start. nil = no session.
        var sessionMinutes: Double? = 90
        var paused = false
        var shielded = false
        var verifiedOnly = false
        /// Sent you a Heart Signal this many seconds after demo start.
        var signalsYouAfter: TimeInterval?
        /// Signals you back this many seconds after you signal them.
        var replyAfter: TimeInterval?
        /// Accepts your connection actions / meeting requests after this delay. nil = never answers.
        var acceptsAfter: TimeInterval? = 4
        var instagram: String?
        var note: String
    }

    struct Person {
        var profile: PublicProfile
        var script: Script
    }

    static func person(
        _ n: Int, _ name: String, _ age: Int, pronouns: String, gender: String, interests: [String], vibes: [String],
        prompt: Int, answer: String, intention: Intention, availability: Availability, avatar: String,
        review: ReviewStatus = .approved, band: String, script: Script
    ) -> Person {
        Person(
            profile: PublicProfile(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 100 + n))!,
                firstName: name, age: age, pronouns: pronouns, gender: gender, interests: interests,
                vibeTags: vibes, promptQuestion: ProfilePrompts.all[prompt], promptAnswer: answer,
                intention: intention, availability: availability, photoPaths: ["avatar:\(avatar)"],
                photoReviewStatus: review, spaceName: nil, simulatedDistanceBand: band
            ),
            script: script
        )
    }

    static func people() -> [Person] {
        [
            person(1, "Mina", 22, pronouns: "she/her", gender: "Woman", interests: ["Music", "Film", "Late-night food"],
                   vibes: ["Night owl", "Deep talks"], prompt: 0, answer: "A walk to Trader Joe's and a terrible pun.",
                   intention: .somethingSerious, availability: .meetNow, avatar: "music.note|pink", band: "< 100 m",
                   script: Script(spaceID: village, signalsYouAfter: 0, instagram: "@mina.makes.playlists",
                                  note: "Already sent you a signal. Signal her for an instant Heart Sync.")),
            person(2, "Alex", 21, pronouns: "he/him", gender: "Man", interests: ["Games", "Design", "Coffee"],
                   vibes: ["Quietly funny", "Planner"], prompt: 1, answer: "The third floor of Leavey, pretending to study.",
                   intention: .somethingCasual, availability: .either, avatar: "gamecontroller.fill|purple", band: "100–250 m",
                   script: Script(spaceID: village, replyAfter: 20, instagram: "@alex.pixels",
                                  note: "Signals you back about 20 seconds after you signal him.")),
            person(3, "Jamie", 23, pronouns: "they/them", gender: "Non-binary", interests: ["Photography", "Concerts", "Hiking"],
                   vibes: ["Spontaneous", "Golden retriever energy"], prompt: 2, answer: "Golden hour on the Doheny steps.",
                   intention: .figuringItOut, availability: .connectLater, avatar: "camera.fill|blue", band: "250–500 m",
                   script: Script(spaceID: village, sessionMinutes: 3, signalsYouAfter: 30, instagram: "@jamie.frames",
                                  note: "Signals you, then leaves after 3 minutes. Signal them later for Crossed Hearts.")),
            person(4, "Noah", 22, pronouns: "he/him", gender: "Man", interests: ["Startups", "Movies", "Tennis"],
                   vibes: ["Main character", "Early riser"], prompt: 3, answer: "Someone who texts back the same day.",
                   intention: .newFriends, availability: .meetNow, avatar: "sparkles|orange", band: "100–250 m",
                   script: Script(spaceID: village, acceptsAfter: nil,
                                  note: "Never signals back. Your signal to him stays anonymous and pending.")),
            person(5, "Priya", 20, pronouns: "she/her", gender: "Woman", interests: ["Dance", "Cooking", "Poetry"],
                   vibes: ["Social butterfly", "Chaotic good"], prompt: 4, answer: "Pineapple belongs on pizza. Fight me.",
                   intention: .somethingCasual, availability: .either, avatar: "music.mic|mint", band: "< 100 m",
                   script: Script(spaceID: village, note: "Ordinary profile.")),
            person(6, "Marcus", 24, pronouns: "he/him", gender: "Man", interests: ["Basketball", "Podcasts", "Cooking"],
                   vibes: ["Golden retriever energy"], prompt: 5, answer: "Whether cereal is soup.",
                   intention: .somethingSerious, availability: .connectLater, avatar: "basketball.fill|amber", band: "250–500 m",
                   script: Script(spaceID: village, note: "Ordinary profile.")),
            person(7, "Elena", 21, pronouns: "she/her", gender: "Woman", interests: ["Art museums", "Thrifting", "Coffee"],
                   vibes: ["Bookish", "Soft-spoken"], prompt: 1, answer: "The Fisher Museum, every Thursday.",
                   intention: .figuringItOut, availability: .meetNow, avatar: "paintpalette.fill|plum", review: .pending,
                   band: "100–250 m", script: Script(spaceID: village, note: "Photo still in review — shown without a badge.")),
            person(8, "Sam", 22, pronouns: "he/they", gender: "Non-binary", interests: ["Climbing", "Anime", "Running"],
                   vibes: ["Night owl"], prompt: 2, answer: "Boba and a bouldering session.",
                   intention: .newFriends, availability: .either, avatar: "figure.climbing|teal", band: "< 100 m",
                   script: Script(spaceID: village, verifiedOnly: true,
                                  note: "Verified-only: hidden from you until your photo is approved.")),
            person(9, "Taylor", 22, pronouns: "she/her", gender: "Woman", interests: ["Surfing", "Film", "Volunteering"],
                   vibes: ["Early riser"], prompt: 0, answer: "Sunrise at Venice.", intention: .somethingSerious,
                   availability: .either, avatar: "water.waves|blue", band: "100–250 m",
                   script: Script(spaceID: village, paused: true, note: "Paused — never shown.")),
            person(10, "Jordan", 23, pronouns: "he/him", gender: "Man", interests: ["Theater", "Music", "Coffee"],
                   vibes: ["Main character"], prompt: 3, answer: "Kindness to waiters.", intention: .somethingCasual,
                   availability: .meetNow, avatar: "theatermasks.fill|pink", band: "< 100 m",
                   script: Script(spaceID: village, shielded: true, note: "In Protect My Heart — never shown.")),
            person(11, "Rio", 21, pronouns: "she/they", gender: "Woman", interests: ["Podcasts", "Running", "Startups"],
                   vibes: ["Planner", "Deep talks"], prompt: 4, answer: "Cold pizza is better than hot pizza.",
                   intention: .newFriends, availability: .connectLater, avatar: "headphones|purple", band: "100–250 m",
                   script: Script(spaceID: leavey, note: "At Leavey Library — switch spaces to see her.")),
            person(12, "Devon", 22, pronouns: "he/him", gender: "Man", interests: ["Hiking", "Design", "Games"],
                   vibes: ["Chaotic good"], prompt: 5, answer: "Tabs vs. spaces.", intention: .somethingCasual,
                   availability: .either, avatar: "laptopcomputer|mint", band: "< 100 m",
                   script: Script(spaceID: hackathon, note: "At Trojan Hacks."))
        ]
    }
}
