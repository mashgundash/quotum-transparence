import Foundation

/// Ce qu'un relevé de l'abonnement ClinePass établit. La réponse ne nomme personne et le
/// fichier d'identifiants n'est lu que pour son jeton : la ligne garde un nom de repli.
struct MesureClinePass: Sendable, Equatable {
    var quota: Quota
    var mesureA: Date = .now
}

/// Même partition que `ReleveCopilot` : un jeton refusé ne dit rien du quota, et une réponse
/// inattendue encore moins.
enum ReleveClinePass: Sendable, Equatable {
    case releve(MesureClinePass)
    /// HTTP 401 ou 403 : la session de Cline ne vaut plus, elle se refait par `cline auth`.
    case reconnexionNecessaire
    /// Réseau coupé, redirection refusée, 429, 5xx, statut inattendu, corps illisible ou
    /// `success` qui n'est pas `true`.
    case indetermine
    /// Aucune session Cline sur ce Mac : rien à relever.
    case aucun
}

/// Le jeton de la session que `cline auth` a ouverte. Il sert à un appel et n'est ni copié
/// sur disque, ni journalisé, ni conservé au-delà du relevé.
struct JetonClinePass: Sendable, Equatable {
    /// Toujours préfixé `workos:` : c'est la forme sous laquelle la route l'attend.
    let valeur: String
}

enum LectureClinePass: Sendable, Equatable {
    case jeton(JetonClinePass)
    /// Aucun fichier, ou un fichier lisible sans session de navigateur.
    case absent
    /// Lecture empêchée — droits refusés, contenu inexploitable, jeton présent mais
    /// impropre à partir dans un en-tête.
    case empechee
}

/// La session de Cline, lue dans `providers.json`, à l'entrée `providers.cline.settings`.
///
/// ⛔ **Lecture seule.** Le jeton n'est jamais rafraîchi et le fichier jamais écrit : Cline
/// reste seul maître de sa session.
///
/// ⛔ Seul `auth.accessToken` est lu. Les champs `apiKey` voisins portent une clé d'API de
/// Cline, qui sert aussi à l'inférence : ce n'est pas un identifiant posé par une connexion,
/// et Quotum ne s'en sert pas.
enum IdentifiantsClinePass {
    static let prefixeSession = "workos:"

    static let variableFichier = "CLINE_PROVIDER_SETTINGS_PATH"
    static let variableDonnees = "CLINE_DATA_DIR"
    static let variableDossier = "CLINE_DIR"

    /// Le même ordre que Cline : le fichier désigné, puis `<CLINE_DATA_DIR>/settings`, puis
    /// `<CLINE_DIR>/data/settings`, puis `~/.cline/data/settings`. Une valeur relative est
    /// ignorée : rien ne dit contre quel dossier courant Cline l'aurait résolue.
    static func fichier(environnement: [String: String], accueil: URL) -> URL {
        if let declare = chemin(environnement[variableFichier], accueil: accueil) {
            return declare
        }
        let donnees = chemin(environnement[variableDonnees], accueil: accueil)
            ?? (chemin(environnement[variableDossier], accueil: accueil)
                ?? accueil.appendingPathComponent(".cline", isDirectory: true))
                .appendingPathComponent("data", isDirectory: true)
        return donnees.appendingPathComponent("settings/providers.json")
    }

