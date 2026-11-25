import AppKit
import WebKit
import ServiceManagement

// MARK: - Лог (~/Library/Logs/SvitloBar.log)

func debugLog(_ message: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SvitloBar.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Моделі

struct AddressConfig: Codable {
    var cityId: String
    var cityLabel: String
    var streetId: String
    var streetLabel: String
    var houseId: String
    var houseLabel: String

    var shortLabel: String {
        let city = cityLabel.components(separatedBy: " (").first ?? cityLabel
        return "\(city), \(streetLabel), \(houseLabel)"
    }
}

// День ділиться на 48 півгодинних слотів (дзеркало дає точність до 30 хв)
let slotsPerDay = 48
let slotMinutes = 30

struct DaySchedule {
    let date: String   // yyyy-MM-dd
    let label: String  // "Пт 06.11"
    let slots: [Int]   // 48 значень: 0 = світло є, 1–2 = можливо, 3–4 = відключення
}

struct Schedule {
    let queue: String
    let days: [DaySchedule]
    let messages: [String]
    let fetched: Date
    var mirrorUpdated: Date? = nil  // не nil — дані з неофіційного дзеркала
}

struct AppError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Налаштування (UserDefaults)

enum Store {
    static let key = "addressConfig"

    static func load() -> AddressConfig? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AddressConfig.self, from: data)
    }

    // Миготіння напису за 15 хв до зміни стану (за замовчуванням вимкнено)
    static var blinkEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "blinkEnabled") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "blinkEnabled") }
    }

    // Остання черга з офіційного сайту — потрібна для запиту до дзеркала
    static var queue: String? {
        get { UserDefaults.standard.string(forKey: "queue") }
        set { UserDefaults.standard.set(newValue, forKey: "queue") }
    }

    static func save(_ config: AddressConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Клієнт VOE (прихований WKWebView: проходить Cloudflare, API кличеться зі сторінки)

final class VOEClient: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let hostWindow: NSWindow
    private var csrfWaiters: [(Result<Void, Error>) -> Void] = []
    private var pollTimer: Timer?
    private var pollAttempts = 0
    private var loading = false
    private var activity: NSObjectProtocol?

    override init() {
        let conf = WKWebViewConfiguration()
        conf.websiteDataStore = .default() // зберігає cf_clearance між запусками
        // Справжній UA рушія + версія встановленого Safari. Захардкоджена стара версія
        // не збігалась із можливостями WebKit, і Cloudflare не пропускав перевірку автоматично.
        let safariVersion = Bundle(path: "/Applications/Safari.app")?
            .infoDictionary?["CFBundleShortVersionString"] as? String ?? "26.0"
        conf.applicationNameForUserAgent = "Version/\(safariVersion) Safari/605.1.15"
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 560, height: 480), configuration: conf)
        // Cloudflare challenge не виконується у webview поза вікном (нема requestAnimationFrame),
        // тому webview живе у майже прозорому вікні на екрані.
        hostWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        hostWindow.title = "SvitloBar — перевірка Cloudflare"
        hostWindow.isReleasedWhenClosed = false
        // На всіх Spaces і поверх інших вікон: інакше macOS вважає вікно перекритим,
        // пригальмовує webview і автоматична перевірка Cloudflare не встигає пройти
        hostWindow.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces, .stationary]
        super.init()
        webView.navigationDelegate = self
        hostWindow.contentView = webView
        setWindowHidden(true)
    }

    private func setWindowHidden(_ hidden: Bool) {
        if hidden {
            hostWindow.alphaValue = 0.01
            hostWindow.ignoresMouseEvents = true
            hostWindow.setFrameOrigin(NSPoint(x: 8, y: 8))
            hostWindow.level = .floating  // прозоре й «прозоре для кліків», але не перекрите
            hostWindow.orderFrontRegardless()
        } else {
            hostWindow.level = .normal
            hostWindow.alphaValue = 1
            hostWindow.ignoresMouseEvents = false
            hostWindow.center()
            hostWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // Показати вікно з сайтом, щоб вручну пройти перевірку Cloudflare
    func presentChallengeWindow() {
        setWindowHidden(false)
    }

    // Чекає, поки сторінка завантажиться і на ній з'явиться csrf-токен
    // Сторінка вже завантажена й має csrf — перезавантаження не потрібне. Кожне зайве
    // перезавантаження головної сторінки — ще один шанс отримати перевірку Cloudflare.
    func ensureReady(forceReload: Bool = false, completion: @escaping (Result<Void, Error>) -> Void) {
        if !forceReload && !loading {
            webView.evaluateJavaScript("document.querySelector('input[name=csrf]')?.value || ''") { [weak self] result, _ in
                guard let self else { return }
                if let token = result as? String, !token.isEmpty {
                    completion(.success(()))
                } else {
                    self.load(completion)
                }
            }
            return
        }
        load(completion, force: forceReload)
    }

    private func load(_ completion: @escaping (Result<Void, Error>) -> Void, force: Bool = false) {
        csrfWaiters.append(completion)
        if loading && !force { return }
        loading = true
        pollAttempts = 0
        if activity == nil {
            // не даємо App Nap пригальмувати JS перевірки, поки сторінка вантажиться
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Завантаження графіка VOE")
        }
        webView.load(URLRequest(url: URL(string: "https://disconnection.voe.com.ua/")!))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        startCsrfPolling()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishWaiters(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishWaiters(.failure(error))
    }

    private func startCsrfPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollCsrf()
        }
    }

    private func pollCsrf() {
        pollAttempts += 1
        webView.evaluateJavaScript("document.querySelector('input[name=csrf]')?.value || ''") { [weak self] result, _ in
            guard let self else { return }
            if let token = result as? String, !token.isEmpty {
                self.pollTimer?.invalidate()
                self.setWindowHidden(true)
                self.finishWaiters(.success(()))
            } else if self.pollAttempts > 30,
                      !(self.hostWindow.isVisible && self.hostWindow.alphaValue == 1) {
                // у видимому вікні користувач проходить перевірку сам — не обриваємо
                self.pollTimer?.invalidate()
                self.webView.evaluateJavaScript(
                    "document.title + ' | turnstile=' + !!document.querySelector('iframe[src*=challenges], [class*=turnstile], #challenge-stage') + ' | ' + (document.body?.innerText || '').slice(0, 200)"
                ) { info, _ in debugLog("challenge: \((info as? String) ?? "?")") }
                self.finishWaiters(.failure(AppError(
                    "Сайт просить перевірку безпеки — оберіть у меню «Пройти перевірку Cloudflare…» і підтвердіть її вручну")))
            }
        }
    }

    private func finishWaiters(_ result: Result<Void, Error>) {
        loading = false
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        let waiters = csrfWaiters
        csrfWaiters = []
        waiters.forEach { $0(result) }
    }

    // MARK: Пошук адреси (autocomplete: місто → вулиця → будинок)

    func resolveAddress(city: String, street: String, house: String,
                        completion: @escaping (Result<AddressConfig, Error>) -> Void) {
        ensureReady { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result { completion(.failure(error)); return }
            let js = """
            const enc = encodeURIComponent;
            const get = async (u) => (await fetch(u)).json();
            const norm = (s) => s.toLowerCase().trim();
            const cities = await get('/api/autocomplete.php?type=city&q=' + enc(city));
            if (!cities.items || !cities.items.length) return JSON.stringify({error: 'Місто не знайдено'});
            const c = cities.items.find(x => norm(x.label).includes(norm(city))) || cities.items[0];
            const streets = await get('/api/autocomplete.php?type=street&q=' + enc(street) + '&ref=' + c.id);
            if (!streets.items || !streets.items.length) return JSON.stringify({error: 'Вулицю не знайдено'});
            const s = streets.items.find(x => norm(x.label) === norm(street))
                   || streets.items.find(x => norm(x.label).startsWith('вулиця'))
                   || streets.items[0];
            const houses = await get('/api/autocomplete.php?type=house&q=' + enc(house) + '&ref=' + s.id);
            if (!houses.items || !houses.items.length) return JSON.stringify({error: 'Будинок не знайдено'});
            const h = houses.items.find(x => norm(x.label) === norm(house)) || houses.items[0];
            return JSON.stringify({city: c, street: s, house: h});
            """
            self.webView.callAsyncJavaScript(js,
                                             arguments: ["city": city, "street": street, "house": house],
                                             in: nil, in: .page) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let value):
                    guard let text = value as? String, let data = text.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        completion(.failure(AppError("Неочікувана відповідь автодоповнення")))
                        return
                    }
                    if let message = obj["error"] as? String {
                        completion(.failure(AppError(message)))
                        return
                    }
                    guard let c = obj["city"] as? [String: Any],
                          let s = obj["street"] as? [String: Any],
                          let h = obj["house"] as? [String: Any],
                          let cityId = c["id"] as? String, let cityLabel = c["label"] as? String,
                          let streetId = s["id"] as? String, let streetLabel = s["label"] as? String,
                          let houseId = h["id"] as? String, let houseLabel = h["label"] as? String else {
                        completion(.failure(AppError("Неповні дані адреси")))
                        return
                    }
                    completion(.success(AddressConfig(cityId: cityId, cityLabel: cityLabel,
                                                      streetId: streetId, streetLabel: streetLabel,
                                                      houseId: houseId, houseLabel: houseLabel)))
                }
            }
        }
    }

    // MARK: Отримання графіка

    func fetchSchedule(config: AddressConfig, retry: Bool = true,
                       completion: @escaping (Result<Schedule, Error>) -> Void) {
        ensureReady { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result { completion(.failure(error)); return }
            let js = """
            const el = document.querySelector('input[name=csrf]');
            if (!el) return JSON.stringify({ok: false, message: 'no_csrf'});
            const fd = new FormData();
            fd.set('csrf', el.value);
            fd.set('selected_eic', '');
            fd.set('website', '');
            fd.set('type', 'address');
            fd.set('value', houseId);
            fd.set('city_id', cityId);
            fd.set('city_label', cityLabel);
            fd.set('street_id', streetId);
            fd.set('street_label', streetLabel);
            fd.set('house_id', houseId);
            fd.set('house_label', houseLabel);
            const r = await fetch('/api/search.php', {method: 'POST', body: fd});
            return await r.text();
            """
            let args: [String: Any] = [
                "cityId": config.cityId, "cityLabel": config.cityLabel,
                "streetId": config.streetId, "streetLabel": config.streetLabel,
                "houseId": config.houseId, "houseLabel": config.houseLabel,
            ]
            self.webView.callAsyncJavaScript(js, arguments: args, in: nil, in: .page) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let value):
                    guard let text = value as? String else {
                        completion(.failure(AppError("Порожня відповідь API")))
                        return
                    }
                    do {
                        completion(.success(try Self.parse(text)))
                    } catch {
                        // Протух csrf / сесія — одна повторна спроба з перезавантаженням сторінки
                        if retry {
                            self.ensureReady(forceReload: true) { _ in
                                self.fetchSchedule(config: config, retry: false, completion: completion)
                            }
                        } else {
                            completion(.failure(error))
                        }
                    }
                }
            }
        }
    }

    private static func parse(_ text: String) throws -> Schedule {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError("Невалідний JSON від API")
        }
        guard (obj["ok"] as? Bool) == true else {
            throw AppError((obj["message"] as? String) ?? "Помилка API")
        }
        guard let tables = obj["tables"] as? [[String: Any]], let table = tables.first else {
            throw AppError("У відповіді немає таблиці графіка")
        }
        let queue = table["listnum"] as? String ?? "?"
        var messages: [String] = []
        if let message = table["message"] as? String, !message.isEmpty { messages.append(message) }
        if let reserve = table["reserve"] as? String, !reserve.isEmpty { messages.append(reserve) }

        var days: [DaySchedule] = []
        for row in (table["rows"] as? [[String: Any]] ?? []) {
            let date = row["date"] as? String ?? ""
            let label = row["label"] as? String ?? date
            var slots = [Int](repeating: 0, count: slotsPerDay)
            let cells = row["cells"] as? [[String: Any]] ?? []
            for (index, cell) in cells.enumerated() where index < 24 {
                var level = 0
                for segment in (cell["segments"] as? [[String: Any]] ?? []) {
                    level = max(level, segment["level"] as? Int ?? 0)
                }
                slots[index * 2] = level
                slots[index * 2 + 1] = level
            }
            days.append(DaySchedule(date: date, label: label, slots: slots))
        }
        return Schedule(queue: queue, days: days, messages: messages, fetched: Date())
    }
}

