import Foundation

struct QncTable: Codable, Identifiable, Equatable, Hashable {
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

private let qncResponseSeparator = "###qncSeparator###"

private func qncResponseData(from responseText: String) -> String {
    let parts = responseText.components(separatedBy: qncResponseSeparator)
    return parts.first ?? responseText
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

    func fetchRows(selectString: String, deviceID: String) async throws -> String {
        var comps = URLComponents(string: "https://api.quenic.com/qncAPITable")
        comps?.queryItems = [
            URLQueryItem(name: "selectString", value: selectString),
            URLQueryItem(name: "deviceID", value: deviceID)
        ]
        guard let url = comps?.url else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw APIError.badStatus(http.statusCode)
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(decoding: data, as: UTF8.self)
    }

    func fetchResultTable(selectString: String, deviceID: String) async throws -> QueryResultTable {
        let text = try await fetchRows(selectString: selectString, deviceID: deviceID)
        return try QueryResultTableParser().parse(responseText: text)
    }
}

struct QueryResultTable: Equatable, Sendable {
    let columns: [String]
    let rows: [QueryResultRow]

    var isEmpty: Bool {
        columns.isEmpty || rows.isEmpty
    }
}

struct QueryResultRow: Identifiable, Equatable, Sendable {
    let id = UUID()
    let values: [String: String]
}

final class QueryResultTableParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private struct XMLNode {
        let name: String
        var text: String = ""
        var children: [XMLNode] = []

        var textContent: String {
            let childText = children
                .map(\.textContent)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return [text, childText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }

    private var root: XMLNode?
    private var stack: [XMLNode] = []

    func parse(responseText: String) throws -> QueryResultTable {
        let dataPart = qncResponseData(from: responseText)
        let trimCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}"))
        let cleaned = dataPart.trimmingCharacters(in: trimCharacters)

        guard !cleaned.isEmpty else {
            return QueryResultTable(columns: [], rows: [])
        }

        guard cleaned.first == "<" else {
            return parseDelimitedText(cleaned) ?? parsePlainText(cleaned)
        }

        let table = try parseXML(cleaned)
        return table.isEmpty ? (parseDelimitedText(cleaned) ?? table) : table
    }

    private func parseXML(_ xml: String) throws -> QueryResultTable {
        root = nil
        stack.removeAll()

        guard let data = xml.data(using: .utf8) else {
            throw APIError.decoding(NSError(domain: "QueryResultTableParser", code: -1, userInfo: [NSLocalizedDescriptionKey: "XML konnte nicht gelesen werden."]))
        }

        let parser = XMLParser(data: data)
        parser.delegate = self

        guard parser.parse(), let root else {
            throw APIError.decoding(parser.parserError ?? NSError(domain: "QueryResultTableParser", code: -2, userInfo: [NSLocalizedDescriptionKey: "XML konnte nicht verarbeitet werden."]))
        }

        let rowNodes = collectRowNodes(in: root)
        var columns: [String] = []
        var rows: [QueryResultRow] = []

        for node in rowNodes {
            var values: [String: String] = [:]

            for child in node.children where isColumnNode(child) {
                let column = displayName(for: child.name)
                if !columns.contains(column) {
                    columns.append(column)
                }

                let value = child.textContent
                if let existing = values[column], !existing.isEmpty, !value.isEmpty {
                    values[column] = [existing, value].joined(separator: "\n")
                } else {
                    values[column] = value
                }
            }

            if !values.isEmpty {
                rows.append(QueryResultRow(values: values))
            }
        }

        return QueryResultTable(columns: columns, rows: rows)
    }

    private func collectRowNodes(in node: XMLNode) -> [XMLNode] {
        if isRowNode(node) {
            return [node]
        }

        return node.children.flatMap { collectRowNodes(in: $0) }
    }

    private func isRowNode(_ node: XMLNode) -> Bool {
        guard isDataElement(node.name), !node.children.isEmpty else {
            return false
        }

        let columnChildren = node.children.filter { isColumnNode($0) }
        return !columnChildren.isEmpty && columnChildren.count == node.children.count
    }

    private func isColumnNode(_ node: XMLNode) -> Bool {
        isDataElement(node.name) && node.children.isEmpty
    }

