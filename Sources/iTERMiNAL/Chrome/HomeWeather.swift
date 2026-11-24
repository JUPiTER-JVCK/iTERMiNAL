import Foundation

/// The weather on Home, as pure logic: what to ask, how to read the answer, how
/// to put it in words and a little picture. Foundation only, so it is compiled
/// and checked off a Mac like the rest of the app's logic; making the requests
/// is `HomeWeatherModel`.
///
/// The service is Open-Meteo, which needs no key. That is why there is nothing
/// to sign up for and nothing to keep in the Keychain — and why the feature is
/// off until a city is typed: with no city, no request is ever built, so a
/// fresh install says nothing about where its owner is. What is sent is the
/// city text (to find it) and then that city's coordinates (to get its
/// weather); both over https, built with `URLComponents` so the text cannot
/// change the shape of the request.
enum WeatherUnits: String, CaseIterable, Equatable {
    case metric
    case imperial

    var temperatureSymbol: String { self == .metric ? "°C" : "°F" }
    var speedSymbol: String { self == .metric ? "km/h" : "mph" }
}

struct WeatherPlace: Equatable {
    var name: String
    var region: String?
    var country: String?
    var latitude: Double
    var longitude: Double

    /// "Seattle, Washington" — the city and its region, or its country when the
    /// service gave no region. Never empty: a place always has a name.
    var title: String {
        let second = [region, country].compactMap { $0 }.first { !$0.isEmpty }
        return [name, second].compactMap { $0 }.joined(separator: ", ")
    }
}

/// What the sky is doing, coarsely — enough to choose a picture and a colour.
enum WeatherKind: Equatable {
    case clear, partlyCloudy, cloudy, fog, drizzle, rain, snow, thunderstorm
}

struct WeatherCondition: Equatable {
    var kind: WeatherKind
    var text: String
}

struct WeatherReading: Equatable {
    var place: WeatherPlace
    var units: WeatherUnits
    var temperature: Double
    var feelsLike: Double?
    var humidity: Int?
    var windSpeed: Double?
    var code: Int
    var isDay: Bool
    /// The place's offset from UTC, so its own clock can be shown.
    var utcOffsetSeconds: Int

    var condition: WeatherCondition { HomeWeather.condition(code: code, isDay: isDay) }
}

enum HomeWeather {
    enum Problem: Error, Equatable {
        /// No place by that name (or none in the region that was named).
        case notFound(String)
        /// The service answered with something this cannot read.
        case unreadable
        /// The service said no, or could not be reached.
        case unavailable
    }

    static let geocodingHost = "geocoding-api.open-meteo.com"
    static let forecastHost = "api.open-meteo.com"
    static let maxResponseBytes = 64 * 1024
    static let maxCityLength = 80
    /// How many matches to ask for, so "Portland, Oregon" can be told from the
    /// bigger Portland the service lists first.
    static let candidateCount = 10

    // MARK: What the person typed