    private static func chemin(_ brut: String?, accueil: URL) -> URL? {
        guard let valeur = nonVide(brut) else { return nil }
        if valeur == "~" { return accueil }
        if valeur.hasPrefix("~/") { return accueil.appendingPathComponent(String(valeur.dropFirst(2))) }
        guard valeur.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: valeur)
    }

    /// ⛔ Aucun paramètre n'a de valeur par défaut : un test qui en oublierait un ne doit pas
    /// compiler, plutôt que lire le vrai `providers.json`.
    static func jeton(fichier: URL,
                      lireFichier: @escaping @Sendable (URL) throws(LectureFichier.Echec) -> Data) async -> LectureClinePass {
        let lecture = await HorsFil.executer { () -> Result<Data, LectureFichier.Echec> in
            do throws(LectureFichier.Echec) { return .success(try lireFichier(fichier)) } catch { return .failure(error) }
        }
        switch lecture {
        case .success(let donnees):
            return classer(donnees)
        case .failure(.absent):
            return .absent
        case .failure(let echec):
            Journal.donnees.notice("ClinePass : providers.json illisible (\(String(describing: echec)))")
            return .empechee
        }
    }

    /// Un JSON valide sans session conclut — ce Mac n'a pas de connexion à Cline ; un contenu
    /// illisible, ou un jeton d'un autre type qu'une chaîne, ne conclut rien.
    static func classer(_ donnees: Data) -> LectureClinePass {
        guard let racine = try? JSONDecoder().decode(Racine.self, from: donnees) else {
            Journal.donnees.notice("ClinePass : providers.json lu mais inexploitable")
            return .empechee
        }
        switch racine.providers?.cline?.settings?.auth?.accessToken {
        case nil, .absent?:
            return .absent
        case .illisible?:
            Journal.donnees.notice("ClinePass : jeton de session d'un type inattendu")
            return .empechee
        case .texte(let brut)?:
            guard let coupe = nonVide(brut) else { return .absent }
            let valeur = coupe.hasPrefix(prefixeSession) ? coupe : prefixeSession + coupe
            guard valeur.count > prefixeSession.count else { return .absent }
            // Un jeton part dans un en-tête : un blanc ou un caractère de contrôle y casserait
            // la requête, ou y glisserait une ligne de plus.
            guard valeur.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else {
                Journal.donnees.notice("ClinePass : jeton de session impropre à un en-tête")
                return .empechee
            }
            return .jeton(JetonClinePass(valeur: valeur))
        }
    }

    /// Chaque niveau tolère un voisin d'un autre type : seule compte la chaîne qui mène au
    /// jeton, et les entrées des autres fournisseurs ne sont jamais lues.
    private struct Racine: Decodable {
        var providers: Fournisseurs?
        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            providers = try? c.decode(Fournisseurs.self, forKey: .providers)
        }
        enum CodingKeys: String, CodingKey { case providers }
    }

    private struct Fournisseurs: Decodable {
        var cline: Entree?
        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            cline = try? c.decode(Entree.self, forKey: .cline)
        }
        enum CodingKeys: String, CodingKey { case cline }
    }

    private struct Entree: Decodable {
        var settings: Reglages?
        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            settings = try? c.decode(Reglages.self, forKey: .settings)
        }
        enum CodingKeys: String, CodingKey { case settings }
    }

    private struct Reglages: Decodable {
        var auth: Auth?
        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            auth = try? c.decode(Auth.self, forKey: .auth)
        }
        enum CodingKeys: String, CodingKey { case auth }
    }

    private enum Champ: Equatable {
        case absent
        case texte(String)
        case illisible
    }

    private struct Auth: Decodable {
        var accessToken: Champ
        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            if !c.contains(.accessToken) || (try? c.decodeNil(forKey: .accessToken)) == true {
                accessToken = .absent
            } else if let texte = try? c.decode(String.self, forKey: .accessToken) {
                accessToken = .texte(texte)
            } else {
                accessToken = .illisible
            }
        }
        enum CodingKeys: String, CodingKey { case accessToken }
    }

    private static func nonVide(_ valeur: String?) -> String? {
        guard let coupe = valeur?.trimmingCharacters(in: .whitespacesAndNewlines), !coupe.isEmpty else {
            return nil
        }
        return coupe
    }
}

