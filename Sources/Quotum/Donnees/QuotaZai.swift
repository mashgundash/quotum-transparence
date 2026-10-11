import Foundation

/// Ce qu'un relevé de Z.ai établit. La réponse ne nomme personne : la ligne garde un nom de
/// repli.
struct MesureZai: Sendable, Equatable {
    /// De la plus courte à la plus longue ; vide quand aucune limite ne se lit — jamais une
    /// grille inventée.
    var quota: Quota
    var mesureA: Date
    /// `data.level`, tel que publié (`lite`, `pro`…).
    var niveau: String?
}

enum ReleveZai: Sendable, Equatable {
    case releve(MesureZai)
    /// `code 500` dans un 200 : la clé est reconnue, le compte n'a pas de forfait de codage.
    case sansForfait
    /// 401 ou 403 : clé révoquée, expirée ou mal copiée.
    case cleRefusee
    /// Réseau, redirection refusée, 429, 5xx, erreur dans un 200, corps illisible : rien n'est
    /// établi.
    case indetermine
    /// Aucune clé collée dans Quotum pour cet outil : rien n'est parti.
    case sansCle
}

/// Relevé du forfait de codage de Z.ai par `GET /api/monitor/usage/quota/limit`, avec la clé que
/// l'utilisateur a collée.
///
/// ⚠️ **Aucune durée n'est publiée.** La sorte se lit dans le couple `unit` × `number` — 3 × 5,
/// les heures, et 6 × 1, la semaine, concordent chez trois lecteurs tiers ; le code du mois, non
/// (5 chez deux, 7 chez le troisième). Tout autre couple reste `.inconnue`, sous un nom brut, et
/// `duree` reste `nil` : la projection prend la durée nominale de la sorte.
enum QuotaZai {
    static let hoteInternational = "api.z.ai"
    static let hoteChine = "open.bigmodel.cn"
    /// ⛔ Les deux seuls hôtes qui reçoivent la clé.
    static let hotesAdmis: Set<String> = [hoteInternational, hoteChine]
    static let chemin = "/api/monitor/usage/quota/limit"
    /// L'app s'annonce sous son propre nom, jamais sous celui d'un client officiel.
    static let agent = "Quotum"

    static func hote(_ region: RegionCleOutil) -> String {
        switch region {
        case .internationale: hoteInternational
        case .chine: hoteChine
        }
    }

    enum ReponseAPI: Sendable, Equatable {
        case donnees(Data)
        case cleRefusee
        case echec
    }

    // MARK: - Appel

    static func relever(cle: CleOutil, region: RegionCleOutil, session: URLSession, delai: TimeInterval) async -> ReleveZai {
        let reponse = await charger(cle: cle, region: region, session: session, delai: delai)
        return conclure(reponse, mesureA: Date())
    }

    static func conclure(_ reponse: ReponseAPI, mesureA: Date) -> ReleveZai {
        switch reponse {
        case .cleRefusee: .cleRefusee
        case .echec: .indetermine
        case .donnees(let donnees): analyser(donnees, mesureA: mesureA)
        }
    }

    /// Les deux adresses, écrites en entier : c'est ce que la page « Ce que Quotum lit » cite, et
    /// ce qu'une recherche d'adresses dans les sources doit trouver.
    static let adresseInternationale = "https://api.z.ai/api/monitor/usage/quota/limit"
    static let adresseChine = "https://open.bigmodel.cn/api/monitor/usage/quota/limit"

    /// `nil` pour tout hôte hors de `hotesAdmis` : la clé ne part que vers l'un des deux.
    static func adresse(hote: String) -> URL? {
        let texte: String
        switch hote {
        case hoteInternational: texte = adresseInternationale
        case hoteChine: texte = adresseChine
        default: return nil
        }
        guard let url = URL(string: texte), url.scheme == "https", url.host() == hote, url.path() == chemin else {
            return nil
        }
        return url
    }

