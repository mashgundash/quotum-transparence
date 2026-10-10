import Foundation

/// Ce qu'un relevé de Kimi Code établit. La réponse ne nomme personne et le fichier du CLI
/// ne porte aucun courriel : la ligne garde un nom de repli.
struct MesureKimi: Sendable, Equatable {
    var quota: Quota
    var mesureA: Date
    /// L'échéance du jeton qui a servi, lue dans le fichier du CLI quand il la porte.
    var jetonExpireA: Date?
}

/// Ce que la lecture du fichier du CLI puis l'appel à `/coding/v1/usages` ont pu établir.
enum ReleveKimi: Sendable, Equatable {
    case releve(MesureKimi)
    /// Le jeton du CLI a passé son échéance : il n'est pas parti, aucune requête n'a eu
    /// lieu. Seul le CLI `kimi` le renouvelle — Quotum ne touche jamais au jeton de
    /// rafraîchissement, que Kimi fait tourner.
    case jetonExpire(expireA: Date)
    /// Jeton encore valable selon le fichier, mais refusé (401).
    case reconnexionNecessaire
    /// La route refuse la requête de Quotum (400, 403) alors que le jeton est valable. Elle
    /// peut attendre les en-têtes d'identité du CLI officiel, que Quotum n'envoie pas : la
    /// mesure est indisponible, et une reconnexion n'y changerait rien.
    case mesureRefusee
    /// L'appel n'a rien établi — réseau coupé, 429, 5xx, corps illisible, fichier illisible.
    case indetermine
    /// Aucun jeton Kimi Code sur cette machine : rien à relever.
    case aucun
}

/// Le jeton que le CLI `kimi` dépose sur le disque. Il sert à un appel et n'est ni copié,
/// ni journalisé, ni conservé au-delà du relevé.
struct JetonKimi: Sendable, Equatable {
    let valeur: String
    /// `nil` quand le fichier ne porte aucune échéance : c'est alors le serveur qui tranche.
    let expireA: Date?
}

enum LectureKimi: Sendable, Equatable {
    case jeton(JetonKimi)
    /// Aucun fichier, ou un fichier lisible sans jeton.
    case absent
    /// Lecture empêchée — droits refusés, contenu inexploitable, échéance illisible,
    /// dossier déclaré relatif, ou CLI réglé sur un autre hôte que `api.kimi.com`.
    case empechee
}

/// ⛔ **Lecture seule.** Le fichier n'est jamais écrit, et son `refresh_token` n'est jamais
/// lu : Kimi le fait tourner à chaque renouvellement, et le consommer ici déconnecterait le CLI.
enum IdentifiantsKimi {
    static let dossierParDefaut = ".kimi-code"
    static let cheminRelatif = "credentials/kimi-code.json"
    /// Déplace tout le dossier du CLI, fichier d'identifiants compris.
    static let variableDossier = "KIMI_CODE_HOME"
    /// Posées, elles disent que le CLI parle à un autre hôte : son jeton n'est pas destiné à
    /// `api.kimi.com`, et il n'y part pas.
    static let variablesAutreHote = ["KIMI_CODE_BASE_URL", "KIMI_CODE_OAUTH_HOST", "KIMI_OAUTH_HOST"]

