import Foundation

/// Fictional people for the demo fixture. Deterministic: fixed IDs, fixed scripts. Every person here is invented.
/// Nothing in this file is ever sent to the live backend.
///
/// Spaces are the real draft zones bundled in `campus_spaces.json`, referenced by slug. The demo can only reach them
/// through the simulated location provider, which exists only in demo builds of AppState (see AppState.make).
enum DemoWorld {
    static let mcCarthyQuad = "upc-mccarthy-quad"
    static let greatLawn = "usc-village-great-lawn"
    static let alumniPark = "upc-alumni-park-tommy-trojan"

    static let demoCode = "123456"

    /// How a fictional person behaves in the scenario.
    struct Script {
        /// The space they're participating in, if any.
        var space: String?
        var paused = false
        var verifiedOnly = false
        var matchGender: MatchGender
        var showMe: Set<MatchGender> = Set(MatchGender.allCases)
        var ageRange: ClosedRange<Int> = 18...120
        /// Expresses interest in you this many seconds after your session opens (they "discover" you first).
        var interestedAfter: TimeInterval?
        /// Expresses interest back this many seconds after you express interest in them.
        var replyAfter: TimeInterval?
        /// Leaves the space (their session ends) this many seconds after your first session opens.
        var leavesAfter: TimeInterval?
        /// Replies to your messages with these lines, in order, after `Options.replyDelay`.
        var replies: [String] = []
        var note: String
    }

    struct Person {
        var profile: PublicProfile
        var script: Script
    }

