import Foundation

/// Ce qu'un relevé de MiniMax établit. La réponse ne nomme personne : la ligne garde un nom de
/// repli.
struct MesureMiniMax: Sendable, Equatable {
    /// Toutes les fenêtres de tous les modèles, de la plus courte à la plus longue ; vide quand
    /// aucune ne se lit — jamais une grille inventée.
    var quota: Quota
    var mesureA: Date
}

enum ReleveMiniMax: Sendable, Equatable {
    case releve(MesureMiniMax)
    /// 401 ou 403, ou `base_resp.status_code` 1004 ou 1001 dans un 200 : clé refusée, ou clé
    /// qui n'est pas celle d'un abonnement Token Plan.
    case cleRefusee
    /// Réseau, redirection refusée, 429, 5xx, autre erreur dans un 200, corps illisible : rien
    /// n'est établi.
    case indetermine
    /// Aucune clé collée dans Quotum pour cet outil : rien n'est parti.
    case sansCle
}

/// Relevé de l'abonnement Token Plan de MiniMax par `GET /v1/token_plan/remains`, avec la clé
/// d'abonnement que l'utilisateur a collée.
///
/// ⚠️ Deux pièges du domaine :
/// - **`*_usage_count` est un RESTANT**, malgré son nom. Le consommé se lit d'abord dans
///   `*_remaining_percent` (les compteurs valent 0 sur Token Plan), à défaut dans
///   `(total − restant) / total`.
/// - La fenêtre d'**intervalle** a ses bornes dans `start_time` / `end_time`, la fenêtre
///   **hebdomadaire** dans `weekly_start_time` / `weekly_end_time`. Prendre les premières pour
///   la semaine dirait une recharge hebdomadaire à l'heure de la session.
enum QuotaMiniMax {
    static let hoteInternational = "www.minimax.io"
    static let hoteChine = "api.minimaxi.com"
    /// ⛔ Les deux seuls hôtes qui reçoivent la clé.
    static let hotesAdmis: Set<String> = [hoteInternational, hoteChine]
    static let chemin = "/v1/token_plan/remains"
    /// L'app s'annonce sous son propre nom, jamais sous celui d'un client officiel.
    static let agent = "Quotum"
    /// Les codes de `base_resp` qui refusent la clé : 1004 documenté, 1001 rapporté.
    static let codesCleRefusee: Set<Int> = [1004, 1001]

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

    static func relever(cle: CleOutil, region: RegionCleOutil, session: URLSession,
                        delai: TimeInterval) async -> ReleveMiniMax {
        let reponse = await charger(cle: cle, region: region, session: session, delai: delai)
        return conclure(reponse, mesureA: Date())
    }

    static func conclure(_ reponse: ReponseAPI, mesureA: Date) -> ReleveMiniMax {
        switch reponse {
        case .cleRefusee: .cleRefusee
        case .echec: .indetermine
        case .donnees(let donnees): analyser(donnees, mesureA: mesureA)
        }
    }