    /// ⚠️ L'`Authorization` se pose **sur la requête**, jamais dans la configuration de
    /// session : CFNetwork rejoue celle-ci sur la cible d'une redirection, autre hôte compris.
    static func requete(cle: CleOutil, region: RegionCleOutil, delai: TimeInterval) -> URLRequest? {
        guard let url = adresse(hote: hote(region)) else { return nil }
        var requete = URLRequest(url: url)
        requete.httpMethod = "GET"
        requete.timeoutInterval = delai
        requete.setValue("Bearer \(cle.valeur)", forHTTPHeaderField: "Authorization")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue(agent, forHTTPHeaderField: "User-Agent")
        return requete
    }

    private static func charger(cle: CleOutil, region: RegionCleOutil, session: URLSession,
                                delai: TimeInterval) async -> ReponseAPI {
        guard let requete = requete(cle: cle, region: region, delai: delai) else { return .echec }
        do {
            let (donnees, reponse) = try await session.data(for: requete,
                                                            delegate: RedirectionMemeHoteSeulement(hote: hote(region)))
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            if code != 200 { Journal.donnees.notice("Quota Z.ai : statut HTTP \(code)") }
            return interpreter(code: code, donnees: donnees)
        } catch {
            Journal.donnees.debug("Quota Z.ai : \(hote(region)) injoignable")
            return .echec
        }
    }

    /// 401 et 403 : la clé est refusée. Tout le reste — 404, 429, 5xx, une redirection
    /// refusée — n'établit rien.
    static func interpreter(code: Int, donnees: Data) -> ReponseAPI {
        switch code {
        case 200: .donnees(donnees)
        case 401, 403: .cleRefusee
        default: .echec
        }
    }

    // MARK: - Analyses pures

    /// Un nombre JSON fini, et rien d'autre : une chaîne n'est pas une mesure.
    private struct Nombre: Decodable {
        let valeur: Double?

        init(from decodeur: Decoder) throws {
            let lu = try? decodeur.singleValueContainer().decode(Double.self)
            valeur = lu.flatMap { $0.isFinite ? $0 : nil }
        }
    }