    private func isDataElement(_ name: String) -> Bool {
        let lowercasedName = name.lowercased()
        let localName = displayName(for: name).lowercased()
        let containerNames = ["documentelement", "newdataset", "dataset", "diffgram", "schema"]

        return !containerNames.contains(localName)
            && !lowercasedName.contains("schema")
            && !lowercasedName.hasPrefix("xs:")
            && !lowercasedName.hasPrefix("xsd:")
            && !lowercasedName.hasPrefix("msdata:")
            && !lowercasedName.hasPrefix("diffgr:")
    }

    private func displayName(for elementName: String) -> String {
        elementName.components(separatedBy: ":").last ?? elementName
    }

    private func parseDelimitedText(_ text: String) -> QueryResultTable? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let headerLine = lines.first, lines.count > 1 else {
            return nil
        }

        let delimiter = ["\t", ";", "|", ","].max { lhs, rhs in
            split(headerLine, delimiter: lhs).count < split(headerLine, delimiter: rhs).count
        } ?? "\t"

        let headerParts = split(headerLine, delimiter: delimiter)
        guard headerParts.count > 1 else {
            return nil
        }

        let columns = uniqueColumns(from: headerParts)
        let rows = lines.dropFirst().map { line in
            let parts = split(line, delimiter: delimiter)
            var values: [String: String] = [:]

            for index in columns.indices {
                values[columns[index]] = index < parts.count ? parts[index] : ""
            }

            return QueryResultRow(values: values)
        }

        return QueryResultTable(columns: columns, rows: rows)
    }

    private func parsePlainText(_ text: String) -> QueryResultTable {
        let column = "Ergebnis"
        let rows = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { QueryResultRow(values: [column: $0]) }

        return QueryResultTable(columns: rows.isEmpty ? [] : [column], rows: rows)
    }

    private func split(_ line: String, delimiter: String) -> [String] {
        line.components(separatedBy: delimiter)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func uniqueColumns(from names: [String]) -> [String] {
        var counts: [String: Int] = [:]

        return names.enumerated().map { index, name in
            let baseName = name.isEmpty ? "Spalte \(index + 1)" : name
            let count = counts[baseName, default: 0] + 1
            counts[baseName] = count
            return count == 1 ? baseName : "\(baseName) \(count)"
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        stack.append(XMLNode(name: elementName))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let node = stack.popLast() else { return }

        if stack.isEmpty {
            root = node
        } else {
            stack[stack.count - 1].children.append(node)
        }
    }
}

struct VTablesRow: Identifiable, Hashable {
    let id = UUID()
    let catalog: String
    let schema: String
    let name: String
    let type: String
}

final class VTablesService {
    static let shared = VTablesService()
    private init() {}

    func fetchVTables(deviceID: String) async throws -> [VTablesRow] {
        // Build select and call existing text/plain endpoint
        let select = "select * from [V_Tables]"
        let text = try await APIService.shared.fetchRows(selectString: select, deviceID: deviceID)
        let dataPart = qncResponseData(from: text)
        // Trim potential BOM/whitespace
        let cleaned = dataPart.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = VTablesXMLParser().parse(dataXML: cleaned)
        if rows.isEmpty { throw APIError.decoding(NSError(domain: "VTables", code: -1, userInfo: [NSLocalizedDescriptionKey: "Keine Tabellen gefunden (XML leer oder Kodierung unverträglich)"])) }
        return rows
    }
}

final class VTablesXMLParser: NSObject, XMLParserDelegate {
    private var rows: [VTablesRow] = []
    private var currentElement: String = ""
    private var currentCatalog: String = ""
    private var currentSchema: String = ""
    private var currentName: String = ""
    private var currentType: String = ""
    private var accumulating: String = ""

    func parse(dataXML: String) -> [VTablesRow] {
        rows.removeAll()
        if let data = dataXML.data(using: .utf8) {
            let parser = XMLParser(data: data)
            parser.delegate = self
            if parser.parse() { return rows }
        }
        if let data = dataXML.data(using: .unicode) { // UTF-16 fallback
            let parser = XMLParser(data: data)
            parser.delegate = self
            if parser.parse() { return rows }
        }
        return rows
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        accumulating = ""
        if elementName == "V_TABLES" {
            currentCatalog = ""
            currentSchema = ""
            currentName = ""
            currentType = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        accumulating += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = accumulating.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "TABLE_CATALOG": currentCatalog = value
        case "TABLE_SCHEMA": currentSchema = value
        case "TABLE_NAME": currentName = value
        case "TABLE_TYPE": currentType = value
        case "V_TABLES":
            let row = VTablesRow(catalog: currentCatalog, schema: currentSchema, name: currentName, type: currentType)
            rows.append(row)
        default: break
        }
        accumulating = ""
    }
}
struct QncTableEntry: Identifiable, Hashable, Codable, Sendable {
    let id = UUID()
    let name: String
    let selectString: String
    let iconName: String?

    enum CodingKeys: String, CodingKey {
        case name
        case selectString
        case iconName
    }
}

final class QncTablesService {
    static let shared = QncTablesService()
    private init() {}

    func fetchEntries(deviceID: String) async throws -> [QncTableEntry] {
        let select = "select * from [T_QNCTABLES]"
        let text = try await APIService.shared.fetchRows(selectString: select, deviceID: deviceID)
        let dataPart = qncResponseData(from: text)
        let cleaned = dataPart.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = QncTablesXMLParser().parse(dataXML: cleaned)
        if rows.isEmpty { throw APIError.decoding(NSError(domain: "QncTables", code: -1, userInfo: [NSLocalizedDescriptionKey: "Keine Einträge gefunden (T_QNCTABLES)"])) }
        return rows
    }
}

struct QncTableEntriesCache: Sendable {
    struct CachedEntries: Sendable {
        let entries: [QncTableEntry]
        let loadedAt: Date
    }

    nonisolated init() {}

    nonisolated func cachedEntries(for deviceID: String) -> CachedEntries? {
        guard let url = cacheURL(for: deviceID),
              let loadedAt = loadedAt(for: url),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([QncTableEntry].self, from: data),
              !entries.isEmpty else {
            return nil
        }

        return CachedEntries(entries: entries, loadedAt: loadedAt)
    }

    nonisolated func save(_ entries: [QncTableEntry], for deviceID: String, loadedAt: Date = Date()) {
        guard !entries.isEmpty, let url = cacheURL(for: deviceID) else {
            return
        }

        let directoryURL = url.deletingLastPathComponent()
        do {
            let data = try JSONEncoder().encode(entries)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: loadedAt], ofItemAtPath: url.path)
        } catch {
            return
        }
    }