// MARK: - Резервне джерело: неофіційне дзеркало графіка на GitHub
// https://github.com/vn-progr/gpv-voe-vinnytsia — збирає дані з bezsvitla.com.ua кожні кілька хвилин.
// Використовується лише коли сайт VOE недоступний (перевірка Cloudflare).

enum MirrorClient {
    static let url = URL(string: "https://raw.githubusercontent.com/vn-progr/gpv-voe-vinnytsia/main/data/Vinnytsiaoblenerho.json")!
    static let maxAge: TimeInterval = 3 * 3600

    static func fetch(queue: String, completion: @escaping (Result<Schedule, Error>) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("SvitloBar", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error { completion(.failure(error)); return }
            do {
                completion(.success(try parse(data ?? Data(), queue: queue)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // Половини години: first — немає світла першу половину, second — другу; m* — «можливо»
    private static func halves(_ value: String) -> (Int, Int) {
        switch value {
        case "no": return (4, 4)
        case "first": return (4, 0)
        case "second": return (0, 4)
        case "maybe": return (2, 2)
        case "mfirst": return (2, 0)
        case "msecond": return (0, 2)
        default: return (0, 0)
        }
    }

    static func parse(_ data: Data, queue: String) throws -> Schedule {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fact = obj["fact"] as? [String: Any],
              let byDay = fact["data"] as? [String: Any] else {
            throw AppError("Дзеркало: невалідний JSON")
        }
        let status = obj["lastUpdateStatus"] as? [String: Any]
        let updatedAt = (obj["lastUpdated"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        guard (status?["ok"] as? Bool) == true, let updatedAt, Date().timeIntervalSince(updatedAt) < maxAge else {
            throw AppError("Дзеркало давно не оновлювалось")
        }

        let kyiv = TimeZone(identifier: "Europe/Kyiv") ?? .current
        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = kyiv
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let labelFormatter = DateFormatter()
        labelFormatter.timeZone = kyiv
        labelFormatter.locale = Locale(identifier: "uk_UA")
        labelFormatter.dateFormat = "EEEEEE dd.MM"
        let today = dateFormatter.string(from: Date())

        var days: [DaySchedule] = []
        for key in byDay.keys.sorted() {
            guard let ts = Double(key), let day = byDay[key] as? [String: Any],
                  let hours = day["GPV\(queue)"] as? [String: Any] else { continue }
            let date = Date(timeIntervalSince1970: ts)
            let dateString = dateFormatter.string(from: date)
            guard dateString >= today else { continue }
            var slots = [Int](repeating: 0, count: slotsPerDay)
            for hour in 0..<24 {
                let (a, b) = halves(hours[String(hour + 1)] as? String ?? "yes")
                slots[hour * 2] = a
                slots[hour * 2 + 1] = b
            }
            // Неопублікований день у дзеркалі виглядає як «світло весь день» — не показуємо його
            if dateString != today && slots.allSatisfy({ $0 == 0 }) { continue }
            let label = labelFormatter.string(from: date)
            days.append(DaySchedule(date: dateString, label: label.prefix(1).uppercased() + label.dropFirst(), slots: slots))
        }
        guard !days.isEmpty else { throw AppError("Дзеркало: немає даних для черги \(queue)") }
        return Schedule(queue: queue, days: days, messages: [], fetched: Date(), mirrorUpdated: updatedAt)
    }
}

// MARK: - Вікно налаштувань

final class SettingsWindowController: NSWindowController {
    private let cityField = NSTextField()
    private let streetField = NSTextField()
    private let houseField = NSTextField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Зберегти й перевірити", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let blinkCheckbox = NSButton(checkboxWithTitle: "Блимати в рядку меню за 15 хв до зміни стану",
                                         target: nil, action: nil)
    var onSave: ((String, String, String) -> Void)?
    var onBlinkChange: (() -> Void)?

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "SvitloBar — налаштування адреси"
        self.init(window: window)
        buildUI()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        func row(_ title: String, _ field: NSTextField, _ placeholder: String) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.widthAnchor.constraint(equalToConstant: 80).isActive = true
            field.placeholderString = placeholder
            field.widthAnchor.constraint(equalToConstant: 280).isActive = true
            let stack = NSStackView(views: [label, field])
            stack.orientation = .horizontal
            return stack
        }

        let hint = NSTextField(wrappingLabelWithString:
            "Черга відключень визначається автоматично за адресою (дані АТ «Вінницяобленерго»).")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        saveButton.keyEquivalent = "\r"

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let buttonRow = NSStackView(views: [saveButton, spinner])
        buttonRow.orientation = .horizontal

        statusLabel.font = .systemFont(ofSize: 11)

        let stack = NSStackView(views: [
            row("Місто", cityField, "Вінниця"),
            row("Вулиця", streetField, "Соборна"),
            row("Будинок", houseField, "1"),
            hint,
            buttonRow,
            statusLabel,
            blinkCheckbox,
        ])
        blinkCheckbox.target = self
        blinkCheckbox.action = #selector(blinkToggled)
        blinkCheckbox.state = Store.blinkEnabled ? .on : .off
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
        ])
    }

    func prefill(city: String, street: String, house: String) {
        cityField.stringValue = city
        streetField.stringValue = street
        houseField.stringValue = house
    }

    func setBusy(_ busy: Bool) {
        saveButton.isEnabled = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    func setStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .systemGreen
    }

    // Застосовується одразу, без кнопки «Зберегти»
    @objc private func blinkToggled() {
        Store.blinkEnabled = blinkCheckbox.state == .on
        onBlinkChange?()
    }

    @objc private func saveTapped() {
        let city = cityField.stringValue.trimmingCharacters(in: .whitespaces)
        let street = streetField.stringValue.trimmingCharacters(in: .whitespaces)
        let house = houseField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !city.isEmpty, !street.isEmpty, !house.isEmpty else {
            setStatus("Заповніть усі три поля.", isError: true)
            return
        }
        onSave?(city, street, house)
    }
}

// MARK: - Стан живлення та інтервали

enum PowerLevel {
    case on, maybe, off

    init(level: Int) {
        self = level >= 3 ? .off : (level >= 1 ? .maybe : .on)
    }

    var color: NSColor {
        switch self {
        case .on: return .systemGreen
        case .maybe: return .systemYellow
        case .off: return .systemRed
        }
    }

    var label: String {
        switch self {
        case .on: return "світло є"
        case .maybe: return "можливе"
        case .off: return "відключення"
        }
    }
}

struct PowerInterval {
    let start: Int  // хвилина від початку доби
    let end: Int    // хвилина кінця (не включно)
    let level: PowerLevel
}

enum ScheduleMath {
    // Весь день як послідовність інтервалів однакового стану (включно з годинами, коли світло є)
    static func intervals(_ slots: [Int]) -> [PowerInterval] {
        var result: [PowerInterval] = []
        var index = 0
        while index < slots.count {
            let level = PowerLevel(level: slots[index])
            var end = index
            while end < slots.count && PowerLevel(level: slots[end]) == level { end += 1 }
            result.append(PowerInterval(start: index * slotMinutes, end: end * slotMinutes, level: level))
            index = end
        }
        return result
    }

    // Кількість слотів кожного стану
    static func totals(_ slots: [Int]) -> (on: Int, maybe: Int, off: Int) {
        var on = 0, maybe = 0, off = 0
        for value in slots {
            switch PowerLevel(level: value) {
            case .on: on += 1
            case .maybe: maybe += 1
            case .off: off += 1
            }
        }
        return (on, maybe, off)
    }

    // 5 → "2,5 год", 4 → "2 год"
    static func hoursText(slots: Int) -> String {
        let minutes = slots * slotMinutes
        return minutes % 60 == 0 ? "\(minutes / 60) год" : "\(minutes / 60),5 год"
    }

    static func duration(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) хв" }
        return m == 0 ? "\(h) год" : "\(h) год \(m) хв"
    }
}

// MARK: - Кастомні view для меню

private let menuWidth: CGFloat = 330
private let menuInset: CGFloat = 14

private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                   color: NSColor = .labelColor, mono: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
                      : .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    return field
}