/// Relevé des limites de l'abonnement ClinePass.
///
/// ⚠️ Route interne, non documentée publiquement, et `api.cline.bot` rend 401 sur toute route,
/// inventée comprise : un 401 n'y prouve pas que la route existe encore. Ce lecteur ne couvre
/// que l'abonnement ClinePass — le solde prépayé de Cline n'y figure pas.
enum QuotaClinePass {
    static let hote = "api.cline.bot"
    static let adresse = "https://api.cline.bot/api/v1/users/me/plan/usage-limits"

    /// L'app s'annonce sous son propre nom, jamais sous celui de Cline.
    static let agent = "Quotum"

    static let typeCinqHeures = "five_hour"
    static let typeSemaine = "weekly"
    static let typeMois = "monthly"

    enum ReponseAPI: Sendable, Equatable {
        case donnees(Data)
        case jetonRefuse
        case echec
    }

    /// Le seul point qui branche le réel : chemin de l'utilisateur, disque, session partagée.
    static func relever() async -> ReleveClinePass {
        let fichier = IdentifiantsClinePass.fichier(environnement: ProcessInfo.processInfo.environment,
                                                    accueil: FileManager.default.homeDirectoryForCurrentUser)
        let lecture = await IdentifiantsClinePass.jeton(fichier: fichier,
                                                        lireFichier: { url throws(LectureFichier.Echec) in
                                                            try LectureFichier.lire(url)
                                                        })
        return await relever(lecture: lecture, session: Reseau.session, delai: 8)
    }

    static func relever(lecture: LectureClinePass,
                        session: URLSession,
                        delai: TimeInterval) async -> ReleveClinePass {
        switch lecture {
        case .jeton(let jeton):
            return await relever(jeton: jeton, session: session, delai: delai)
        case .absent:
            return .aucun
        // Une lecture empêchée n'établit pas l'absence de session.
        case .empechee:
            return .indetermine
        }
    }

    static func relever(jeton: JetonClinePass,
                        session: URLSession,
                        delai: TimeInterval) async -> ReleveClinePass {
        conclure(await charger(jeton: jeton, session: session, delai: delai), mesureA: Date())
    }

    static func conclure(_ reponse: ReponseAPI, mesureA: Date) -> ReleveClinePass {
        switch reponse {
        case .jetonRefuse: return .reconnexionNecessaire
        case .echec: return .indetermine
        case .donnees(let donnees):
            guard let quota = decoder(donnees) else { return .indetermine }
            return .releve(MesureClinePass(quota: quota, mesureA: mesureA))
        }
    }

    /// ⚠️ L'`Authorization` se pose **sur la requête**, jamais dans la configuration de
    /// session : CFNetwork rejoue celle-ci sur la cible d'une redirection, autre hôte compris.
    static func requete(jeton: JetonClinePass, delai: TimeInterval) -> URLRequest? {
        guard let url = URL(string: adresse) else { return nil }
        var requete = URLRequest(url: url)
        requete.httpMethod = "GET"
        requete.timeoutInterval = delai
        requete.setValue("Bearer \(jeton.valeur)", forHTTPHeaderField: "Authorization")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue(agent, forHTTPHeaderField: "User-Agent")
        return requete
    }

    private static func charger(jeton: JetonClinePass,
                                session: URLSession,
                                delai: TimeInterval) async -> ReponseAPI {
        guard let requete = requete(jeton: jeton, delai: delai) else { return .echec }
        do {
            let (donnees, reponse) = try await session.data(for: requete,
                                                            delegate: RedirectionMemeHoteSeulement(hote: hote))
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            switch code {
            case 200: break
            case 401, 403: Journal.donnees.notice("Quota ClinePass : session refusée (\(code)), `cline auth` à refaire")
            default: Journal.donnees.notice("Quota ClinePass : statut HTTP \(code)")
            }
            return interpreter(code: code, donnees: donnees)
        } catch {
            Journal.donnees.debug("Quota ClinePass : api.cline.bot injoignable")
            return .echec
        }
    }