    private nonisolated func loadedAt(for url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }

        return attributes[.modificationDate] as? Date
    }

    private nonisolated func cacheURL(for deviceID: String) -> URL? {
        guard let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        return applicationSupportURL
            .appendingPathComponent("qncTABLE", isDirectory: true)
            .appendingPathComponent("table-overview-cache", isDirectory: true)
            .appendingPathComponent(cacheFileName(for: deviceID))
    }

    private nonisolated func cacheFileName(for key: String) -> String {
        let hash = key.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partialResult, byte in
            (partialResult ^ UInt64(byte)) &* 1_099_511_628_211
        }

        return String(format: "%016llx.cache", hash)
    }
}

final class QncTablesXMLParser: NSObject, XMLParserDelegate {
    private var entries: [QncTableEntry] = []
    private var currentElement: String = ""
    private var currentName: String = ""
    private var currentSelect: String = ""
    private var currentIcon: String = ""
    private var accumulating: String = ""

    func parse(dataXML: String) -> [QncTableEntry] {
        entries.removeAll()
        if let data = dataXML.data(using: .utf8) {
            let parser = XMLParser(data: data)
            parser.delegate = self
            if parser.parse() { return entries }
        }
        if let data = dataXML.data(using: .unicode) {
            let parser = XMLParser(data: data)
            parser.delegate = self
            if parser.parse() { return entries }
        }
        return entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        accumulating = ""
        if elementName == "T_QNCTABLES" {
            currentName = ""
            currentSelect = ""
            currentIcon = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        accumulating += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = accumulating.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Name": currentName = value
        case "SelectString": currentSelect = value
        case "IconName": currentIcon = value
        case "T_QNCTABLES":
            let entry = QncTableEntry(name: currentName, selectString: currentSelect, iconName: currentIcon.isEmpty ? nil : currentIcon)
            entries.append(entry)
        default: break
        }
        accumulating = ""
    }
}