final class DotView: NSView {
    private let color: NSColor
    init(color: NSColor, size: CGFloat = 9) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

// Смуга на 24 години (48 півгодин) з рискою «зараз»
final class TimelineBarView: NSView {
    private let slots: [Int]
    private let nowMinutes: Int?  // nil — день не сьогоднішній
    private let barTop: CGFloat = 4
    private let barHeight: CGFloat = 18

    init(slots: [Int], nowMinutes: Int?) {
        self.slots = slots
        self.nowMinutes = nowMinutes
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 40).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let width = bounds.width
        // Щілина лише між годинами; дві половини години зливаються в одну клітинку
        let gap: CGFloat = 2
        let hourWidth = (width - gap * 23) / 24
        for (slot, value) in slots.prefix(slotsPerDay).enumerated() {
            let hour = slot / 2, half = slot % 2
            let rect = NSRect(x: CGFloat(hour) * (hourWidth + gap) + CGFloat(half) * hourWidth / 2,
                              y: barTop, width: hourWidth / 2, height: barHeight)
            var color = PowerLevel(level: value).color
            if let now = nowMinutes, (slot + 1) * slotMinutes <= now { color = color.withAlphaComponent(0.35) }
            color.setFill()
            NSBezierPath(rect: rect).fill()
        }
        if let now = nowMinutes {
            let x = min(max(CGFloat(now) / 1440 * width, 1), width - 1)
            NSColor.labelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 1, y: 0, width: 2, height: barHeight + barTop * 2),
                         xRadius: 1, yRadius: 1).fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for tick in [0, 6, 12, 18, 24] {
            let text = NSAttributedString(string: "\(tick)", attributes: attrs)
            let size = text.size()
            var x = CGFloat(tick) / 24 * width - size.width / 2
            x = min(max(x, 0), width - size.width)
            text.draw(at: NSPoint(x: x, y: barTop + barHeight + 4))
        }
    }
}