    static func person(
        _ n: Int, _ name: String, _ age: Int, pronouns: String, gender: String, interests: [String], vibes: [String],
        prompt: Int, answer: String, intention: Intention, availability: Availability, avatar: String,
        review: ReviewStatus = .approved, script: Script
    ) -> Person {
        Person(
            profile: PublicProfile(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 100 + n))!,
                firstName: name, age: age, pronouns: pronouns, gender: gender, interests: interests,
                vibeTags: vibes, promptQuestion: ProfilePrompts.all[prompt], promptAnswer: answer,
                intention: intention, availability: availability, photoPaths: ["avatar:\(avatar)"],
                photoReviewStatus: review
            ),
            script: script
        )
    }

    static func people() -> [Person] {
        [
            person(1, "Mina", 22, pronouns: "she/her", gender: "Woman", interests: ["Music", "Film", "Late-night food"],
                   vibes: ["Night owl", "Deep talks"], prompt: 0, answer: "A walk to Trader Joe's and a terrible pun.",
                   intention: .somethingSerious, availability: .meetNow, avatar: "music.note|pink",
                   script: Script(space: mcCarthyQuad, matchGender: .woman, interestedAfter: 0,
                                  replies: ["Hi! Okay, this is fun.", "Leavey or Doheny for studying?"],
                                  note: "Expresses interest soon after you open to matching. Show interest back for a match.")),
            person(2, "Alex", 21, pronouns: "he/him", gender: "Man", interests: ["Games", "Design", "Coffee"],
                   vibes: ["Quietly funny", "Planner"], prompt: 1, answer: "The third floor of Leavey, pretending to study.",
                   intention: .somethingCasual, availability: .either, avatar: "gamecontroller.fill|purple",
                   script: Script(space: mcCarthyQuad, matchGender: .man, replyAfter: 20,
                                  replies: ["Hey :) what are you up to this week?"],
                                  note: "Shows interest back about 20 s after you show interest in him.")),
            person(3, "Jamie", 23, pronouns: "they/them", gender: "Non-binary", interests: ["Photography", "Concerts", "Hiking"],
                   vibes: ["Spontaneous", "Golden retriever energy"], prompt: 2, answer: "Golden hour on the Doheny steps.",
                   intention: .figuringItOut, availability: .connectLater, avatar: "camera.fill|blue",
                   script: Script(space: mcCarthyQuad, matchGender: .nonbinary, interestedAfter: 10, leavesAfter: 180,
                                  note: "Interested in you, then leaves after 3 min. Leaving deletes their interest; no match later.")),
            person(4, "Noah", 22, pronouns: "he/him", gender: "Man", interests: ["Startups", "Movies", "Tennis"],
                   vibes: ["Main character", "Early riser"], prompt: 3, answer: "Someone who texts back the same day.",
                   intention: .newFriends, availability: .meetNow, avatar: "sparkles|orange",
                   script: Script(space: mcCarthyQuad, matchGender: .man,
                                  note: "Never shows interest back. Your interest stays private.")),
            person(5, "Priya", 20, pronouns: "she/her", gender: "Woman", interests: ["Dance", "Cooking", "Poetry"],
                   vibes: ["Social butterfly", "Chaotic good"], prompt: 4, answer: "Pineapple belongs on pizza. Fight me.",
                   intention: .somethingCasual, availability: .either, avatar: "music.mic|mint",
                   script: Script(space: mcCarthyQuad, matchGender: .woman, note: "Ordinary profile.")),
            person(6, "Marcus", 24, pronouns: "he/him", gender: "Man", interests: ["Basketball", "Podcasts", "Cooking"],
                   vibes: ["Golden retriever energy"], prompt: 5, answer: "Whether cereal is soup.",
                   intention: .somethingSerious, availability: .connectLater, avatar: "basketball.fill|amber",
                   script: Script(space: mcCarthyQuad, matchGender: .man, note: "Ordinary profile.")),
            person(7, "Elena", 21, pronouns: "she/her", gender: "Woman", interests: ["Art museums", "Thrifting", "Coffee"],
                   vibes: ["Bookish", "Soft-spoken"], prompt: 1, answer: "The Fisher Museum, every Thursday.",
                   intention: .figuringItOut, availability: .meetNow, avatar: "paintpalette.fill|plum", review: .pending,
                   script: Script(space: mcCarthyQuad, matchGender: .woman, note: "Photo still in review — shown without a badge.")),
            person(8, "Sam", 22, pronouns: "he/they", gender: "Non-binary", interests: ["Climbing", "Anime", "Running"],
                   vibes: ["Night owl"], prompt: 2, answer: "Boba and a bouldering session.",
                   intention: .newFriends, availability: .either, avatar: "figure.climbing|teal",
                   script: Script(space: mcCarthyQuad, verifiedOnly: true, matchGender: .nonbinary,
                                  note: "Verified-only: hidden from you until your photo is approved.")),
            person(9, "Taylor", 22, pronouns: "she/her", gender: "Woman", interests: ["Surfing", "Film", "Volunteering"],
                   vibes: ["Early riser"], prompt: 0, answer: "Sunrise at Venice.", intention: .somethingSerious,
                   availability: .either, avatar: "water.waves|blue",
                   script: Script(space: mcCarthyQuad, paused: true, matchGender: .woman,
                                  note: "Campus matching paused — has no session, never shown.")),
            person(10, "Jordan", 23, pronouns: "he/him", gender: "Man", interests: ["Theater", "Music", "Coffee"],
                   vibes: ["Main character"], prompt: 3, answer: "Kindness to waiters.", intention: .somethingCasual,
                   availability: .meetNow, avatar: "theatermasks.fill|pink",
                   script: Script(space: mcCarthyQuad, matchGender: .man, showMe: [.woman],
                                  note: "Only wants to see women. Preferences apply both ways, so you never see each other.")),
            person(11, "Rio", 21, pronouns: "she/they", gender: "Woman", interests: ["Podcasts", "Running", "Startups"],
                   vibes: ["Planner", "Deep talks"], prompt: 4, answer: "Cold pizza is better than hot pizza.",
                   intention: .newFriends, availability: .connectLater, avatar: "headphones|purple",
                   script: Script(space: alumniPark, matchGender: .woman, note: "At Alumni Park & Tommy Trojan.")),
            person(12, "Devon", 22, pronouns: "he/him", gender: "Man", interests: ["Hiking", "Design", "Games"],
                   vibes: ["Chaotic good"], prompt: 5, answer: "Tabs vs. spaces.", intention: .somethingCasual,
                   availability: .either, avatar: "laptopcomputer|mint",
                   script: Script(space: alumniPark, matchGender: .man, note: "At Alumni Park & Tommy Trojan.")),
            person(13, "Kai", 20, pronouns: "they/them", gender: "Non-binary", interests: ["Film", "Coffee", "Thrifting"],
                   vibes: ["Soft-spoken"], prompt: 3, answer: "Remembering how someone takes their coffee.",
                   intention: .figuringItOut, availability: .either, avatar: "film.fill|orange",
                   script: Script(space: alumniPark, matchGender: .nonbinary, note: "At Alumni Park & Tommy Trojan.")),
            person(14, "Lena", 24, pronouns: "she/her", gender: "Woman", interests: ["Tennis", "Poetry", "Cooking"],
                   vibes: ["Planner"], prompt: 5, answer: "Best taco truck near campus.", intention: .somethingSerious,
                   availability: .connectLater, avatar: "book.fill|blue",
                   script: Script(space: alumniPark, matchGender: .woman, ageRange: 22...30,
                                  note: "At Alumni Park. Only sees people 22–30."))
        ]
    }
}
