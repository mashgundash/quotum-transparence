import Foundation

/// Où joindre un proxy. L'URL complète est lue sur disque quand elle y est : le port
/// est choisi au démarrage du proxy et le figer ici ferait mentir l'app le jour où
/// il change.
struct SourceProxy: Sendable {
    var fournisseur: Fournisseur
    var fichierURL: URL?
    var fichierSecret: URL
    var baseParDefaut: String

    static var claude: SourceProxy {
        let accueil = FileManager.default.homeDirectoryForCurrentUser
        return SourceProxy(fournisseur: .claude,
                           fichierURL: accueil.appendingPathComponent(".claude/cc-proxy.url"),
                           fichierSecret: accueil.appendingPathComponent(".claude/cc-proxy.secret"),
                           baseParDefaut: "http://127.0.0.1:8787")
    }

    static var codex: SourceProxy {
        let accueil = FileManager.default.homeDirectoryForCurrentUser
        return SourceProxy(fournisseur: .chatgpt,
                           fichierURL: accueil.appendingPathComponent(".codex-comptes/codex-proxy.url"),
                           fichierSecret: accueil.appendingPathComponent(".codex-comptes/codex-proxy.secret"),
                           baseParDefaut: "http://127.0.0.1:8788")
    }

    /// Ce que le disque permet de conclure sur l'adresse du statut. Une adresse
    /// introuvable a deux causes opposées : aucun fichier — le proxy n'est pas
    /// installé — ou des fichiers présents dont rien d'exploitable ne sort. Les
    /// confondre ferait passer une configuration cassée pour un choix de son
    /// propriétaire, et personne ne serait prévenu.
    enum Adresse: Sendable, Equatable {
        case joignable(URL)
        case inexploitable
        case absente
    }

    func adresseStatut() -> Adresse {
        if let base = SourceProxy.premiereLigne(de: fichierURL) {
            if let url = SourceProxy.adresseLocale(SourceProxy.sansBarreFinale(base) + "/_proxy/status") {
                return .joignable(url)
            }
            Journal.donnees.notice("Proxy \(fournisseur.rawValue, privacy: .public) : adresse refusée, hors boucle locale")
        }
        if let secret = SourceProxy.premiereLigne(de: fichierSecret),
           let url = SourceProxy.adresseLocale(SourceProxy.sansBarreFinale(baseParDefaut) + "/" + secret + "/_proxy/status") {
            return .joignable(url)
        }
        return existe(fichierURL) || existe(fichierSecret) ? .inexploitable : .absente
    }

    /// Les trois écritures admises de la boucle locale. Une liste de refus laisserait
    /// toujours passer la forme qu'on n'a pas prévue ; celle-ci nomme ce qu'elle
    /// accepte, et refuse le reste sans avoir à l'imaginer.
    private static let hotesDeLaBoucleLocale: Set<String> = ["127.0.0.1", "::1", "localhost"]

    /// L'adresse, à la seule condition qu'elle désigne un des proxies locaux. Elle
    /// vient de la première ligne d'un fichier du disque : rien dans `URL(string:)`
    /// n'empêche cette ligne de nommer une machine distante, à qui partirait alors le
    /// secret que porte le chemin.
    static func adresseLocale(_ texte: String) -> URL? {
        guard let url = URL(string: texte),
              url.scheme?.lowercased() == "http",
              url.user(percentEncoded: true) == nil,
              url.password(percentEncoded: true) == nil,
              // Le chemin du statut n'en porte ni l'un ni l'autre, et les accepter
              // ferait viser autre chose que ce que la concaténation a composé.
              url.query(percentEncoded: true) == nil,
              url.fragment(percentEncoded: true) == nil,
              let hote = url.host(percentEncoded: true),
              // Un hôte percent-encodé se lit différemment selon qui le décode ; le
              // refuser supprime l'écart entre ce qui est validé ici et ce que la
              // pile réseau joindra.
              hote == url.host(percentEncoded: false),
              hotesDeLaBoucleLocale.contains(hote.lowercased()),
              // Mesuré le 2026-09-18 : `URL` accepte `:99999` et rend bien 99999.
              // La plage n'est donc vérifiée nulle part en amont.
              url.port.map((1...65_535).contains) ?? true
        else { return nil }
        return url
    }