    /// Les deux adresses, écrites en entier : c'est ce que la page « Ce que Quotum lit » cite, et
    /// ce qu'une recherche d'adresses dans les sources doit trouver.
    static let adresseInternationale = "https://www.minimax.io/v1/token_plan/remains"
    static let adresseChine = "https://api.minimaxi.com/v1/token_plan/remains"

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
            if code != 200 { Journal.donnees.notice("Quota MiniMax : statut HTTP \(code)") }
            return interpreter(code: code, donnees: donnees)
        } catch {
            Journal.donnees.debug("Quota MiniMax : \(hote(region)) injoignable")
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

    /// Les deux fenêtres d'une entrée, qui ne diffèrent que par le nom de leurs champs.
    enum Voie: CaseIterable {
        case intervalle
        case semaine

        var prefixe: String {
            switch self {
            case .intervalle: "current_interval"
            case .semaine: "current_weekly"
            }
        }

        var debut: String {
            switch self {
            case .intervalle: "start_time"
            case .semaine: "weekly_start_time"
            }
        }

        var fin: String {
            switch self {
            case .intervalle: "end_time"
            case .semaine: "weekly_end_time"
            }
        }
    }

    private struct Cle: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ texte: String) { stringValue = texte }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Ce qu'une voie publie, champ par champ. Un champ d'un autre type vaut une absence.
    private struct VoieLue {
        var presente: Bool
        var statut: Int?
        var statutLisible: Bool
        var total: Double?
        var restant: Double?
        var pourcentageRestant: Double?
        var debut: Double?
        var fin: Double?
    }

    private struct Entree: Decodable {
        var modele: String?
        var voies: [Voie: VoieLue]

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: Cle.self)
            modele = try? c.decodeIfPresent(String.self, forKey: Cle("model_name"))
            func nombre(_ nom: String) -> Double? {
                (try? c.decodeIfPresent(Nombre.self, forKey: Cle(nom)))?.valeur
            }
            func present(_ nom: String) -> Bool {
                c.contains(Cle(nom)) && (try? c.decodeNil(forKey: Cle(nom))) != true
            }
            var voies: [Voie: VoieLue] = [:]
            for voie in Voie.allCases {
                let champs = ["_total_count", "_usage_count", "_remaining_percent"].map { voie.prefixe + $0 }
                let statut = voie.prefixe + "_status"
                voies[voie] = VoieLue(
                    presente: champs.contains(where: present),
                    statut: try? c.decodeIfPresent(Int.self, forKey: Cle(statut)),
                    statutLisible: !present(statut) || (try? c.decode(Int.self, forKey: Cle(statut))) != nil,
                    total: nombre(champs[0]),
                    restant: nombre(champs[1]),
                    pourcentageRestant: nombre(champs[2]),
                    debut: nombre(voie.debut),
                    fin: nombre(voie.fin))
            }
            self.voies = voies
        }
    }

    private struct Statut: Decodable {
        var code: Int?

        enum CodingKeys: String, CodingKey { case code = "status_code" }
    }

    /// Lue seule, avant les données : une réponse d'erreur ne porte pas `model_remains`.
    private struct EnveloppeErreur: Decodable {
        var statut: Souple<Statut>?
        var statutPresent: Bool

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            statutPresent = c.contains(.statut) && (try? c.decodeNil(forKey: .statut)) != true
            statut = try? c.decodeIfPresent(Souple<Statut>.self, forKey: .statut)
        }

        enum CodingKeys: String, CodingKey { case statut = "base_resp" }
    }

    private struct Reponse: Decodable {
        var entrees: [Souple<Entree>]

        enum CodingKeys: String, CodingKey { case entrees = "model_remains" }
    }

    static func analyser(_ donnees: Data, mesureA: Date) -> ReleveMiniMax {
        guard let enveloppe = try? JSONDecoder().decode(EnveloppeErreur.self, from: donnees) else {
            Journal.donnees.notice("Quota MiniMax : réponse illisible")
            return .indetermine
        }
        // Un 200 peut porter une erreur : `base_resp` la dit. Présent, il doit se lire et valoir 0.
        if enveloppe.statutPresent {
            guard let code = enveloppe.statut?.valeur?.code else {
                Journal.donnees.notice("Quota MiniMax : base_resp illisible")
                return .indetermine
            }
            if codesCleRefusee.contains(code) { return .cleRefusee }
            guard code == 0 else {
                Journal.donnees.notice("Quota MiniMax : erreur \(code) dans un 200")
                return .indetermine
            }
        }
        guard let reponse = try? JSONDecoder().decode(Reponse.self, from: donnees) else {
            Journal.donnees.notice("Quota MiniMax : réponse sans model_remains lisible")
            return .indetermine
        }
        let entrees = reponse.entrees.compactMap(\.valeur).compactMap { entree -> (String, [Fenetre])? in
            guard let modele = entree.modele?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !modele.isEmpty else { return nil }
            let fenetres = Voie.allCases.compactMap { voie in entree.voies[voie].flatMap { fenetre($0, voie: voie) } }
            return fenetres.isEmpty ? nil : (modele, fenetres)
        }
        // Le nom du modèle ne départage des fenêtres que s'il y en a plusieurs à départager.
        let plusieurs = entrees.count > 1
        let toutes = entrees.flatMap { modele, fenetres in
            fenetres.map { fenetre -> Fenetre in
                var nommee = fenetre
                if plusieurs { nommee.reserve = modele }
                return nommee
            }
        }
        return .releve(MesureMiniMax(quota: Quota(ordonner(toutes)), mesureA: mesureA))
    }

    /// ⛔ Statut 3 (indisponible) ou illisible : aucune fenêtre. Absent, rien ne dit que la voie
    /// n'est pas mesurée, et ses chiffres se lisent.
    private static func fenetre(_ lue: VoieLue, voie: Voie) -> Fenetre? {
        guard lue.presente, lue.statutLisible, lue.statut == nil || lue.statut == 1,
              let utilisation = consomme(lue) else { return nil }
        let debut = lue.debut.flatMap(QuotaZai.dateMillisecondes)
        let fin = lue.fin.flatMap(QuotaZai.dateMillisecondes)
        let duree = debut.flatMap { debut in fin.flatMap { dureeAdmise(de: debut, a: $0) } }
        let sorte = sorte(duree: duree)
        return Fenetre(libelle: libelle(sorte: sorte, duree: duree, voie: voie),
                       sorte: sorte,
                       utilisation: utilisation,
                       seRechargeA: fin,
                       duree: duree)
    }

    /// Une fenêtre de plus d'un an n'est pas un quota : des bornes qui le disent sont fausses.
    static let dureeMaximale: TimeInterval = 366 * 86_400

    /// ⛔ Positive et au plus `dureeMaximale`, sinon rien : `Duration.seconds` s'arrête net sur
    /// une durée qu'il ne représente pas.
    static func dureeAdmise(de debut: Date, a fin: Date) -> TimeInterval? {
        let duree = fin.timeIntervalSince(debut)
        guard duree.isFinite, duree > 0, duree <= dureeMaximale else { return nil }
        return duree
    }

    /// Le consommé, en pourcentage. Le pourcentage restant prime ; à défaut, les compteurs, dont
    /// `usage_count` est le **restant**. Hors bornes ou contradictoire : rien, plutôt qu'une
    /// grille pleine ou vide qu'aucune mesure n'a dite.
    private static func consomme(_ lue: VoieLue) -> Double? {
        if let restant = lue.pourcentageRestant {
            guard (0...100).contains(restant) else { return nil }
            return 100 - restant
        }
        guard let total = lue.total, total > 0,
              let restant = lue.restant, restant >= 0, restant <= total else { return nil }
        let consomme = (total - restant) / total * 100
        return consomme.isFinite ? consomme : nil
    }

    private static func sorte(duree: TimeInterval?) -> Fenetre.Sorte {
        switch duree {
        case 18_000: .cinqHeures
        case 86_400: .vingtQuatreHeures
        case 604_800: .septJours
        default: .inconnue
        }
    }

    /// Une fenêtre sans sigle se lit sous son nom : sa durée publiée dans la langue servie, ou à
    /// défaut le nom brut de ses champs.
    private static func libelle(sorte: Fenetre.Sorte, duree: TimeInterval?, voie: Voie) -> String {
        switch sorte {
        case .cinqHeures: return Fenetre.libelleCinqHeures
        case .vingtQuatreHeures: return Fenetre.libelleVingtQuatreHeures
        case .septJours: return Fenetre.libelleSeptJours
        default:
            guard let duree else { return voie.prefixe }
            return Duration.seconds(duree)
                .formatted(.units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 2)
                    .locale(Langue.locale))
        }
    }

    /// De la plus courte à la plus longue, **toutes réserves confondues**, par la durée publiée ;
    /// une durée inconnue en dernier. Stable, et sans dédoublonnage : deux modèles de même
    /// sorte restent deux fenêtres, départagées par leur réserve.
    static func ordonner(_ fenetres: [Fenetre]) -> [Fenetre] {
        fenetres.enumerated()
            .sorted { ($0.element.duree ?? .infinity, $0.offset) < ($1.element.duree ?? .infinity, $1.offset) }
            .map(\.element)
    }
}