    /// `nil` pour un `KIMI_CODE_HOME` relatif : il se résout contre le dossier courant du CLI,
    /// que Quotum ne connaît pas, et lire un autre fichier que le sien mesurerait un autre compte.
    static func fichier(accueil: URL, environnement: [String: String]) -> URL? {
        guard let declare = nonVide(environnement[variableDossier]) else {
            return accueil.appendingPathComponent(dossierParDefaut, isDirectory: true)
                .appendingPathComponent(cheminRelatif)
        }
        let developpe = (declare as NSString).expandingTildeInPath
        guard developpe.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: developpe, isDirectory: true).appendingPathComponent(cheminRelatif)
    }

    static func jeton(accueil: URL, environnement: [String: String]) async -> LectureKimi {
        if variablesAutreHote.contains(where: { nonVide(environnement[$0]) != nil }) {
            Journal.donnees.notice("Kimi Code : CLI réglé sur un autre hôte, relevé abandonné")
            return .empechee
        }
        guard let cible = fichier(accueil: accueil, environnement: environnement) else {
            Journal.donnees.notice("Kimi Code : \(variableDossier) relatif, relevé abandonné")
            return .empechee
        }
        return await HorsFil.executer { lire(cible) }
    }

    /// ⚠️ Jamais `Data(contentsOf:)` : un tube nommé à ce chemin la ferait attendre sans fin.
    static func lire(_ url: URL) -> LectureKimi {
        do {
            return classer(try LectureFichier.lire(url))
        } catch .absent {
            return .absent
        } catch {
            Journal.donnees.notice("Kimi Code : fichier d'identifiants illisible (\(String(describing: error)))")
            return .empechee
        }
    }

    private struct Contenu: Decodable {
        var accessToken: String?
        var echeance: Echeance

        enum Echeance: Equatable {
            case absente
            case lue(Date)
            case illisible
        }

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            accessToken = try? c.decode(String.self, forKey: .accessToken)
            if !c.contains(.expiresAt) || (try? c.decodeNil(forKey: .expiresAt)) == true {
                echeance = .absente
            } else if let date = (try? c.decode(Horodatage.self, forKey: .expiresAt))?.date {
                echeance = .lue(date)
            } else {
                echeance = .illisible
            }
        }

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresAt = "expires_at"
        }
    }

    static func classer(_ donnees: Data) -> LectureKimi {
        guard let contenu = try? JSONDecoder().decode(Contenu.self, from: donnees) else {
            Journal.donnees.notice("Kimi Code : fichier d'identifiants lu mais inexploitable")
            return .empechee
        }
        guard let valeur = nonVide(contenu.accessToken) else { return .absent }
        switch contenu.echeance {
        case .absente: return .jeton(JetonKimi(valeur: valeur, expireA: nil))
        case .lue(let date): return .jeton(JetonKimi(valeur: valeur, expireA: date))
        // Une échéance publiée qu'on ne sait pas lire ne laisse pas partir le jeton : rien
        // ne dit qu'il vaut encore.
        case .illisible:
            Journal.donnees.notice("Kimi Code : échéance du jeton illisible, relevé abandonné")
            return .empechee
        }
    }

    private static func nonVide(_ valeur: String?) -> String? {
        guard let coupe = valeur?.trimmingCharacters(in: .whitespacesAndNewlines), !coupe.isEmpty else {
            return nil
        }
        return coupe
    }
}

/// Relevé direct du quota de Kimi Code par `GET api.kimi.com/coding/v1/usages`.
///
/// ⛔ **Aucun en-tête `X-Msh-*`.** Le CLI officiel s'annonce par eux (plateforme, appareil,
/// identifiant d'appareil) ; les reprendre serait se faire passer pour lui. La requête porte
/// le jeton, `Accept` et le `User-Agent` « Quotum », rien d'autre. Si la route les exige,
/// elle refuse, et la ligne dit que la mesure est indisponible.
///
/// ⚠️ Le jeton du CLI dure environ un quart d'heure et Quotum ne le renouvelle jamais : une
/// mesure n'existe que si `kimi` a servi récemment.
enum QuotaKimi {
    static let agent = "Quotum"
    static let hote = "api.kimi.com"
    static let adresse = "https://api.kimi.com/coding/v1/usages"
    /// Un jeton qui expire dans la minute ne part pas : il serait périmé à l'arrivée.
    static let margeExpiration: TimeInterval = 60

    enum ReponseAPI: Sendable, Equatable {
        case donnees(Data)
        case jetonRefuse
        case refusee
        case echec
    }

    /// ⛔ Aucune valeur par défaut : le dossier d'accueil, l'environnement, la session et
    /// l'horloge sont ceux que l'appelant désigne, et un test ne peut pas retomber sur le
    /// poste réel faute de les avoir passés.
    static func relever(accueil: URL,
                        environnement: [String: String],
                        session: URLSession,
                        maintenant: Date,
                        delai: TimeInterval) async -> ReleveKimi {
        switch await IdentifiantsKimi.jeton(accueil: accueil, environnement: environnement) {
        case .jeton(let jeton):
            return await relever(jeton: jeton, session: session, maintenant: maintenant, delai: delai)
        case .absent:
            return .aucun
        case .empechee:
            return .indetermine
        }
    }

    static func relever(jeton: JetonKimi,
                        session: URLSession,
                        maintenant: Date,
                        delai: TimeInterval) async -> ReleveKimi {
        if let expireA = jeton.expireA, expire(expireA, maintenant: maintenant) {
            return .jetonExpire(expireA: expireA)
        }
        let reponse = await charger(jeton: jeton, session: session, delai: delai)
        return conclure(reponse, mesureA: maintenant, jetonExpireA: jeton.expireA)
    }

    static func expire(_ expireA: Date, maintenant: Date) -> Bool {
        expireA <= maintenant.addingTimeInterval(margeExpiration)
    }