    static func estLocale(_ url: URL?) -> Bool {
        guard let url else { return false }
        return adresseLocale(url.absoluteString) != nil
    }

    private func existe(_ fichier: URL?) -> Bool {
        guard let fichier else { return false }
        return FileManager.default.fileExists(atPath: fichier.path)
    }

    /// Le fichier d'URL de cc-proxy porte le PID sur une seconde ligne : seule la
    /// première compte.
    static func premiereLigne(de fichier: URL?) -> String? {
        guard let fichier,
              let contenu = try? String(contentsOf: fichier, encoding: .utf8) else { return nil }
        let ligne = contenu.split(separator: "\n", omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return ligne.isEmpty ? nil : ligne
    }

    static func sansBarreFinale(_ valeur: String) -> String {
        valeur.hasSuffix("/") ? String(valeur.dropLast()) : valeur
    }
}

/// Ce qu'une lecture de proxy a pu établir. Un proxy **absent** et un proxy **muet**
/// se ressemblaient jusqu'ici — les deux rendaient `nil` — et le panneau avertissait
/// dans les deux cas : sur une machine où ces proxies ne sont pas installés, il
/// reprochait en permanence son silence à une brique qui n'existe pas.
enum LectureProxy: Sendable, Equatable {
    case etat(EtatProxy)
    /// Ni fichier d'URL ni fichier de secret : ce proxy n'est pas installé sur cette
    /// machine. Rien à signaler, rien à attendre de lui.
    case absent
    /// Installé — ses fichiers sont là — mais il n'a pas répondu, pas en JSON
    /// exploitable, ou ses fichiers ne donnent aucune adresse. Là, il y a quelque
    /// chose à dire.
    case muet

    var etat: EtatProxy? {
        if case .etat(let etat) = self { return etat } else { return nil }
    }

    var estMuet: Bool { self == .muet }
}

/// CFNetwork suit les redirections de lui-même. L'adresse du proxy est contrôlée
/// avant l'appel, mais un `302` la remplacerait après coup : la cible passe donc par
/// la même liste, sans quoi l'app quitterait la boucle locale sur la seule parole de
/// ce qui écoute sur ce port.
final class RedirectionLocaleSeulement: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        SourceProxy.estLocale(request.url) ? request : nil
    }
}

enum LecteurProxy {
    static func requete(url: URL, delai: TimeInterval) -> URLRequest {
        var requete = URLRequest(url: url)
        requete.timeoutInterval = delai
        requete.httpMethod = "GET"
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        return requete
    }

    /// Les comptes d'un proxy qui ne répond pas restent simplement à l'état inconnu :
    /// ce n'est pas une panne de l'app.
    static func lire(_ source: SourceProxy,
                     session: URLSession = Reseau.session,
                     delai: TimeInterval = 1.5) async -> LectureProxy {
        let url: URL
        switch await HorsFil.executer({ source.adresseStatut() }) {
        case .joignable(let joignable):
            url = joignable
        case .absente:
            Journal.donnees.debug("Proxy \(source.fournisseur.rawValue, privacy: .public) : aucun fichier de configuration")
            return .absent
        case .inexploitable:
            Journal.donnees.notice("Proxy \(source.fournisseur.rawValue, privacy: .public) : configuration présente mais inexploitable")
            return .muet
        }
        do {
            let (donnees, reponse) = try await session.data(for: LecteurProxy.requete(url: url, delai: delai),
                                                            delegate: RedirectionLocaleSeulement())
            guard let http = reponse as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
                Journal.donnees.notice("Proxy \(source.fournisseur.rawValue, privacy: .public) : statut HTTP \(code)")
                return .muet
            }
            return ReponseProxy.decoder(donnees).map(LectureProxy.etat) ?? .muet
        } catch {
            Journal.donnees.debug("Proxy \(source.fournisseur.rawValue, privacy: .public) injoignable")
            return .muet
        }
    }
}
