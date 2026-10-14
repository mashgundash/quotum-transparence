import Foundation
import OSLog

enum Journal {
    static let donnees = Logger(subsystem: "app.quotum.mac", category: "donnees")
}

/// Le disque, `ps` et le Trousseau sont bloquants. Les exécuter sur une file GCD
/// plutôt que dans la piscine coopérative évite d'y immobiliser un fil pendant que
/// les requêtes réseau attendent, et garde le fil principal libre de dessiner.
enum HorsFil {
    static func executer<T: Sendable>(_ travail: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { suite in
            DispatchQueue.global(qos: .utility).async {
                suite.resume(returning: travail())
            }
        }
    }
}

/// Lire un petit fichier sans jamais pouvoir se figer dessus.
///
/// ⛔ Contrôler le chemin puis l'ouvrir laisse une fenêtre où un tube nommé peut prendre
/// sa place, et `Data(contentsOf:)` attendrait alors un écrivain qui ne vient jamais.
/// L'ouverture est donc non bloquante, et le contrôle porte sur le descripteur ouvert,
/// celui-là même qu'on lit ensuite.
enum LectureFichier {
    enum Echec: Error, Equatable {
        case absent
        case pasUnFichierOrdinaire
        case tropGrand
        case systeme(Int32)
    }

    static func lire(_ url: URL, tailleMaximale: Int = 1 << 20, cheminSansLien: Bool = false) throws(Echec) -> Data {
        let descripteur = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (cheminSansLien ? O_NOFOLLOW_ANY : 0))
        guard descripteur >= 0 else {
            throw errno == ENOENT ? .absent : .systeme(errno)
        }
        defer { close(descripteur) }
        var etat = stat()
        guard fstat(descripteur, &etat) == 0 else { throw .systeme(errno) }
        guard etat.st_mode & S_IFMT == S_IFREG else { throw .pasUnFichierOrdinaire }
        guard etat.st_size <= tailleMaximale else { throw .tropGrand }
        var donnees = Data()
        var tampon = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let lus = tampon.withUnsafeMutableBytes { read(descripteur, $0.baseAddress, $0.count) }
            if lus < 0 {
                if errno == EINTR { continue }
                throw .systeme(errno)
            }
            if lus == 0 { break }
            donnees.append(contentsOf: tampon[0..<lus])
            guard donnees.count <= tailleMaximale else { throw .tropGrand }
        }
        return donnees
    }
}

/// Session dédiée, sans cache : un statut de proxy relu depuis le cache serait un
/// état périmé présenté comme frais.
enum Reseau {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    /// Le travail, ou `nil` si l'échéance tombe avant lui — auquel cas il est annulé.
    static func avantEcheance<Valeur: Sendable>(_ secondes: TimeInterval,
                                                _ travail: @escaping @Sendable () async -> Valeur) async -> Valeur? {
        await withTaskGroup(of: Valeur?.self) { groupe in
            groupe.addTask { await travail() }
            groupe.addTask {
                try? await Task.sleep(for: .seconds(secondes))
                return nil
            }
            let premier = await groupe.next() ?? nil
            groupe.cancelAll()
            return premier
        }
    }
}

/// ⛔ Un jeton posé sur la requête ne suit aucune redirection qui quitte son hôte, ni ne
/// descend en clair. CFNetwork retire déjà l'en-tête posé par requête sur toute redirection ;
/// cette garde ferme la porte même si ce comportement changeait.
final class RedirectionMemeHoteSeulement: NSObject, URLSessionTaskDelegate {
    let hote: String

    init(hote: String) {
        self.hote = hote.lowercased()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              url.user(percentEncoded: true) == nil,
              url.password(percentEncoded: true) == nil,
              url.host(percentEncoded: true)?.lowercased() == hote
        else {
            Journal.donnees.notice("Redirection refusée hors de \(self.hote) (statut \(response.statusCode))")
            return nil
        }
        return request
    }
}

/// Les proxies rendent des dates ISO 8601, avec ou sans millisecondes ; une API peut
/// rendre un epoch en secondes ou en millisecondes. Un seul décodeur les accepte
/// toutes plutôt que d'abandonner une réponse entière sur une variante de format.
struct Horodatage: Decodable, Sendable, Equatable {
    let date: Date?

    init(date: Date?) { self.date = date }

    init(from decodeur: Decoder) throws {
        let valeur = try decodeur.singleValueContainer()
        if valeur.decodeNil() {
            date = nil
        } else if let texte = try? valeur.decode(String.self) {
            date = Horodatage.analyser(texte)
        } else if let nombre = try? valeur.decode(Double.self) {
            date = Horodatage.analyser(epoch: nombre)
        } else {
            date = nil
        }
    }

