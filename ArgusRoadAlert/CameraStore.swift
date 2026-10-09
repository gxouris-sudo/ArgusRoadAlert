import Foundation
import CoreLocation

struct Camera: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let kind: String
    let lat: Double
    let lon: Double
    let source: String
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var location: CLLocation { .init(latitude: lat, longitude: lon) }
}

private struct Overpass: Decodable {
    struct El: Decodable { let id: Int; let lat: Double?; let lon: Double?; let tags: [String: String]? }
    let elements: [El]
}
private struct FeedItem: Decodable { let name: String; let kind: String?; let lat: Double; let lon: Double }

@MainActor
final class CameraStore: ObservableObject {
    @Published var cameras: [Camera] = []
    @Published var status = "No data yet. Start monitoring."
    private var osm: [Camera] = []
    private var feed: [Camera] = []
    private var user: [Camera] = []
    private var lastFetch: CLLocation?
    private var lastDate = Date.distantPast
    private var fetching = false
    private let d = UserDefaults.standard

    init() {
        osm = load("osm"); user = load("user"); feed = load("feed")
        merge()
    }
    private func load(_ k: String) -> [Camera] {
        guard let data = d.data(forKey: k) else { return [] }
        return (try? JSONDecoder().decode([Camera].self, from: data)) ?? []
    }
    private func save(_ k: String, _ v: [Camera]) { d.set(try? JSONEncoder().encode(v), forKey: k) }
    private func merge() {
        cameras = osm + feed + user
        if !cameras.isEmpty { status = "\(cameras.count) cameras loaded" }
    }

    func addReport(at l: CLLocation) {
        user.append(Camera(id: UUID().uuidString, name: "Reported camera", kind: "reported",
                           lat: l.coordinate.latitude, lon: l.coordinate.longitude, source: "You"))
        save("user", user); merge()
    }

    func refreshIfNeeded(near loc: CLLocation) async {
        if let last = lastFetch, loc.distance(from: last) < 10_000, Date().timeIntervalSince(lastDate) < 1800 { return }
        guard !fetching else { return }
        fetching = true; defer { fetching = false }
        status = "Updating cameras..."
        let lat = loc.coordinate.latitude, lon = loc.coordinate.longitude
        let q = "[out:json][timeout:25];(node[\"highway\"=\"speed_camera\"](around:30000,\(lat),\(lon));node[\"enforcement\"~\"maxspeed|traffic_signals|average_speed\"](around:30000,\(lat),\(lon)););out body;"
        var req = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = ("data=" + (q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q)).data(using: .utf8)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let r = try JSONDecoder().decode(Overpass.self, from: data)
            osm = r.elements.compactMap { e in
                guard let la = e.lat, let lo = e.lon else { return nil }
                let t = e.tags ?? [:]
                let kind = t["enforcement"] ?? "speed_camera"
                let name = t["name"] ?? (t["maxspeed"].map { "Camera (limit \($0))" } ?? "Enforcement camera")
                return Camera(id: "osm\(e.id)", name: name, kind: kind, lat: la, lon: lo, source: "OpenStreetMap")
            }
            save("osm", osm)
            lastFetch = loc; lastDate = Date()
        } catch { status = "OSM update failed, using cached data" }

        // Optional custom feed (e.g. a JSON list of official AI-camera locations you host)
        if let s = d.string(forKey: "feedURL"), let url = URL(string: s), !s.isEmpty {
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let items = try? JSONDecoder().decode([FeedItem].self, from: data) {
                feed = items.enumerated().map { i, it in
                    Camera(id: "feed\(i)", name: it.name, kind: it.kind ?? "ai", lat: it.lat, lon: it.lon, source: "Custom feed")
                }
                save("feed", feed)
            }
        }
        merge()
    }
}