    /// The city text, tidied — or nil when there is nothing to ask about.
    /// Whitespace is collapsed, control characters rejected, and the length
    /// capped, so what leaves the Mac is a short plain name.
    static func cleanCity(_ raw: String) -> String? {
        if raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != " " && $0 != "\t" }) {
            return nil
        }
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty, collapsed.count <= maxCityLength else { return nil }
        return collapsed
    }

    /// "Seattle, WA" → ("Seattle", "WA"). The service looks places up by name
    /// alone, so anything after the first comma narrows the answers instead of
    /// being sent.
    static func split(city: String) -> (name: String, qualifier: String?) {
        let parts = city.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts[0].trimmingCharacters(in: .whitespaces)
        guard parts.count == 2 else { return (name, nil) }
        let rest = parts[1].trimmingCharacters(in: .whitespaces)
        return (name, rest.isEmpty ? nil : rest)
    }

    // MARK: What to ask

    static func geocodeURL(city: String) -> URL? {
        guard let clean = cleanCity(city) else { return nil }
        let name = split(city: clean).name
        guard !name.isEmpty else { return nil }
        // Encoded by hand, down to unreserved ASCII: how `URLComponents` treats
        // `&`, `=` and `+` inside a query value differs between platforms, and
        // here the text is a stranger's, so it must not be able to add to the
        // query whichever way that goes.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = geocodingHost
        components.path = "/v1/search"
        components.percentEncodedQuery = "name=\(encoded)&count=\(candidateCount)&language=en&format=json"
        return components.url
    }

    static func forecastURL(latitude: Double, longitude: Double, units: WeatherUnits) -> URL? {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = forecastHost
        components.path = "/v1/forecast"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day"),
            URLQueryItem(name: "temperature_unit", value: units == .metric ? "celsius" : "fahrenheit"),
            URLQueryItem(name: "wind_speed_unit", value: units == .metric ? "kmh" : "mph"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        return components.url
    }

    // MARK: Reading the answers

    /// The place the person meant, out of the service's candidates. With a
    /// qualifier ("Oregon", "FR"), the first candidate whose region, country or
    /// country code is that; with none, the service's first, which it ranks by
    /// size. A qualifier nothing matches is an error, not the first candidate:
    /// Home would otherwise show the wrong city's weather as the one asked for.
    static func parsePlace(_ data: Data, city: String) -> Result<WeatherPlace, Problem> {
        guard data.count <= maxResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return .failure(.unreadable) }
        if root["error"] as? Bool == true { return .failure(.unavailable) }
        let shown = cleanCity(city) ?? city
        // No `results` key at all is how the service says "nothing by that name".
        guard let results = root["results"] as? [[String: Any]], !results.isEmpty else {
            return .failure(.notFound(shown))
        }

        let qualifier = cleanCity(city).flatMap { split(city: $0).qualifier }?.lowercased()
        for result in results {
            guard let name = text(result["name"]),
                  let latitude = number(result["latitude"]), let longitude = number(result["longitude"]),
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else { continue }
            let region = text(result["admin1"])
            let country = text(result["country"])
            if let qualifier {
                let wanted = [region, country, text(result["country_code"])]
                    .compactMap { $0?.lowercased() }
                guard wanted.contains(qualifier) else { continue }
            }
            return .success(WeatherPlace(name: name, region: region, country: country,
                                         latitude: latitude, longitude: longitude))
        }
        return .failure(.notFound(shown))
    }

    static func parseReading(_ data: Data, place: WeatherPlace, units: WeatherUnits) -> Result<WeatherReading, Problem> {
        guard data.count <= maxResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return .failure(.unreadable) }
        if root["error"] as? Bool == true { return .failure(.unavailable) }
        guard let current = root["current"] as? [String: Any],
              let temperature = number(current["temperature_2m"]),
              let code = number(current["weather_code"]).flatMap({ whole($0) }) else { return .failure(.unreadable) }
        return .success(WeatherReading(
            place: place,
            units: units,
            temperature: temperature,
            feelsLike: number(current["apparent_temperature"]),
            humidity: number(current["relative_humidity_2m"]).flatMap { whole($0) },
            windSpeed: number(current["wind_speed_10m"]),
            code: code,
            // A reading without the flag is shown as day rather than guessed at night.
            isDay: (number(current["is_day"]) ?? 1) != 0,
            utcOffsetSeconds: number(root["utc_offset_seconds"]).flatMap { whole($0) } ?? 0
        ))
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A number as a whole one — nil for what could not be a reading at all, so
    /// converting never traps on a wild value from the wire.
    private static func whole(_ value: Double) -> Int? {
        guard value.isFinite, abs(value) < 1_000_000 else { return nil }
        return Int(value.rounded())
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double, double.isFinite { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }

    // MARK: In words

    /// WMO weather interpretation codes, as Open-Meteo reports them. A code it
    /// does not list reads as plain "Unknown", never as a guess.
    static func condition(code: Int, isDay: Bool) -> WeatherCondition {
        switch code {
        case 0: return WeatherCondition(kind: .clear, text: isDay ? "Clear sky" : "Clear night")
        case 1: return WeatherCondition(kind: .clear, text: isDay ? "Mostly sunny" : "Mostly clear")
        case 2: return WeatherCondition(kind: .partlyCloudy, text: "Partly cloudy")
        case 3: return WeatherCondition(kind: .cloudy, text: "Overcast")
        case 45, 48: return WeatherCondition(kind: .fog, text: "Fog")
        case 51, 53, 55: return WeatherCondition(kind: .drizzle, text: "Drizzle")
        case 56, 57: return WeatherCondition(kind: .drizzle, text: "Freezing drizzle")
        case 61: return WeatherCondition(kind: .rain, text: "Light rain")
        case 63: return WeatherCondition(kind: .rain, text: "Rain")
        case 65: return WeatherCondition(kind: .rain, text: "Heavy rain")
        case 66, 67: return WeatherCondition(kind: .rain, text: "Freezing rain")
        case 71: return WeatherCondition(kind: .snow, text: "Light snow")
        case 73: return WeatherCondition(kind: .snow, text: "Snow")
        case 75: return WeatherCondition(kind: .snow, text: "Heavy snow")
        case 77: return WeatherCondition(kind: .snow, text: "Snow grains")
        case 80: return WeatherCondition(kind: .rain, text: "Light showers")
        case 81: return WeatherCondition(kind: .rain, text: "Showers")
        case 82: return WeatherCondition(kind: .rain, text: "Heavy showers")
        case 85, 86: return WeatherCondition(kind: .snow, text: "Snow showers")
        case 95: return WeatherCondition(kind: .thunderstorm, text: "Thunderstorm")
        case 96, 99: return WeatherCondition(kind: .thunderstorm, text: "Thunderstorm with hail")
        default: return WeatherCondition(kind: .cloudy, text: "Unknown")
        }
    }

    /// "12°" — whole degrees, with no "-0°" for a reading that rounds to zero.
    static func degrees(_ value: Double) -> String {
        guard let rounded = whole(value) else { return "—" }
        return "\(rounded == 0 ? 0 : rounded)°"
    }

    /// "Feels like 9° · 82% humidity · 14 km/h wind", whatever of it there is.
    static func details(_ reading: WeatherReading) -> [String] {
        var parts: [String] = []
        if let feels = reading.feelsLike { parts.append("Feels like \(degrees(feels))") }
        if let humidity = reading.humidity { parts.append("\(humidity)% humidity") }
        if let wind = reading.windSpeed, let speed = whole(wind) {
            parts.append("\(speed) \(reading.units.speedSymbol) wind")
        }
        return parts
    }

    /// The place's own clock, "14:30" or "2:30 PM" by the reader's locale.
    static func localTime(at date: Date, utcOffsetSeconds: Int, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(secondsFromGMT: utcOffsetSeconds) ?? .current
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: In a picture

    /// A small picture in text, five lines of the same width so they line up in
    /// a monospaced font. Drawn for this app; the weather CLI starlit, which this
    /// Home is modelled on, shows the same idea.
    static let artWidth = 13

    static func art(_ kind: WeatherKind, isDay: Bool) -> [String] {
        let lines: [String]
        switch kind {
        case .clear where isDay:
            lines = ["    \\ | /    ",
                     "   .-----.   ",
                     " --|     |-- ",
                     "   `-----'   ",
                     "    / | \\    "]
        case .clear:
            lines = ["   _..._     ",
                     " .'     `.   ",
                     " :   *   :   ",
                     " `.     .'   ",
                     "   `---'   . "]
        case .partlyCloudy:
            lines = ["  \\  /       ",
                     "_ /\"\".-.     ",
                     "  \\_(   ).   ",
                     "  /(___(__)  ",
                     "             "]
        case .cloudy:
            lines = ["             ",
                     "    .--.     ",
                     " .-(    ).   ",
                     "(___.__)__)  ",
                     "             "]
        case .fog:
            lines = ["             ",
                     " _ - _ - _ - ",
                     "  _ - _ - _  ",
                     " _ - _ - _ - ",
                     "             "]
        case .drizzle:
            lines = ["    .-.      ",
                     "   (   ).    ",
                     "  (___(__)   ",
                     "   ' ' ' '   ",
                     "  ' ' ' '    "]
        case .rain:
            lines = ["    .-.      ",
                     "   (   ).    ",
                     "  (___(__)   ",
                     "  ,',',','   ",
                     "  ,',',','   "]
        case .snow:
            lines = ["    .-.      ",
                     "   (   ).    ",
                     "  (___(__)   ",
                     "   * * * *   ",
                     "  * * * *    "]
        case .thunderstorm:
            lines = ["    .-.      ",
                     "   (   ).    ",
                     "  (___(__)   ",
                     "   /_  /_    ",
                     "    /   /    "]
        }
        return lines
    }
}
