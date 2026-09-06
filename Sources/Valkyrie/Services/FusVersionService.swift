import Foundation

/// A firmware version triple as Samsung publishes it: AP (system), CSC (region), CP (modem).
struct FirmwareBuild: Identifiable, Hashable {
    let ap: String
    let csc: String
    let cp: String

    var id: String { "\(ap)/\(csc)/\(cp)" }
    var display: String { id }

    init?(raw: String) {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, !parts[0].isEmpty else { return nil }
        ap = parts[0]
        csc = parts[1]
        // Some entries leave the CP field blank, meaning "same as AP".
        cp = parts[2].isEmpty ? parts[0] : parts[2]
    }
}

struct FirmwareVersionInfo {
    let model: String
    let region: String
    let latest: FirmwareBuild
    let androidVersion: String?
    let history: [FirmwareBuild]
}

enum FusVersionError: LocalizedError {
    case badModelOrRegion
    case notFound(model: String, region: String)
    case malformed
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .badModelOrRegion:
            return "Enter both a model (e.g. SM-F956B) and a region code (e.g. EUX)."
        case .notFound(let model, let region):
            return "Samsung has no firmware listed for \(model) in region \(region). Check the model spelling and the CSC code."
        case .malformed:
            return "Samsung returned a version list this build couldn't read."
        case .transport(let detail):
            return "Couldn't reach Samsung's version server: \(detail)"
        }
    }
}

/// Reads Samsung's public firmware version index.
///
/// This endpoint needs no authentication at all — it's the same one phones poll for
/// OTA checks — so version lookup always works even when the download servers are
/// gated. It returns the current build plus the full upgrade history for a model.
enum FusVersionService {
    static func versionURL(model: String, region: String) -> URL? {
        let model = model.trimmingCharacters(in: .whitespaces).uppercased()
        let region = region.trimmingCharacters(in: .whitespaces).uppercased()
        return URL(string: "https://fota-cloud-dn.ospserver.net/firmware/\(region)/\(model)/version.xml")
    }

    static func fetch(model rawModel: String, region rawRegion: String) async throws -> FirmwareVersionInfo {
        let model = rawModel.trimmingCharacters(in: .whitespaces).uppercased()
        let region = rawRegion.trimmingCharacters(in: .whitespaces).uppercased()
        guard !model.isEmpty, !region.isEmpty, let url = versionURL(model: model, region: region) else {
            throw FusVersionError.badModelOrRegion
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw FusVersionError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            throw FusVersionError.notFound(model: model, region: region)
        }

        let parser = VersionXMLParser()
        guard parser.parse(data: data), let latestRaw = parser.latest,
              let latest = FirmwareBuild(raw: latestRaw) else {
            // An unknown model/region returns a stub document rather than a 404.
            throw FusVersionError.notFound(model: model, region: region)
        }

        let history = parser.upgrades.compactMap(FirmwareBuild.init(raw:))
        return FirmwareVersionInfo(
            model: model,
            region: region,
            latest: latest,
            androidVersion: parser.androidVersion,
            history: history
        )
    }
}

/// Pulls `<latest>` and the `<upgrade><value>` list out of Samsung's version.xml.
private final class VersionXMLParser: NSObject, XMLParserDelegate {
    private(set) var latest: String?
    private(set) var androidVersion: String?
    private(set) var upgrades: [String] = []

    private var currentElement = ""
    private var buffer = ""
    private var insideUpgrade = false

    func parse(data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        currentElement = elementName
        buffer = ""
        if elementName == "upgrade" { insideUpgrade = true }
        if elementName == "latest" { androidVersion = attributes["o"] }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "latest":
            if !text.isEmpty { latest = text }
        case "value":
            if insideUpgrade, !text.isEmpty { upgrades.append(text) }
        case "upgrade":
            insideUpgrade = false
        default:
            break
        }
        buffer = ""
    }
}
