import SwiftUI

struct PulsePerson: Identifiable {
    let id = UUID()
    let name: String
    let age: Int
    let direction: String
    let distance: Int
    let symbol: String
    let color: Color
    let interests: [String]
    let radarX: CGFloat
    let radarY: CGFloat
}

// MARK: - Demo Data

let demoPeople: [PulsePerson] = [
    PulsePerson(
        name: "Mina",
        age: 22,
        direction: "Northwest",
        distance: 120,
        symbol: "music.note",
        color: .pink,
        interests: ["Music", "Film", "Late-night food"],
        radarX: 0.24,
        radarY: 0.28
    ),

    PulsePerson(
        name: "Alex",
        age: 21,
        direction: "East",
        distance: 230,
        symbol: "gamecontroller.fill",
        color: .purple,
        interests: ["Games", "Design", "Coffee"],
        radarX: 0.78,
        radarY: 0.48
    ),

    PulsePerson(
        name: "Jamie",
        age: 23,
        direction: "Southwest",
        distance: 380,
        symbol: "camera.fill",
        color: .blue,
        interests: ["Photography", "Concerts", "Hiking"],
        radarX: 0.22,
        radarY: 0.76
    ),

    PulsePerson(
        name: "Noah",
        age: 22,
        direction: "Northeast",
        distance: 460,
        symbol: "sparkles",
        color: .orange,
        interests: ["Startups", "Movies", "Tennis"],
        radarX: 0.73,
        radarY: 0.20
    )
]
