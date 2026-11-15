import SwiftUI
import MapKit
import CoreLocation

// MARK: - Кореневий екран

struct ContentView: View {
    @EnvironmentObject var s: AppState
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView {
            StatusView()
                .tabItem { Label("Статус", systemImage: "exclamationmark.triangle.fill") }
            MapTab()
                .tabItem { Label("Карта", systemImage: "map.fill") }
            SettingsView()
                .tabItem { Label("Налаштування", systemImage: "gearshape.fill") }
        }
        .onChange(of: phase) { _, new in s.sceneChanged(new) }
    }
}

// MARK: - 1. Статус

struct StatusView: View {
    @EnvironmentObject var s: AppState

    private var tint: Color { s.alarmActive ? .red : .green }

    private var distanceText: String {
        guard s.mode != .never, let h = s.house, let u = s.userLocation else { return "—" }
        let m = u.distance(from: CLLocation(latitude: h.latitude, longitude: h.longitude))
        return m < 1000 ? "\(Int(m)) м" : String(format: "%.1f км", m / 1000)
    }

    private var gpsText: String {
        if s.mode == .never { return "вимкнено" }
        switch s.auth {
        case .authorizedAlways: return "завжди"
        case .authorizedWhenInUse: return "лише коли відкрито"
        case .notDetermined: return "чекає дозволу"
        default: return "нема доступу"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Text("Статус тітки").font(.footnote)
                    Text(s.alarmActive ? "ШТУРМОВА ТРИВОГА" : "ТРИВОГИ НЕМАЄ")
                        .font(.system(size: 30, weight: .heavy))
                        .multilineTextAlignment(.center)
                    if s.alarmActive, let since = s.alarmSince {
                        Text(since, style: .timer)
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    Text(s.alarmActive ? "Тітка в небезпеці" : "Тітка в безпеці").font(.footnote)
                }
                .frame(maxWidth: .infinity)
                .padding(22)
                .foregroundStyle(tint)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(tint, lineWidth: 2))

                Button {
                    s.toggleManual()
                } label: {
                    Text(s.alarmActive ? "Відбій тривоги" : "Оголосити штурмову тривогу")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(s.alarmActive ? Color.primary : Color.red)
                .controlSize(.large)

                VStack(spacing: 0) {
                    row("Остання тривога тривала", s.lastDuration > 0 ? fmtDuration(s.lastDuration) : "—")
                    Divider()
                    row("Від тебе до тітки", distanceText)
                    Divider()
                    row("GPS", gpsText)
                }
                .padding(.horizontal, 16)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(16)
        }
    }

    private func row(_ a: String, _ b: String) -> some View {
        HStack {
            Text(a).foregroundStyle(.secondary)
            Spacer()
            Text(b).monospacedDigit()
        }
        .padding(.vertical, 12)
    }
}

// MARK: - 2. Карта

struct TargetView: View {
    var body: some View {
        ZStack {
            Circle().stroke(Color.blue, lineWidth: 2).frame(width: 34, height: 34)
            Circle().stroke(Color.blue, lineWidth: 1.5).frame(width: 18, height: 18)
            Circle().fill(Color.blue).frame(width: 5, height: 5)
        }
    }
}

struct HouseMark: View {
    var active: Bool
    var body: some View {
        ZStack {
            Circle().fill(Color.red.opacity(active ? 0.35 : 0.2)).frame(width: 40, height: 40)
            Image(systemName: "house.fill").foregroundStyle(Color.red).font(.title3)
        }
    }
}

struct MapTab: View {
    @EnvironmentObject var s: AppState
    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 49.8096, longitude: 30.1122),
                           span: MKCoordinateSpan(latitudeDelta: 0.07, longitudeDelta: 0.07)))
    @State private var pending: CLLocationCoordinate2D?

    var body: some View {
        VStack(spacing: 0) {
            if s.house == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Перше відкриття: де живе тітка?").font(.headline)
                    Text("Торкнись карти там, де її будинок. Змінити потім не вийде.")
                        .font(.subheadline)
                    if let p = pending {
                        Button("Це будинок тітки") {
                            s.setHouse(p)
                            pending = nil
                            position = .region(MKCoordinateRegion(center: p,
                                                                  latitudinalMeters: 900,
                                                                  longitudinalMeters: 900))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial)
            }

            MapReader { proxy in
                Map(position: $position) {
                    if let h = s.house {
                        MapCircle(center: h, radius: s.radius)
                            .foregroundStyle(Color.red.opacity(s.alarmActive ? 0.25 : 0.1))
                            .stroke(Color.red, lineWidth: 2)
                        Annotation("Тітка", coordinate: h) { HouseMark(active: s.alarmActive) }
                    } else if let p = pending {
                        Annotation("Тут?", coordinate: p) {
                            Image(systemName: "mappin.circle.fill").font(.largeTitle).foregroundStyle(Color.red)
                        }
                    }
                    if s.mode != .never, let loc = s.userLocation {
                        Annotation("Ти", coordinate: loc.coordinate) { TargetView() }
                    }
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                    MapScaleView()
                }
                .onTapGesture { point in
                    if s.house == nil, let c = proxy.convert(point, from: .local) {
                        pending = c
                    }
                }
            }
        }
        .onAppear {
            if let h = s.house {
                position = .region(MKCoordinateRegion(center: h, latitudinalMeters: 1200, longitudinalMeters: 1200))
            }
        }
    }
}

// MARK: - 3. Налаштування

struct SettingsView: View {
    @EnvironmentObject var s: AppState
    @State private var pw = ""
    @State private var pwError = false
    @State private var radText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Коли дивитись GPS") {
                    ForEach(GPSMode.allCases) { m in
                        Button {
                            s.setMode(m)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.title).foregroundStyle(.primary)
                                    Text(m.subtitle).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if s.mode == m { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                    if s.needsAlwaysFix {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Щоб тривога працювала у фоні, у налаштуваннях iPhone обери доступ до геолокації «Завжди».")
                                .font(.footnote).foregroundStyle(.red)
                            Button("Відкрити налаштування iPhone") { s.openSystemSettings() }
                        }
                    }
                }

                Section("Сповіщення") {
                    Text(s.notifAllowed ? "Увімкнено" : "Вимкнено")
                        .foregroundStyle(.secondary)
                    if !s.notifAllowed {
                        Button("Відкрити налаштування iPhone") { s.openSystemSettings() }
                    }
                }

                Section("Адмін") {
                    SecureField("Пароль адміна", text: $pw)
                        .keyboardType(.numberPad)
                    Button("Ввійти") {
                        if s.login(pw) {
                            pwError = false
                            radText = String(Int(s.radius))
                        } else {
                            pwError = true
                        }
                        pw = ""
                    }
                    if pwError { Text("Неправильний пароль.").foregroundStyle(.red).font(.footnote) }
                }

                if s.devMode {
                    Section("Режим розробника") {
                        Text("Поки що нічого не робить, крім цього:").font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            TextField("Радіус зони, метрів", text: $radText)
                                .keyboardType(.numberPad)
                            Button("Зберегти") {
                                if let v = Double(radText) { s.setRadius(v); radText = String(Int(s.radius)) }
                            }
                        }
                        Text("Зараз: \(Int(s.radius)) м (від 10 до 5000)")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Скинути точку дому", role: .destructive) { s.resetHouse() }
                        Button("Вимкнути режим розробника") { s.setDev(false) }
                    }
                }
            }
            .navigationTitle("Налаштування")
            .onAppear { radText = String(Int(s.radius)) }
        }
    }
}
