/// Names for new sets: a mood and a scene joined in camel case, like `MagicalSunset` or
/// `SummerVibes`, picked at random from every combination of the two lists.
public enum SetName {
    static let moods = [
        "Magical", "Summer", "Golden", "Midnight", "Electric", "Velvet", "Cosmic", "Endless", "Hidden", "Neon",
        "Silent", "Wild", "Sacred", "Lunar", "Solar", "Crystal", "Deep", "Hypnotic", "Liquid", "Mystic",
        "Burning", "Frozen", "Secret", "Infinite", "Analog", "Digital", "Tropical", "Urban", "Ancient", "Astral",
        "Blue", "Crimson", "Dreamy", "Eternal", "Faded", "Gentle", "Hazy", "Indigo", "Jade", "Kinetic",
        "Lazy", "Lost", "Mellow", "Nocturnal", "Oceanic", "Pastel", "Purple", "Quiet", "Radiant", "Rising",
        "Rusty", "Silver", "Smooth", "Stellar", "Sunny", "Twilight", "Ultra", "Vivid", "Warm", "Wandering",
        "Amber", "Balearic", "Coastal", "Dusty", "Emerald", "Feral", "Floating", "Glowing", "Heavy", "Late",
        "Lucid", "Molten", "Naked", "Opal", "Primal", "Restless", "Saffron", "Shiny", "Spinning", "Starry",
        "Sweet", "Tidal", "Wicked", "Winter", "Spring", "Autumn", "Desert", "Hollow", "Higher", "Inner",
        "Open", "Pure", "Rainy", "Salty", "Sonic", "Stormy", "Strange", "Tender", "Euphoric", "Breezy",
    ]

    static let scenes = [
        "Sunset", "Vibes", "Sunrise", "Dreams", "Waves", "Groove", "Horizon", "Nights", "Shores", "Lights",
        "Echoes", "Rhythm", "Pulse", "Garden", "Paradise", "Motion", "Journey", "Skyline", "Ritual", "Tides",
        "Fever", "Rain", "Bloom", "Mirage", "Orbit", "Galaxy", "Lagoon", "Harbor", "Highway", "Desire",
        "Escape", "Breeze", "Heat", "Fire", "Shadows", "Spirit", "Temple", "Jungle", "Island", "Canyon",
        "Valley", "Forest", "River", "Coast", "Dunes", "Moon", "Stars", "Sky", "Clouds", "Storm",
        "Thunder", "Season", "Feeling", "Moments", "Memories", "Stories", "Signals", "Frequencies", "Circuits", "Machines",
        "Voyage", "Odyssey", "Drift", "Haze", "Glow", "Flame", "Embers", "Afterglow", "Daydream", "Sundown",
        "Daybreak", "Dawn", "Dusk", "Hours", "Weekend", "Holiday", "Sessions", "Fusion", "Theory", "Magic",
        "Mood", "Soul", "Love", "Bliss", "Heaven", "Kingdom", "Station", "Boulevard", "Disco", "Lounge",
        "Terrace", "Rooftop", "Beach", "Cove", "Reef", "Oasis", "Sanctuary", "Utopia", "Spectrum", "Prism",
    ]

    /// A random mood followed by a random scene.
    public static func random() -> String {
        moods.randomElement()! + scenes.randomElement()!
    }
}