    private struct Limite: Decodable {
        var type: String?
        var unite: Int?
        var nombre: Int?
        var pourcentage: Nombre?
        var echeance: Nombre?

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            type = (try? c.decodeIfPresent(String.self, forKey: .type))
                ?? (try? c.decodeIfPresent(String.self, forKey: .nom))
            unite = try? c.decodeIfPresent(Int.self, forKey: .unite)
            nombre = try? c.decodeIfPresent(Int.self, forKey: .nombre)
            pourcentage = try? c.decodeIfPresent(Nombre.self, forKey: .pourcentage)
            echeance = try? c.decodeIfPresent(Nombre.self, forKey: .echeance)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case nom = "name"
            case unite = "unit"
            case nombre = "number"
            case pourcentage = "percentage"
            case echeance = "nextResetTime"
        }
    }

    private struct Donnees: Decodable {
        var limites: [Souple<Limite>]
        var niveau: String?

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            limites = try c.decode([Souple<Limite>].self, forKey: .limites)
            niveau = try? c.decodeIfPresent(String.self, forKey: .niveau)
        }

        enum CodingKeys: String, CodingKey {
            case limites = "limits"
            case niveau = "level"
        }
    }

    private struct Enveloppe: Decodable {
        var code: Int?
        var succes: Bool?
        var donnees: Souple<Donnees>?

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            code = try? c.decodeIfPresent(Int.self, forKey: .code)
            succes = try? c.decodeIfPresent(Bool.self, forKey: .succes)
            donnees = try? c.decodeIfPresent(Souple<Donnees>.self, forKey: .donnees)
        }

        enum CodingKeys: String, CodingKey {
            case code
            case succes = "success"
            case donnees = "data"
        }
    }

    /// Les limites que Quotum montre : les jetons, et les crédits qui les remplacent sur
    /// certaines formules. `TIME_LIMIT` décompte les appels d'outils MCP, pas le forfait.
    static let typesLus: Set<String> = ["TOKENS_LIMIT", "CREDIT_LIMIT"]

    static func analyser(_ donnees: Data, mesureA: Date) -> ReleveZai {
        guard let enveloppe = try? JSONDecoder().decode(Enveloppe.self, from: donnees) else {
            Journal.donnees.notice("Quota Z.ai : réponse illisible")
            return .indetermine
        }
        // Un 200 peut porter une erreur : le `code` et `success` de l'enveloppe la disent.
        if let code = enveloppe.code, code != 200 {
            if code == 500 { return .sansForfait }
            Journal.donnees.notice("Quota Z.ai : erreur \(code) dans un 200")
            return .indetermine
        }
        if enveloppe.succes == false {
            Journal.donnees.notice("Quota Z.ai : success à false dans un 200")
            return .indetermine
        }
        guard enveloppe.code == 200 || enveloppe.succes == true,
              let lues = enveloppe.donnees?.valeur else {
            Journal.donnees.notice("Quota Z.ai : réponse sans limites lisibles")
            return .indetermine
        }
        let fenetres = lues.limites.compactMap { $0.valeur }.compactMap(fenetre)
        let niveau = lues.niveau?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .releve(MesureZai(quota: Quota(ordonner(fenetres)),
                                 mesureA: mesureA,
                                 niveau: niveau?.isEmpty == false ? niveau : nil))
    }

    /// ⛔ `percentage` est un **consommé**. Négatif, il contredit la réponse : aucune fenêtre
    /// plutôt qu'une grille pleine. Au-delà de 100, c'est une mesure, que `Fenetre` borne.
    private static func fenetre(_ limite: Limite) -> Fenetre? {
        guard let type = limite.type, typesLus.contains(type),
              let utilisation = limite.pourcentage?.valeur, utilisation >= 0 else { return nil }
        let recharge = limite.echeance?.valeur.flatMap(dateMillisecondes)
        switch (limite.unite, limite.nombre) {
        case (3, 5):
            return Fenetre.cinqHeures(utilisation: utilisation, seRechargeA: recharge)
        case (6, 1):
            return Fenetre.septJours(utilisation: utilisation, seRechargeA: recharge)
        case (let unite, let nombre):
            let nom = "Z.ai (unité \(unite.map(String.init) ?? "?") × \(nombre.map(String.init) ?? "?"))"
            return Fenetre(libelle: nom, sorte: .inconnue, utilisation: utilisation, seRechargeA: recharge)
        }
    }

    /// Les échéances admises, en millisecondes : du 1er janvier 2000 inclus au 1er janvier 2100
    /// exclu. Une borne finie hors de cette plage n'est pas une date : ni échéance ni durée.
    static let plageMillisecondes: Range<Double> = 946_684_800_000 ..< 4_102_444_800_000

    /// `nextResetTime` est en **millisecondes** depuis l'époque Unix.
    static func dateMillisecondes(_ valeur: Double) -> Date? {
        guard valeur.isFinite, plageMillisecondes.contains(valeur) else { return nil }
        return Date(timeIntervalSince1970: valeur / 1000)
    }

    /// Faute de durée publiée, l'ordre vient de la sorte : la 5 h, la semaine, puis ce qu'on ne
    /// sait pas classer — qui ne devient jamais la ligne principale tant qu'une fenêtre connue
    /// existe. Stable : à sorte égale, l'ordre de la réponse.
    static func ordonner(_ fenetres: [Fenetre]) -> [Fenetre] {
        func rang(_ sorte: Fenetre.Sorte) -> Int {
            switch sorte {
            case .cinqHeures: 0
            case .septJours: 1
            default: 2
            }
        }
        return fenetres.enumerated()
            .sorted { (rang($0.element.sorte), $0.offset) < (rang($1.element.sorte), $1.offset) }
            .map(\.element)
    }
}