    /// 401 et 403 se règlent par une reconnexion. ⛔ Le 429 reste un échec ordinaire : c'est
    /// la route du relevé qui freine, pas le compte qui s'épuise.
    static func interpreter(code: Int, donnees: Data) -> ReponseAPI {
        switch code {
        case 200: .donnees(donnees)
        case 401, 403: .jetonRefuse
        default: .echec
        }
    }

    // MARK: - Analyses pures

    private struct Reponse: Decodable {
        var succes: Bool?
        var donnees: Donnees?
        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            succes = try? c.decode(Bool.self, forKey: .succes)
            donnees = try? c.decode(Donnees.self, forKey: .donnees)
        }
        enum CodingKeys: String, CodingKey {
            case succes = "success"
            case donnees = "data"
        }
    }

    private struct Donnees: Decodable {
        var limites: [Souple<Limite>]
        enum CodingKeys: String, CodingKey { case limites = "limits" }
    }

    /// Chaque champ se lit seul : un `resetsAt` illisible ne coûte que la date, pas la fenêtre.
    private struct Limite: Decodable {
        var type: String?
        var consomme: Double?
        var seRechargeA: Date?
        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            type = try? c.decode(String.self, forKey: .type)
            consomme = try? c.decode(Double.self, forKey: .consomme)
            seRechargeA = (try? c.decode(Horodatage.self, forKey: .seRechargeA))?.date
        }
        enum CodingKeys: String, CodingKey {
            case type
            case consomme = "percentUsed"
            case seRechargeA = "resetsAt"
        }
    }

    /// `nil` seulement pour un corps qui n'est pas la réponse attendue : `success` absent ou
    /// faux, `data.limits` qui n'est pas une liste, page d'erreur servie en 200. Une liste
    /// sans aucune des trois fenêtres connues rend un quota **vide**, jamais une fenêtre à 0 %.
    ///
    /// Les trois fenêtres sont posées de la plus courte à la plus longue, quel que soit l'ordre
    /// de la réponse ; un type inconnu est ignoré, et un type répété ne compte qu'une fois — la
    /// première, sans rien choisir entre deux mesures qui se contredisent.
    ///
    /// ⛔ Aucune durée n'est publiée : « 5 h », « 7 j », « mois » sont des conventions de nom, et
    /// `duree` reste `nil`.
    static func decoder(_ donnees: Data) -> Quota? {
        guard let reponse = try? JSONDecoder().decode(Reponse.self, from: donnees),
              reponse.succes == true,
              let limites = reponse.donnees?.limites else { return nil }
        var parType: [String: Limite] = [:]
        for limite in limites.compactMap(\.valeur) {
            guard let type = limite.type, parType[type] == nil else { continue }
            parType[type] = limite
        }
        let fenetres: [Fenetre?] = [
            parType[typeCinqHeures].flatMap { limite in
                consomme(limite).flatMap { Fenetre.cinqHeures(utilisation: $0, seRechargeA: limite.seRechargeA) }
            },
            parType[typeSemaine].flatMap { limite in
                consomme(limite).flatMap { Fenetre.septJours(utilisation: $0, seRechargeA: limite.seRechargeA) }
            },
            parType[typeMois].flatMap { limite in
                consomme(limite).flatMap {
                    Fenetre(libelle: Fenetre.libelleMois, sorte: .mois, utilisation: $0, seRechargeA: limite.seRechargeA)
                }
            },
        ]
        return Quota(fenetres.compactMap { $0 })
    }

    /// `percentUsed` est un **consommé**, déjà en 0-100. Au-dessus de 100, la fenêtre se borne
    /// à épuisée ; un consommé négatif ne veut rien dire et ne fait pas de fenêtre — le borner
    /// à zéro afficherait une fenêtre intacte que personne n'a constatée.
    private static func consomme(_ limite: Limite) -> Double? {
        guard let valeur = limite.consomme, valeur.isFinite, valeur >= 0 else { return nil }
        return valeur
    }
}