// Обгортка: stack у view фіксованої ширини, придатна для NSMenuItem.view
private func menuView(_ stack: NSStackView, top: CGFloat = 6, bottom: CGFloat = 6) -> NSView {
    stack.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView()
    container.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.topAnchor.constraint(equalTo: container.topAnchor, constant: top),
        stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: menuInset),
        stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -menuInset),
        stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -bottom),
        container.widthAnchor.constraint(equalToConstant: menuWidth),
    ])
    container.frame = NSRect(origin: .zero, size: container.fittingSize)
    return container
}

private func viewItem(_ view: NSView) -> NSMenuItem {
    let item = NSMenuItem()
    item.view = view
    return item
}

private func hStack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = spacing
    return stack
}

private func vStack(_ views: [NSView], spacing: CGFloat = 4) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = spacing
    return stack
}

// Підсумок дня: ● світло 15 год  ● без світла 5 год  ● можливо 4 год
private func totalsRow(_ slots: [Int]) -> NSView {
    let totals = ScheduleMath.totals(slots)
    var parts: [NSView] = []
    var items: [(PowerLevel, String)] = [(.on, "світло \(ScheduleMath.hoursText(slots: totals.on))"),
                                         (.off, "без світла \(ScheduleMath.hoursText(slots: totals.off))")]
    if totals.maybe > 0 { items.append((.maybe, "можливо \(ScheduleMath.hoursText(slots: totals.maybe))")) }
    for (level, text) in items {
        parts.append(hStack([DotView(color: level.color, size: 7),
                             label(text, size: 11.5, color: .secondaryLabelColor, mono: true)], spacing: 4))
    }
    return hStack(parts, spacing: 12)
}

