import SwiftUI

/// Fetches the weather for Home. One shared instance, so leaving Home and coming
/// back does not ask again while what it has is fresh; the reading lives in
/// memory only and is never written anywhere.
///
/// What it asks, and when, is decided by `HomeWeather`: with no city there is no
/// request, and with one there are two — find the city, then get its weather —
/// the first only when the city text has changed since last time.
final class HomeWeatherModel: ObservableObject {
    static let shared = HomeWeatherModel()

    enum State: Equatable {
        /// No city typed: nothing is asked of anyone.
        case off
        case loading(city: String)
        case ready(WeatherReading)
        case failed(city: String, message: String)
    }

    @Published private(set) var state: State = .off

    /// How long a reading is trusted before Home asks again.
    static let maxAge: TimeInterval = 15 * 60

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        // A forecast kept on disk would outlive the reading it is shown in.
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private var knownPlace: (city: String, place: WeatherPlace)?
    /// The question the last good answer was for, and when it came.
    private var answeredKey: String?
    private var answeredAt: Date?
    /// The question being asked right now, if any.
    private var inFlightKey: String?
    private var task: Task<Void, Never>?
    private var generation = 0

    /// Brings what is shown in line with the settings: asks again when the city
    /// or units differ from the last answer, or it has gone stale (or `force`).
    /// Call it on the main thread, like anything that changes what a view shows.
    func update(city rawCity: String, units: WeatherUnits, force: Bool = false) {
        guard let city = HomeWeather.cleanCity(rawCity) else {
            task?.cancel()
            task = nil
            generation += 1
            knownPlace = nil
            answeredKey = nil
            answeredAt = nil
            inFlightKey = nil
            state = .off
            return
        }
        let key = "\(city)|\(units.rawValue)"
        if !force {
            if inFlightKey == key { return }
            if answeredKey == key, let answeredAt, Date().timeIntervalSince(answeredAt) < Self.maxAge,
               case .ready = state { return }
        }

        task?.cancel()
        generation += 1
        let mine = generation
        inFlightKey = key
        // The old reading stays on screen while a new one for the same city comes
        // in; for another city it would be the wrong place's weather.
        var keepShown = false
        if case .ready = state, knownPlace?.city == city { keepShown = true }
        if !keepShown { state = .loading(city: city) }
        let known = knownPlace
        task = Task { @MainActor [weak self] in
            let outcome = await Self.fetch(city: city, units: units, known: known)
            guard let self, !Task.isCancelled, mine == self.generation else { return }
            self.inFlightKey = nil
            switch outcome {
            case .success(let reading):
                self.knownPlace = (city, reading.place)
                self.answeredKey = key
                self.answeredAt = Date()
                self.state = .ready(reading)
            case .failure(let problem):
                self.answeredKey = nil
                self.answeredAt = nil
                self.state = .failed(city: city, message: Self.message(for: problem))
            }
        }
    }

    private static func message(for problem: HomeWeather.Problem) -> String {
        switch problem {
        case .notFound(let city): return "No place found for “\(city)”."
        case .unreadable: return "The weather service sent something unreadable."
        case .unavailable: return "Couldn't reach the weather service."
        }
    }

    private static func fetch(
        city: String,
        units: WeatherUnits,
        known: (city: String, place: WeatherPlace)?
    ) async -> Result<WeatherReading, HomeWeather.Problem> {
        let place: WeatherPlace
        if let known, known.city == city {
            place = known.place
        } else {
            guard let url = HomeWeather.geocodeURL(city: city) else { return .failure(.notFound(city)) }
            switch await get(url) {
            case .failure(let problem): return .failure(problem)
            case .success(let data):
                switch HomeWeather.parsePlace(data, city: city) {
                case .failure(let problem): return .failure(problem)
                case .success(let found): place = found
                }
            }
        }
        guard let url = HomeWeather.forecastURL(latitude: place.latitude, longitude: place.longitude, units: units) else {
            return .failure(.unreadable)
        }
        switch await get(url) {
        case .failure(let problem): return .failure(problem)
        case .success(let data): return HomeWeather.parseReading(data, place: place, units: units)
        }
    }

    private static func get(_ url: URL) async -> Result<Data, HomeWeather.Problem> {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return .failure(.unavailable) }
            return .success(data)
        } catch {
            return .failure(.unavailable)
        }
    }
}