    static func conclure(_ reponse: ReponseAPI, mesureA: Date, jetonExpireA: Date?) -> ReleveKimi {
        switch reponse {
        case .jetonRefuse: return .reconnexionNecessaire
        case .refusee: return .mesureRefusee
        case .echec: return .indetermine
        case .donnees(let donnees):
            guard var mesure = decoder(donnees, mesureA: mesureA) else { return .indetermine }
            mesure.jetonExpireA = jetonExpireA
            return .releve(mesure)
        }
    }

    /// ⚠️ L'`Authorization` se pose **sur la requête**, jamais dans la configuration de
    /// session : CFNetwork rejoue celle-ci sur la cible d'une redirection, autre hôte compris.
    static func requete(jeton: JetonKimi, delai: TimeInterval) -> URLRequest? {
        guard let url = URL(string: adresse) else { return nil }
        var requete = URLRequest(url: url)
        requete.httpMethod = "GET"
        requete.timeoutInterval = delai
        requete.setValue("Bearer \(jeton.valeur)", forHTTPHeaderField: "Authorization")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue(agent, forHTTPHeaderField: "User-Agent")
        return requete
    }

    private static func charger(jeton: JetonKimi,
                                session: URLSession,
                                delai: TimeInterval) async -> ReponseAPI {
        guard let requete = requete(jeton: jeton, delai: delai) else { return .echec }
        do {
            let (donnees, reponse) = try await session.data(for: requete,
                                                            delegate: RedirectionMemeHoteSeulement(hote: hote))
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            if code != 200 { Journal.donnees.notice("Quota Kimi Code : statut HTTP \(code)") }
            return interpreter(code: code, donnees: donnees)
        } catch {
            Journal.donnees.debug("Quota Kimi Code : api.kimi.com injoignable")
            return .echec
        }
    }

    /// Le jeton est valable selon son échéance quand il part : un 401 dit qu'il a été révoqué,
    /// un 400 ou un 403 que la route refuse la requête telle que Quotum la fait.
    static func interpreter(code: Int, donnees: Data) -> ReponseAPI {
        switch code {
        case 200: .donnees(donnees)
        case 401: .jetonRefuse
        case 400, 403: .refusee
        default: .echec
        }
    }

    // MARK: - Analyses pures

    /// Chaque bloc se lit seul : un bloc illisible ne fait pas tomber ses voisins.
    private struct Reponse: Decodable {
        var reserves: Reserves?
        var hebdomadaire: Compteur?
        var limites: [Limite]?

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            reserves = try? c.decode(Reserves.self, forKey: .reserves)
            hebdomadaire = try? c.decode(Compteur.self, forKey: .hebdomadaire)
            limites = (try? c.decode([Souple<Limite>].self, forKey: .limites))?.compactMap(\.valeur)
        }