// MARK: - Делегат застосунку

// MARK: - Автооновлення (GitHub Releases)
// Реліз = тег vX.Y з файлом SvitloBar.zip. Завантажений через URLSession архів не отримує
// атрибут quarantine, тож нова версія стартує без повторного попередження Gatekeeper.
enum Updater {
    static let repo = "dzuba1987/svitlo-bar"
    static let assetName = "SvitloBar.zip"

    struct Release {
        let version: String
        let zipURL: URL
        let pageURL: URL?
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func checkLatest(completion: @escaping (Result<Release?, Error>) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SvitloBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error { return completion(.failure(error)) }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else {
                return completion(.failure(AppError("Не вдалося прочитати дані релізу")))
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = obj["assets"] as? [[String: Any]] ?? []
            guard isNewer(version, than: currentVersion),
                  let asset = assets.first(where: { $0["name"] as? String == assetName }),
                  let link = asset["browser_download_url"] as? String,
                  let zipURL = URL(string: link) else {
                return completion(.success(nil))
            }
            let page = (obj["html_url"] as? String).flatMap(URL.init(string:))
            completion(.success(Release(version: version, zipURL: zipURL, pageURL: page)))
        }.resume()
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    // Завантажує архів, розпаковує й підміняє поточний .app на місці.
    static func install(_ release: Release, completion: @escaping (Error?) -> Void) {
        URLSession.shared.downloadTask(with: release.zipURL) { tempFile, _, error in
            guard let tempFile else { return completion(error ?? AppError("Не вдалося завантажити оновлення")) }
            do {
                let fm = FileManager.default
                let work = fm.temporaryDirectory.appendingPathComponent("SvitloBarUpdate-\(UUID().uuidString)")
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent(assetName)
                try fm.moveItem(at: tempFile, to: zip)
                try shell("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
                let newApp = work.appendingPathComponent("SvitloBar.app")
                guard fm.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/SvitloBar").path) else {
                    throw AppError("В архіві немає SvitloBar.app")
                }
                try? shell("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
                _ = try fm.replaceItemAt(Bundle.main.bundleURL, withItemAt: newApp)
                try? fm.removeItem(at: work)
                completion(nil)
            } catch {
                completion(error)
            }
        }.resume()
    }

    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    private static func shell(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw AppError("\((tool as NSString).lastPathComponent) завершився з кодом \(process.terminationStatus)")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let client = VOEClient()
    private var settingsController: SettingsWindowController?
    private var schedule: Schedule?
    private var lastError: String?   // не вдалося отримати жодних даних
    private var voeError: String?    // офіційний сайт недоступний (дані можуть бути з дзеркала)
    private var refreshTimer: Timer?
    private var titleTimer: Timer?
    private var animTimer: Timer?
    private var animPhase = false
    private var animIcons: (String, String) = ("", "")
    private var animText = ""
    private var updateTimer: Timer?
    private var availableUpdate: Updater.Release?
    private var isUpdating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⚡︎…"
        rebuildMenu()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        titleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateTitle()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        checkForUpdates(silently: true)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.checkForUpdates(silently: true)
        }

        if Store.load() == nil {
            openSettings()
        } else {
            refresh()
        }
    }

    @objc private func didWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.refresh() }
    }

    // MARK: Оновлення даних