/// Home's weather: the city, its temperature and sky, a small picture, and the
/// few details a glance wants. With no city it is a one-line form instead — the
/// feature asks nothing of any service until a city is typed.
struct HomeWeatherCard: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var model = HomeWeatherModel.shared
    let theme: Theme

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    /// The two stops of the weather CLI's default title gradient.
    private static let gradient = LinearGradient(
        colors: [Color(hex: 0x5D63FF), Color(hex: 0xF7A4F4)], startPoint: .leading, endPoint: .trailing)

    private var units: WeatherUnits { WeatherUnits(rawValue: settings.homeWeatherUnits) ?? .metric }

    var body: some View {
        Group {
            if editing || model.state == .off {
                form
            } else {
                switch model.state {
                case .ready(let reading): readout(reading)
                case .loading(let city): loading(city)
                case .failed(let city, let message): failed(city, message)
                case .off: form
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.surfaceBorder))
        // Ask again when the city or units change, when Home appears, and every
        // so often while it stays up. The model skips the request when what it
        // has is fresh; cancelling the loop on disappear is `.task`'s own.
        .task(id: "\(settings.homeWeatherCity)|\(settings.homeWeatherUnits)") {
            while !Task.isCancelled {
                model.update(city: settings.homeWeatherCity, units: units)
                // A few seconds past `maxAge`: the loop's clock starts before the
                // answer arrives, and waking a moment early would find it fresh.
                try? await Task.sleep(nanoseconds: UInt64((HomeWeatherModel.maxAge + 5) * 1_000_000_000))
            }
        }
    }

    // MARK: Readout

    private func readout(_ reading: WeatherReading) -> some View {
        let condition = reading.condition
        let details = HomeWeather.details(reading)
        return HStack(alignment: .center, spacing: 18) {
            Text(HomeWeather.art(condition.kind, isDay: reading.isDay).joined(separator: "\n"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(tint(condition.kind, isDay: reading.isDay))
                .lineSpacing(0)
                .fixedSize()
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(reading.place.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Self.gradient)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(HomeWeather.degrees(reading.temperature))
                        .font(.system(size: 34, weight: .light, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                    Text(condition.text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                TimelineView(.everyMinute) { context in
                    Text("Local time \(HomeWeather.localTime(at: context.date, utcOffsetSeconds: reading.utcOffsetSeconds))")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Weather in \(reading.place.title): \(HomeWeather.degrees(reading.temperature)), \(condition.text)"
                                + (details.isEmpty ? "" : ". " + details.joined(separator: ", ")))

            Spacer(minLength: 8)

            VStack(spacing: 2) {
                LandingIconButton(icon: "arrow.clockwise", theme: theme, help: "Refresh the weather") {
                    model.update(city: settings.homeWeatherCity, units: units, force: true)
                }
                LandingIconButton(icon: "pencil", theme: theme, help: "Change the city or units") {
                    beginEditing()
                }
            }
        }
    }

    private func loading(_ city: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Getting the weather for \(city)…")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: 8)
            LandingIconButton(icon: "pencil", theme: theme, help: "Change the city or units") { beginEditing() }
        }
    }

    private func failed(_ city: String, _ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "cloud.slash")
                .foregroundStyle(theme.textSecondary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            LandingIconButton(icon: "arrow.clockwise", theme: theme, help: "Try again") {
                model.update(city: settings.homeWeatherCity, units: units, force: true)
            }
            LandingIconButton(icon: "pencil", theme: theme, help: "Change the city or units") { beginEditing() }
        }
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "cloud.sun")
                    .foregroundStyle(settings.accentColor)
                Text(settings.homeWeatherCity.isEmpty ? "Add a city to see its weather here" : "Weather")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
            }
            HStack(spacing: 8) {
                TextField("City — Seattle, or Portland, Oregon", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(save)
                Picker("Units", selection: Binding(
                    get: { units },
                    set: { settings.homeWeatherUnits = $0.rawValue }
                )) {
                    Text("°C").tag(WeatherUnits.metric)
                    Text("°F").tag(WeatherUnits.imperial)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button("Show", action: save)
                    .disabled(HomeWeather.cleanCity(draft) == nil)
                    .keyboardShortcut(.defaultAction)
                if editing {
                    Button("Cancel") { editing = false }
                }
            }
            Text("Asks open-meteo.com for that city's weather — no account or key. Until you add a city, nothing is asked.")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
            if editing, !settings.homeWeatherCity.isEmpty {
                Button("Remove weather from Home") {
                    settings.homeWeatherCity = ""
                    draft = ""
                    editing = false
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
        .onAppear { if draft.isEmpty { draft = settings.homeWeatherCity } }
    }

    private func beginEditing() {
        draft = settings.homeWeatherCity
        editing = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func save() {
        guard let city = HomeWeather.cleanCity(draft) else { return }
        settings.homeWeatherCity = city
        editing = false
    }

    private func tint(_ kind: WeatherKind, isDay: Bool) -> Color {
        switch kind {
        case .clear: return isDay ? Color(hex: 0xFACC15) : Color(hex: 0x93C5FD)
        case .partlyCloudy: return Color(hex: 0xFBBF24)
        case .cloudy, .fog: return theme.textSecondary
        case .drizzle, .rain: return Color(hex: 0x60A5FA)
        case .snow: return Color(hex: 0xBAE6FD)
        case .thunderstorm: return Color(hex: 0xFDE047)
        }
    }
}