    static func analyser(_ texte: String) -> Date? {
        let coupe = texte.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !coupe.isEmpty else { return nil }
        if let avecFraction = try? Date(coupe, strategy: .iso8601.time(includingFractionalSeconds: true)) {
            return avecFraction
        }
        if let sansFraction = try? Date(coupe, strategy: .iso8601) {
            return sansFraction
        }
        if let nombre = Double(coupe) { return analyser(epoch: nombre) }
        return nil
    }

    /// Au-delà de cette borne, la valeur ne peut plus être des secondes : elle
    /// placerait la date en l'an 5000. C'est le seul discriminant fiable.
    ///
    /// ⛔ Un infini n'est pas une date. `Double("inf")` en accepte l'écriture, et la
    /// `Date` qui en naîtrait serait plus fraîche que toute mesure ultérieure — donc
    /// définitivement affichée.
    static func analyser(epoch nombre: Double) -> Date? {
        guard nombre.isFinite, nombre > 0 else { return nil }
        return Date(timeIntervalSince1970: nombre > 100_000_000_000 ? nombre / 1000 : nombre)
    }
}

enum Texte {
    /// Réduit un nom à ses lettres et chiffres, accents repliés : « Compte Pro · Max »
    /// et « compte-pro-max » deviennent la même clé de rapprochement.
    static func normaliser(_ valeur: String) -> String {
        valeur.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }
}

/// Une valeur d'un autre type que prévu vaut une absence, sans faire tomber le reste : un
/// élément illisible d'une liste ne coûte que lui-même, et un champ annexe illisible ne coûte
/// pas le bloc qui le porte.
struct Souple<Valeur: Decodable>: Decodable {
    let valeur: Valeur?

    init(from decoder: Decoder) throws {
        valeur = try? decoder.singleValueContainer().decode(Valeur.self)
    }
}

// Après la session réseau : la page « Ce que Quotum lit » cite le numéro de la ligne qui la configure.
extension LectureFichier {
    /// Ce qu'un tirage peut lire au-delà de la première ligne, au plus, avant d'être jeté.
    static let blocPremiereLigne = 512

    /// La première ligne d'un fichier ordinaire, sans son retour ; `nil` si elle dépasse
    /// `octetsMaximum` ou si le fichier finit avant elle. La lecture s'arrête au bloc qui contient le
    /// premier retour : ce qui le suit dans ce bloc, `blocPremiereLigne - 1` octets au plus, est jeté.
    static func premiereLigne(_ url: URL, octetsMaximum: Int) throws(Echec) -> Data? {
        let descripteur = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descripteur >= 0 else {
            throw errno == ENOENT ? .absent : .systeme(errno)
        }
        defer { close(descripteur) }
        var etat = stat()
        guard fstat(descripteur, &etat) == 0 else { throw .systeme(errno) }
        guard etat.st_mode & S_IFMT == S_IFREG else { throw .pasUnFichierOrdinaire }
        return try premiereLigne(octetsMaximum: octetsMaximum) { read(descripteur, $0.baseAddress, $0.count) }
    }

    /// `tirer` remplit le tampon qu'on lui tend et rend le nombre d'octets lus, comme `read`.
    static func premiereLigne(octetsMaximum: Int,
                              tirer: (UnsafeMutableRawBufferPointer) -> Int) throws(Echec) -> Data? {
        var ligne = Data()
        var tampon = [UInt8](repeating: 0, count: blocPremiereLigne)
        while true {
            let voulus = min(tampon.count, max(octetsMaximum, 0) + 1 - ligne.count)
            guard voulus > 0 else { return nil }
            let lus = tampon.withUnsafeMutableBytes { tirer(UnsafeMutableRawBufferPointer(rebasing: $0[0..<voulus])) }
            if lus < 0 {
                if errno == EINTR { continue }
                throw .systeme(errno)
            }
            if lus == 0 { return nil }
            if let fin = tampon[0..<lus].firstIndex(of: UInt8(ascii: "\n")) {
                ligne.append(contentsOf: tampon[0..<fin])
                return ligne
            }
            ligne.append(contentsOf: tampon[0..<lus])
        }
    }
}

/// La file où partent les travaux bloquants. ⚠️ Un travail planifié peut y attendre : ce qui doit
/// valoir à l'instant d'un accès — un consentement — se relit dans le travail même, jamais avant.
struct FileHorsFil: Sendable {
    let planifier: @Sendable (@escaping @Sendable () -> Void) -> Void

    static let systeme = FileHorsFil { DispatchQueue.global(qos: .utility).async(execute: $0) }

    func executer<T: Sendable>(_ travail: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { suite in
            planifier { suite.resume(returning: travail()) }
        }
    }
}
