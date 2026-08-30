import Foundation

struct QncTable: Codable, Identifiable, Equatable {
    // Assuming API returns at least an id and a name; adjust keys if needed based on Swagger
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case id = "id"
        case name = "name"
    }
}

enum APIError: Error, LocalizedError {
    case invalidURL
    case badStatus(Int)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Ungültige URL"
        case .badStatus(let code): return "Serverfehler (Status: \(code))"
        case .decoding(let err): return "Daten konnten nicht gelesen werden: \(err.localizedDescription)"
        }
    }
}

final class APIService {
    static let shared = APIService()
    private init() {}

    func fetchTables() async throws -> [QncTable] {
        guard let url = URL(string: "https://api.quenic.com/swagger/qncAPITable") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw APIError.badStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode([QncTable].self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }
}