    @objc func refresh() {
        guard let config = Store.load() else { return }
        // Для перевірки резервного джерела: SVITLOBAR_FORCE_MIRROR=1
        if ProcessInfo.processInfo.environment["SVITLOBAR_FORCE_MIRROR"] == "1" {
            fallbackToMirror(voeError: "Сайт просить перевірку безпеки (тест)")
            return
        }
        client.fetchSchedule(config: config) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let schedule):
                    debugLog("refresh ok (VOE): \(schedule.days.map(\.date))")
                    Store.queue = schedule.queue
                    self.apply(schedule, voeError: nil, error: nil)
                case .failure(let error):
                    debugLog("refresh failed (VOE): \(error.localizedDescription)")
                    self.fallbackToMirror(voeError: error.localizedDescription)
                }
            }
        }
    }

    // Офіційний сайт недоступний — пробуємо неофіційне дзеркало
    private func fallbackToMirror(voeError: String) {
        guard let queue = Store.queue ?? schedule?.queue else {
            apply(schedule, voeError: voeError, error: voeError)
            return
        }
        MirrorClient.fetch(queue: queue) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let mirror):
                    debugLog("refresh ok (mirror): \(mirror.days.map(\.date))")
                    self.apply(mirror, voeError: voeError, error: nil)
                case .failure(let error):
                    debugLog("mirror failed: \(error.localizedDescription)")
                    self.apply(self.schedule, voeError: voeError, error: voeError)
                }
            }
        }
    }

    private func apply(_ schedule: Schedule?, voeError: String?, error: String?) {
        self.schedule = schedule
        self.voeError = voeError
        self.lastError = error
        updateTitle()
        rebuildMenu()
    }

    // MARK: Заголовок у менюбарі

    private func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    // Поточний стан + момент наступної зміни (світло ↔ відключення), з переходом через північ
    private struct PowerState {
        let offNow: Bool
        let transition: Date?
    }

    private func computeState(_ schedule: Schedule) -> PowerState? {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let now = Date()
        guard let today = schedule.days.first(where: { $0.date == formatter.string(from: now) }) else {
            return nil
        }
        var slots = today.slots
        if let tomorrowDate = calendar.date(byAdding: .day, value: 1, to: now),
           let tomorrow = schedule.days.first(where: { $0.date == formatter.string(from: tomorrowDate) }) {
            slots += tomorrow.slots
        }
        let slot = nowMinutes() / slotMinutes
        let offNow = slots[slot] >= 1
        var index = slot
        while index < slots.count && (slots[index] >= 1) == offNow { index += 1 }
        var transition: Date?
        if index < slots.count {
            transition = calendar.startOfDay(for: now).addingTimeInterval(TimeInterval(index * slotMinutes * 60))
        }
        return PowerState(offNow: offNow, transition: transition)
    }

    // Міні-смуга дня для рядка меню: 24 стовпчики, висота й колір за станом, рамка — поточна година
    private func sparkImage(slots: [Int]) -> NSImage {
        let barWidth: CGFloat = 2, gap: CGFloat = 1, height: CGFloat = 16
        let width = CGFloat(24) * (barWidth + gap) - gap + 2
        let now = nowMinutes()
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            // стовпчик = година, кожна половина (1 pt) малюється своїм станом
            for (slot, value) in slots.prefix(slotsPerDay).enumerated() {
                let hour = slot / 2, half = slot % 2
                let level = PowerLevel(level: value)
                let barHeight: CGFloat = level == .off ? 14 : (level == .maybe ? 10 : 5)
                var color = level.color
                if (slot + 1) * slotMinutes <= now { color = color.withAlphaComponent(0.4) }
                color.setFill()
                let rect = NSRect(x: 1 + CGFloat(hour) * (barWidth + gap) + CGFloat(half) * barWidth / 2,
                                  y: 1, width: barWidth / 2, height: barHeight)
                NSBezierPath(rect: rect).fill()
            }
            let current = now / 60
            let frame = NSRect(x: CGFloat(current) * (barWidth + gap) + 0.5, y: 0.5,
                               width: barWidth + 1, height: height - 1)
            NSColor.labelColor.setStroke()
            let path = NSBezierPath(roundedRect: frame, xRadius: 1, yRadius: 1)
            path.lineWidth = 1
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeft
        if let today = schedule?.days.first(where: { $0.date == todayString() }) {
            button.image = sparkImage(slots: today.slots)
        } else {
            button.image = nil
        }
        guard let schedule else {
            setAnimating(false)
            button.title = lastError == nil ? "⚡︎…" : "⚡︎ !"
            return
        }
        guard let state = computeState(schedule) else {
            setAnimating(false)
            button.title = "⚡︎ \(schedule.queue)"
            return
        }
        let warningMinutes = 15
        if let transition = state.transition {
            let minutes = max(1, Int(ceil(transition.timeIntervalSinceNow / 60)))
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm"
            let timeString = timeFormatter.string(from: transition)
            if minutes <= warningMinutes {
                // наближається зміна стану — блимаємо
                animText = "за \(minutes) хв"
                animIcons = state.offNow ? ("💡", "🌑") : ("🔌", "⚡️")
                if Store.blinkEnabled {
                    setAnimating(true)
                } else {
                    // без миготіння: статичний відлік
                    setAnimating(false)
                    button.title = " \(animIcons.0) \(animText)"
                }
                return
            }
            setAnimating(false)
            button.title = state.offNow ? " 🔌 до \(timeString)" : " ⚡️ до \(timeString)"
        } else {
            setAnimating(false)
            button.title = state.offNow ? " 🔌" : " ⚡️"
        }
    }

    private func setAnimating(_ animate: Bool) {
        if animate {
            guard animTimer == nil else { return }
            animPhase = false
            blinkTick()
            animTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.blinkTick()
            }
        } else {
            animTimer?.invalidate()
            animTimer = nil
            statusItem.button?.appearsDisabled = false
        }
    }

    private func blinkTick() {
        guard let button = statusItem.button else { return }
        animPhase.toggle()
        button.title = " \(animIcons.0) \(animText)"
        button.appearsDisabled = animPhase
    }

    // MARK: Меню

    // Меню перебудовується при кожному відкритті, щоб «зараз» і відліки були актуальні
    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    private func rebuildMenu() {
        if statusItem.menu == nil {
            let menu = NSMenu()
            menu.delegate = self
            statusItem.menu = menu
        }
        if let menu = statusItem.menu { populate(menu) }
    }

    private func nowMinutes() -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func hhmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    // Головний блок: що зараз і коли зміниться
    private func heroView(_ schedule: Schedule) -> NSView {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let now = Date()
        guard let todayIndex = schedule.days.firstIndex(where: { $0.date == formatter.string(from: now) }) else {
            // Без свіжих даних це не «VOE не опублікував», а «не вдалося оновити»
            let stale = voeError != nil
            return menuView(vStack([label(stale ? "Графік застарів" : "Графіка на сьогодні немає", size: 15, weight: .bold),
                                    label(stale ? "Не вдалося оновити, нижче останній отриманий"
                                                : "Сайт VOE ще не опублікував дані",
                                          size: 12, color: .secondaryLabelColor)]),
                            top: 8)
        }
        var slots = schedule.days[todayIndex].slots
        if todayIndex + 1 < schedule.days.count { slots += schedule.days[todayIndex + 1].slots }
        let minute = nowMinutes()
        let current = PowerLevel(level: slots[minute / slotMinutes])
        var index = minute / slotMinutes + 1
        while index < slots.count && PowerLevel(level: slots[index]) == current { index += 1 }
        let next: (at: Int, level: PowerLevel)? = index < slots.count
            ? (index * slotMinutes, PowerLevel(level: slots[index])) : nil

        let title: String
        var subtitle: String
        switch current {
        case .off: title = "Світла немає"
        case .maybe: title = "Можливе відключення"
        case .on: title = "Світло є"
        }
        if let next {
            let wait = ScheduleMath.duration(minutes: next.at - minute)
            let when = (next.at >= 1440 ? "завтра о " : "о ") + hhmm(next.at)
            switch (current, next.level) {
            case (.on, .off): subtitle = "Відключення \(when) · через \(wait)"
            case (.on, .maybe): subtitle = "Можливе відключення \(when) · через \(wait)"
            case (_, .on): subtitle = "Увімкнуть \(when) · через \(wait)"
            case (.maybe, .off): subtitle = "Точне відключення \(when) · через \(wait)"
            default: subtitle = "До \(when) · ще \(wait)"
            }
        } else {
            subtitle = current == .on ? "Відключень за графіком більше немає" : "До кінця опублікованого графіка"
        }
        let header = hStack([DotView(color: current.color, size: 11),
                             label(title, size: 15, weight: .bold)], spacing: 7)
        return menuView(vStack([header, label(subtitle, size: 12, color: .secondaryLabelColor, mono: true)], spacing: 3),
                        top: 8, bottom: 8)
    }

    // Блок дня: заголовок, підсумок, смуга і (для сьогодні) список інтервалів
    private func dayView(_ day: DaySchedule, isToday: Bool) -> NSView {
        let now = isToday ? nowMinutes() : nil
        let header = label(isToday ? "Сьогодні, \(day.label)" : day.label, size: 13, weight: .semibold)
        let bar = TimelineBarView(slots: day.slots, nowMinutes: now)
        var views: [NSView] = [header, totalsRow(day.slots), bar]

        if isToday, let now {
            var rows: [NSView] = []
            for interval in ScheduleMath.intervals(day.slots) {
                let past = interval.end <= now
                let isCurrent = interval.start <= now && now < interval.end
                let tagText = isCurrent ? "\(interval.level.label) · зараз" : (past ? "минуло" : interval.level.label)
                let endText = interval.end == 1440 ? "24:00" : hhmm(interval.end)
                let time = label("\(hhmm(interval.start))–\(endText)",
                                 size: 12.5, weight: isCurrent ? .semibold : .regular, mono: true)
                let tag = label(tagText, size: 12, weight: isCurrent ? .semibold : .regular,
                                color: isCurrent ? interval.level.color : .secondaryLabelColor)
                let length = label(ScheduleMath.hoursText(slots: (interval.end - interval.start) / slotMinutes), size: 11.5,
                                   color: .secondaryLabelColor, mono: true)
                let spacer = NSView()
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                let row = hStack([DotView(color: interval.level.color), time, tag, spacer, length])
                row.alphaValue = past ? 0.45 : 1
                rows.append(row)
            }
            let list = vStack(rows, spacing: 3)
            views.append(list)
            list.widthAnchor.constraint(equalToConstant: menuWidth - menuInset * 2).isActive = true
        }
        bar.widthAnchor.constraint(equalToConstant: menuWidth - menuInset * 2).isActive = true
        return menuView(vStack(views, spacing: 6))
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let lastError, !lastError.contains("перевірку безпеки") {
            menu.addItem(disabled("⚠️ \(lastError)"))
        }
        if let voeError, voeError.contains("перевірку безпеки"), schedule?.mirrorUpdated == nil {
            // Немає навіть дзеркала — клікабельно відкриває вікно перевірки
            let item = makeItem("⚠️ Потрібна перевірка Cloudflare — натисніть", #selector(solveChallenge), "")
            item.toolTip = voeError
            menu.addItem(item)
        }

        if let schedule {
            menu.addItem(viewItem(heroView(schedule)))
            for message in schedule.messages {
                menu.addItem(disabled("ℹ️ \(message)"))
            }
            let today = todayString()
            for day in schedule.days {
                menu.addItem(.separator())
                menu.addItem(viewItem(dayView(day, isToday: day.date == today)))
            }
            if schedule.days.count < 2 {
                menu.addItem(disabled("Графік на завтра ще не опубліковано"))
            }
        }

        menu.addItem(.separator())
        if let config = Store.load() {
            let queue = schedule.map { " • черга \($0.queue)" } ?? ""
            menu.addItem(disabled("\(config.shortLabel)\(queue)"))
        }
        if let schedule {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            if let mirrorUpdated = schedule.mirrorUpdated {
                menu.addItem(disabled("Джерело: неофіційне дзеркало · оновлено о \(formatter.string(from: mirrorUpdated))"))
                let item = makeItem("Сайт VOE просить перевірку — пройти для офіційних даних", #selector(solveChallenge), "")
                item.toolTip = voeError
                menu.addItem(item)
            } else {
                menu.addItem(disabled("Джерело: сайт VOE · оновлено о \(formatter.string(from: schedule.fetched))"))
            }
        }

        menu.addItem(.separator())
        if let update = availableUpdate {
            let title = isUpdating ? "Оновлення до \(update.version)…" : "⬆️ Встановити оновлення \(update.version)"
            let item = makeItem(title, #selector(installUpdate), "")
            item.isEnabled = !isUpdating
            menu.addItem(item)
        }
        menu.addItem(makeItem("Оновити зараз", #selector(refresh), "r"))
        menu.addItem(makeItem("Налаштування…", #selector(openSettings), ","))
        menu.addItem(makeItem("Відкрити сайт VOE", #selector(openSite), ""))
        menu.addItem(makeItem("Пройти перевірку Cloudflare…", #selector(solveChallenge), ""))

        if #available(macOS 13.0, *) {
            let login = makeItem("Запускати при вході", #selector(toggleLoginItem), "")
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }

        menu.addItem(makeItem("Перевірити оновлення (версія \(Updater.currentVersion))", #selector(checkForUpdatesManually), ""))

        menu.addItem(.separator())
        menu.addItem(makeItem("Вийти", #selector(quit), "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func makeItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: Дії меню

    @objc private func solveChallenge() {
        client.presentChallengeWindow()
        refresh()
    }

    @objc private func openSite() {
        NSWorkspace.shared.open(URL(string: "https://disconnection.voe.com.ua/")!)
    }

    @objc private func toggleLoginItem() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Login item error: \(error)")
        }
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Автооновлення

    @objc private func checkForUpdatesManually() {
        checkForUpdates(silently: false)
    }

    private func checkForUpdates(silently: Bool) {
        Updater.checkLatest { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let release):
                    self.availableUpdate = release
                    self.rebuildMenu()
                    if !silently {
                        if let release {
                            self.confirmUpdate(release)
                        } else {
                            self.showAlert("У вас остання версія", "SvitloBar \(Updater.currentVersion)")
                        }
                    }
                case .failure(let error):
                    debugLog("update check failed: \(error.localizedDescription)")
                    if !silently {
                        self.showAlert("Не вдалося перевірити оновлення", error.localizedDescription)
                    }
                }
            }
        }
    }

    private func confirmUpdate(_ release: Updater.Release) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Доступна версія \(release.version)"
        alert.informativeText = "Зараз встановлено \(Updater.currentVersion). Встановити й перезапустити?"
        alert.addButton(withTitle: "Встановити")
        alert.addButton(withTitle: "Пізніше")
        if alert.runModal() == .alertFirstButtonReturn {
            installUpdate()
        }
    }

    @objc private func installUpdate() {
        guard let release = availableUpdate, !isUpdating else { return }
        isUpdating = true
        rebuildMenu()
        Updater.install(release) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.isUpdating = false
                    self.rebuildMenu()
                    debugLog("update install failed: \(error.localizedDescription)")
                    self.showAlert("Не вдалося встановити оновлення", error.localizedDescription)
                    return
                }
                debugLog("updated to \(release.version), relaunching")
                Updater.relaunch()
            }
        }
    }

    private func showAlert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    @objc func openSettings() {
        if settingsController == nil {
            let controller = SettingsWindowController()
            controller.onSave = { [weak self] city, street, house in
                self?.saveAddress(city: city, street: street, house: house)
            }
            controller.onBlinkChange = { [weak self] in
                self?.updateTitle()
            }
            settingsController = controller
        }
        if let config = Store.load() {
            let city = config.cityLabel.components(separatedBy: " (").first?
                .replacingOccurrences(of: "м.", with: "") ?? ""
            let street = config.streetLabel
            settingsController?.prefill(city: city, street: street, house: config.houseLabel)
        }
        settingsController?.window?.center()
        settingsController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func saveAddress(city: String, street: String, house: String) {
        settingsController?.setBusy(true)
        settingsController?.setStatus("Шукаю адресу в довіднику VOE…", isError: false)
        client.resolveAddress(city: city, street: street, house: house) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.settingsController?.setBusy(false)
                    self.settingsController?.setStatus(error.localizedDescription, isError: true)
                case .success(let config):
                    Store.save(config)
                    self.settingsController?.setStatus("Адресу знайдено: \(config.shortLabel). Отримую графік…", isError: false)
                    self.client.fetchSchedule(config: config) { scheduleResult in
                        DispatchQueue.main.async {
                            self.settingsController?.setBusy(false)
                            switch scheduleResult {
                            case .success(let schedule):
                                Store.queue = schedule.queue
                                self.schedule = schedule
                                self.lastError = nil
                                self.voeError = nil
                                self.settingsController?.setStatus(
                                    "Готово. Черга \(schedule.queue) — \(config.shortLabel)", isError: false)
                                self.updateTitle()
                                self.rebuildMenu()
                            case .failure(let error):
                                self.lastError = error.localizedDescription
                                self.settingsController?.setStatus(error.localizedDescription, isError: true)
                                self.rebuildMenu()
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Запуск

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