        enum CodingKeys: String, CodingKey {
            case reserves = "usages"
            case hebdomadaire = "usage"
            case limites = "limits"
        }
    }

    /// La forme actuelle : un rapport consommé (0…1) par fenêtre, nommée par sa clé.
    private struct Reserves: Decodable {
        var cinqHeures: Rapport?
        var septJours: Rapport?
        var mois: Rapport?

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            cinqHeures = try? c.decode(Rapport.self, forKey: .cinqHeures)
            septJours = try? c.decode(Rapport.self, forKey: .septJours)
            mois = try? c.decode(Rapport.self, forKey: .mois)
        }

        enum CodingKeys: String, CodingKey {
            case cinqHeures = "limit_5h"
            case septJours = "limit_7d"
            case mois = "limit_month_total"
        }
    }

    private struct Rapport: Decodable {
        var consomme: Double?
        var recharge: Date?

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: Cle.self)
            consomme = (try? c.decode(Nombre.self, forKey: Cle("used_ratio")))?.valeur
            recharge = QuotaKimi.date(c, ["reset_time", "reset_at", "resetTime", "resetAt"])
        }
    }

    /// La forme antérieure, en nombres de requêtes publiés en chaînes.
    private struct Compteur: Decodable {
        var limite: Double?
        var consomme: Double?
        var restant: Double?
        var recharge: Date?

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: Cle.self)
            limite = (try? c.decode(Nombre.self, forKey: Cle("limit")))?.valeur
            consomme = (try? c.decode(Nombre.self, forKey: Cle("used")))?.valeur
            restant = (try? c.decode(Nombre.self, forKey: Cle("remaining")))?.valeur
            recharge = QuotaKimi.date(c, ["resetTime", "resetAt", "reset_time", "reset_at"])
        }

        /// `used` fait foi ; `remaining` ne sert qu'en son absence, et c'est ici seulement
        /// qu'un restant s'inverse.
        var utilisation: Double? {
            guard let limite, limite > 0 else { return nil }
            let lu = consomme ?? restant.map { limite - $0 }
            guard let lu, lu >= 0 else { return nil }
            return lu / limite * 100
        }
    }

    private struct Limite: Decodable {
        var duree: TimeInterval?
        var detail: Compteur?

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: Cle.self)
            detail = try? c.decode(Compteur.self, forKey: Cle("detail"))
            guard let fenetre = try? c.nestedContainer(keyedBy: Cle.self, forKey: Cle("window")),
                  let valeur = (try? fenetre.decode(Nombre.self, forKey: Cle("duration")))?.valeur,
                  valeur > 0,
                  let unite = try? fenetre.decode(String.self, forKey: Cle("timeUnit")),
                  let secondes = Self.secondes[unite] else { return }
            duree = valeur * secondes
        }

        private static let secondes: [String: TimeInterval] = [
            "TIME_UNIT_SECOND": 1, "TIME_UNIT_MINUTE": 60, "TIME_UNIT_HOUR": 3_600, "TIME_UNIT_DAY": 86_400,
        ]
    }

    private struct Cle: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ nom: String) { stringValue = nom }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Un nombre publié en nombre ou en chaîne. `valeur` vaut `nil` quand il n'est pas fini.
    private struct Nombre: Decodable {
        let valeur: Double?

        init(from decodeur: Decoder) throws {
            let c = try decodeur.singleValueContainer()
            let lu = (try? c.decode(Double.self))
                ?? (try? c.decode(String.self)).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            valeur = lu.flatMap { $0.isFinite ? $0 : nil }
        }
    }

    private static func date(_ c: KeyedDecodingContainer<Cle>, _ noms: [String]) -> Date? {
        for nom in noms {
            if let date = (try? c.decode(Horodatage.self, forKey: Cle(nom)))?.date { return date }
        }
        return nil
    }

    private static let cinqHeures: TimeInterval = 5 * 3_600
    private static let septJours: TimeInterval = 7 * 86_400

    /// `nil` seulement pour un corps qui n'est pas l'objet attendu : une page d'erreur servie
    /// en 200, un corps tronqué. Un objet sans fenêtre lisible rend une mesure vide.
    ///
    /// Les rapports priment, fenêtre par fenêtre ; les comptes de requêtes de la forme
    /// antérieure ne comblent que la fenêtre qu'aucun rapport lisible ne donne.
    static func decoder(_ donnees: Data, mesureA: Date) -> MesureKimi? {
        guard let reponse = try? JSONDecoder().decode(Reponse.self, from: donnees) else { return nil }
        let limites = reponse.limites ?? []
        let compteCinqHeures = limites.first { $0.duree == cinqHeures }?.detail
        let compteSeptJours = limites.first { $0.duree == septJours }?.detail ?? reponse.hebdomadaire

        var fenetres: [Fenetre] = []
        if let fenetre = fenetre(reponse.reserves?.cinqHeures, compteCinqHeures,
                                 libelle: Fenetre.libelleCinqHeures, sorte: .cinqHeures) {
            fenetres.append(fenetre)
        }
        if let fenetre = fenetre(reponse.reserves?.septJours, compteSeptJours,
                                 libelle: Fenetre.libelleSeptJours, sorte: .septJours) {
            fenetres.append(fenetre)
        }
        if let fenetre = fenetre(reponse.reserves?.mois, nil, libelle: Fenetre.libelleMois, sorte: .mois) {
            fenetres.append(fenetre)
        }
        return MesureKimi(quota: Quota(fenetres), mesureA: mesureA, jetonExpireA: nil)
    }

    /// ⛔ Un rapport négatif se contredit : le borner à zéro dessinerait une grille pleine.
    /// Au-delà de 1, la valeur reste une mesure et se borne à 100.
    private static func fenetre(_ rapport: Rapport?,
                                _ compte: Compteur?,
                                libelle: String,
                                sorte: Fenetre.Sorte) -> Fenetre? {
        if let rapport, let consomme = rapport.consomme, consomme >= 0,
           let fenetre = Fenetre(libelle: libelle, sorte: sorte, utilisation: consomme * 100,
                                 seRechargeA: rapport.recharge) {
            return fenetre
        }
        guard let compte, let utilisation = compte.utilisation else { return nil }
        return Fenetre(libelle: libelle, sorte: sorte, utilisation: utilisation, seRechargeA: compte.recharge)
    }
}
