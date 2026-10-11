import Foundation

/// Un événement des trente derniers jours : une réinitialisation reçue, ou dépensée.
struct EvenementReinitialisation: Sendable, Equatable {
    enum Nature: Sendable, Equatable {
        case recue
        case utilisee
    }

    let identifiant: String
    let nature: Nature
    let survenuA: Date
}

/// Ce que le serveur garde des réinitialisations d'un compte — trente jours, selon
/// ChatGPT.app. ⛔ Lu à la demande et jamais persisté : une copie locale ne ferait que
/// vieillir à côté de la source.
struct HistoriqueReinitialisations: Sendable, Equatable {
    /// Du plus récent au plus ancien.
    let evenements: [EvenementReinitialisation]
    let debutFenetre: Date?
    let aLa: Date?
    /// `false` quand la lecture s'est arrêtée avant la fin — borne de pages atteinte,
    /// curseur qui boucle ou illisible — ou qu'un événement publié n'a pas pu être lu. Ce
    /// qui est listé est vrai ; ce qui manque, du côté ancien, n'est pas « rien ».
    let complet: Bool
}

/// Ce qu'une lecture de la réserve ou de l'historique a établi.
enum LectureReserveCodex<Valeur: Sendable & Equatable>: Sendable, Equatable {
    case lu(Valeur)
    /// Codex n'est pas suivi : ni le jeton ni le réseau n'ont été touchés.
    case sansConsentement
    /// Le jeton relu, ou la réponse, nomme un autre compte que celui du tiroir — ou n'en
    /// nomme aucun. Rien n'est posé sur la ligne.
    case compteDifferent
    case reconnexionNecessaire
    /// Réseau coupé, statut inattendu, corps illisible, lecture du jeton empêchée.
    case indetermine
}

/// La réserve de réinitialisations anticipées d'un compte Codex et leur historique sur
/// trente jours — deux `GET` sous `chatgpt.com/backend-api/wham/rate-limit-reset-credits`,
/// mesurés le 29/09.
///
/// ⛔ **Lus sur geste seulement** (dépli du tiroir), jamais à chaque cycle, et sous le
/// consentement Codex : c'est la décision Q5 du 02/10. ⛔ La recharge automatique
/// (`/subscriptions/auto_top_up/settings`) n'est **pas** lue : c'est une route de
/// facturation, et rien ici ne doit y mener.
enum ReserveCodex {
    static let cheminReserve = "/backend-api/wham/rate-limit-reset-credits"
    static let cheminHistorique = "/backend-api/wham/rate-limit-reset-credits/history"
    static let delaiParDefaut: TimeInterval = 8
    /// Le serveur pagine par `next_cursor`. Une borne, parce qu'un curseur qui ne finit
    /// jamais ferait partir une requête par tour de boucle.
    static let pagesMax = 5

    typealias Executeur = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias LecteurJeton = @Sendable () async -> LectureCodex
    /// Relu après chaque attente : le consentement retiré pendant la lecture du jeton ou
    /// entre deux pages arrête tout, avant la requête suivante comme avant le résultat.
    typealias LecteurConsentement = @Sendable () async -> ConsentementMesure

    static let appelReel: Executeur = { try await Reseau.session.data(for: $0) }
    /// Le lecteur du jeton d'une rangée : son auth.json à elle, jamais celui du terminal par
    /// défaut — la réserve d'un second compte se lirait sinon sur le premier.
    static func jetonReel(fichier: URL) -> LecteurJeton {
        { await IdentifiantsCodex.jeton(fichier: fichier) }
    }

    // MARK: - Requêtes

    static func requeteReserve(jeton: JetonCodex, delai: TimeInterval = delaiParDefaut) -> URLRequest? {
        guard let url = URL(string: QuotaCodex.hote + cheminReserve) else { return nil }
        return requete(url: url, jeton: jeton, delai: delai)
    }

    static func requeteHistorique(jeton: JetonCodex,
                                  curseur: String?,
                                  delai: TimeInterval = delaiParDefaut) -> URLRequest? {
        guard var composants = URLComponents(string: QuotaCodex.hote + cheminHistorique) else { return nil }
        if let curseur, !curseur.isEmpty {
            composants.queryItems = [URLQueryItem(name: "cursor", value: curseur)]
        }
        guard let url = composants.url else { return nil }
        return requete(url: url, jeton: jeton, delai: delai)
    }

    /// Les en-têtes de `QuotaCodex.requete`, posés **sur la requête** : un `Authorization`
    /// mis dans la session serait rejoué chez le destinataire d'une redirection.
    private static func requete(url: URL, jeton: JetonCodex, delai: TimeInterval) -> URLRequest {
        var requete = URLRequest(url: url)
        requete.httpMethod = "GET"
        requete.timeoutInterval = delai
        requete.setValue("Bearer \(jeton.valeur)", forHTTPHeaderField: "Authorization")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue(QuotaCodex.agent, forHTTPHeaderField: "User-Agent")
        if let compte = jeton.compteIdentifiant {
            requete.setValue(compte, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return requete
    }

    // MARK: - Lectures sur geste

    /// ⛔ `consentement`, `compteAttendu`, `lireJeton` et `executer` n'ont pas de valeur par
    /// défaut : un appelant qui oublierait l'un d'eux ne compile pas, au lieu de lire le
    /// vrai `auth.json` ou de partir sur le réseau.
    static func lireReserve(consentement: LecteurConsentement,
                            compteAttendu: String,
                            lireJeton: LecteurJeton,
                            executer: Executeur,
                            delai: TimeInterval = delaiParDefaut) async -> LectureReserveCodex<ReserveReinitialisations> {
        let jeton: JetonCodex
        switch await jetonAutorise(consentement: consentement, compteAttendu: compteAttendu, lireJeton: lireJeton) {
        case .success(let lu): jeton = lu
        case .failure(let refus): return refus.lecture()
        }
        guard let requete = requeteReserve(jeton: jeton, delai: delai) else { return .indetermine }
        let reponse = await charger(requete, executer: executer)
        guard await consentement()[.chatgpt] else { return .sansConsentement }
        switch reponse {
        case .donnees(let donnees):
            guard reponseDuCompte(donnees, compteAttendu) else { return .compteDifferent }
            guard let reserve = decoderReserve(donnees) else { return .indetermine }
            return .lu(reserve)
        case .jetonRefuse: return .reconnexionNecessaire
        case .echec: return .indetermine
        }
    }

    static func lireHistorique(consentement: LecteurConsentement,
                               compteAttendu: String,
                               lireJeton: LecteurJeton,
                               executer: Executeur,
                               delai: TimeInterval = delaiParDefaut) async -> LectureReserveCodex<HistoriqueReinitialisations> {
        let jeton: JetonCodex
        switch await jetonAutorise(consentement: consentement, compteAttendu: compteAttendu, lireJeton: lireJeton) {
        case .success(let lu): jeton = lu
        case .failure(let refus): return refus.lecture()
        }

        var evenements: [EvenementReinitialisation] = []
        var vus = Set<String>()
        var premiere: PageHistorique?
        var curseur: String?
        var cursorsVus = Set<String>()
        var illisibles = false

        for _ in 0..<pagesMax {
            guard let requete = requeteHistorique(jeton: jeton, curseur: curseur, delai: delai) else {
                return .indetermine
            }
            let reponse = await charger(requete, executer: executer)
            guard await consentement()[.chatgpt] else { return .sansConsentement }
            switch reponse {
            case .donnees(let donnees):
                guard reponseDuCompte(donnees, compteAttendu) else { return .compteDifferent }
                guard let page = decoderPageHistorique(donnees) else { return .indetermine }
                if premiere == nil { premiere = page }
                illisibles = illisibles || page.evenementsIllisibles
                for evenement in page.evenements where vus.insert(evenement.identifiant).inserted {
                    evenements.append(evenement)
                }
                switch page.suite {
                case .fin:
                    return .lu(historique(evenements, premiere: premiere, complet: !illisibles))
                case .illisible:
                    return .lu(historique(evenements, premiere: premiere, complet: false))
                case .curseur(let suivant):
                    // Un curseur déjà vu boucle : la suite existe, mais ne se lira pas.
                    guard cursorsVus.insert(suivant).inserted else {
                        return .lu(historique(evenements, premiere: premiere, complet: false))
                    }
                    curseur = suivant
                }
            case .jetonRefuse: return .reconnexionNecessaire
            case .echec: return .indetermine
            }
        }
        // La borne atteinte : ce qui a été lu est vrai, seulement incomplet du côté ancien.
        Journal.donnees.notice("Réserve Codex : historique tronqué à \(pagesMax) pages")
        return .lu(historique(evenements, premiere: premiere, complet: false))
    }

    private static func historique(_ evenements: [EvenementReinitialisation],
                                   premiere: PageHistorique?,
                                   complet: Bool) -> HistoriqueReinitialisations {
        HistoriqueReinitialisations(evenements: evenements.sorted { $0.survenuA > $1.survenuA },
                                    debutFenetre: premiere?.debutFenetre,
                                    aLa: premiere?.aLa,
                                    complet: complet)
    }

    private enum Refus: Error {
        case sansConsentement, compteDifferent, reconnexionNecessaire, indetermine

        func lecture<V>() -> LectureReserveCodex<V> {
            switch self {
            case .sansConsentement: .sansConsentement
            case .compteDifferent: .compteDifferent
            case .reconnexionNecessaire: .reconnexionNecessaire
            case .indetermine: .indetermine
            }
        }
    }

    /// Le consentement est vérifié **avant** la lecture du jeton — sans lui, `auth.json`
    /// n'est même pas ouvert — puis **relu après**, avant la première requête. ⛔ Le compte se prouve par le jeton lui-même, sous la règle
    /// de `ReinitialisationCodex` (`JetonCodex.estDuCompte`) : un `codex login` intercalé
    /// aurait remplacé la session, et `account_id` seul n'est qu'une déclaration.
    private static func jetonAutorise(consentement: LecteurConsentement,
                                      compteAttendu: String,
                                      lireJeton: LecteurJeton) async -> Result<JetonCodex, Refus> {
        guard await consentement()[.chatgpt] else { return .failure(.sansConsentement) }
        let lu = await lireJeton()
        guard await consentement()[.chatgpt] else { return .failure(.sansConsentement) }
        switch lu {
        case .jeton(let jeton):
            guard jeton.estDuCompte(compteAttendu) else { return .failure(.compteDifferent) }
            return .success(jeton)
        case .absent: return .failure(.reconnexionNecessaire)
        // Un jeton personnel ne prouve aucun compte : rien de ciblé ne part avec lui.
        case .empechee, .horsDePortee, .jetonPersonnel: return .failure(.indetermine)
        }
    }

    // MARK: - Transport

    private static func charger(_ requete: URLRequest, executer: Executeur) async -> QuotaCodex.ReponseAPI {
        do {
            let (donnees, reponse) = try await executer(requete)
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            if code != 200 { Journal.donnees.notice("Réserve Codex : statut HTTP \(code)") }
            return QuotaCodex.interpreter(code: code, donnees: donnees)
        } catch {
            Journal.donnees.debug("Réserve Codex : chatgpt.com injoignable")
            return .echec
        }
    }

    // MARK: - Analyses pures

    /// ⛔ L'en-tête `ChatGPT-Account-Id` envoyé ne prouve rien — le serveur répond pour le
    /// compte du jeton. Si la réponse nomme un compte, c'est lui qu'on croit, et il doit
    /// être l'attendu. Les réponses mesurées le 29/09 n'en nomment aucun : l'identité tient
    /// alors au jeton relu au moment du geste.
    ///
    /// ⛔ « Absent » et « illisible » ne se confondent pas : `account_id` absent ou `null` ne
    /// dit rien, mais `account_id: 7` ou `""` nomme un compte qu'on ne sait pas lire, et une
    /// identité qu'on ne lit pas n'est pas une identité accordée. Un corps qui n'est pas un
    /// objet JSON passe ici : c'est au décodage de le dire illisible.
    static func reponseDuCompte(_ donnees: Data, _ attendu: String) -> Bool {
        guard let objet = (try? JSONSerialization.jsonObject(with: donnees)) as? [String: Any],
              let brut = objet["account_id"], !(brut is NSNull) else { return true }
        guard let compte = brut as? String else { return false }
        return memeCompte(compte, attendu)
    }

    private static func memeCompte(_ lu: String, _ attendu: String) -> Bool {
        let lu = lu.trimmingCharacters(in: .whitespacesAndNewlines)
        let attendu = attendu.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lu.isEmpty, !attendu.isEmpty else { return false }
        return lu.lowercased() == attendu.lowercased()
    }

    private struct ReponseReserve: Decodable {
        struct Credit: Decodable {
            var statut: String?
            var expireA: Horodatage?
            enum CodingKeys: String, CodingKey {
                case statut = "status"
                case expireA = "expires_at"
            }

            init(from decoder: Decoder) throws {
                let boite = try decoder.container(keyedBy: CodingKeys.self)
                statut = (try? boite.decodeIfPresent(String.self, forKey: .statut)) ?? nil
                expireA = (try? boite.decodeIfPresent(Horodatage.self, forKey: .expireA)) ?? nil
            }
        }

        var credits: [Credit]
        var disponibles: Int?
        var applicables: Int?

        enum CodingKeys: String, CodingKey {
            case credits
            case disponibles = "available_count"
            case applicables = "applicable_available_count"
        }

        /// Seul le décompte reste strict : mal typé, il fait tomber la réserve. Un crédit
        /// illisible ne coûte que son expiration, un `applicable` illisible que lui-même.
        init(from decoder: Decoder) throws {
            let boite = try decoder.container(keyedBy: CodingKeys.self)
            disponibles = try boite.decodeIfPresent(Int.self, forKey: .disponibles)
            applicables = (try? boite.decodeIfPresent(Int.self, forKey: .applicables)) ?? nil
            credits = ((try? boite.decodeIfPresent([Souple<Credit>].self, forKey: .credits)) ?? nil)?
                .compactMap(\.valeur) ?? []
        }
    }

    /// ⚠️ Sans `available_count`, aucune réserve : le décompte ne se reconstruit pas depuis
    /// la liste, qui peut être paginée ou filtrée. Un décompte négatif n'en est pas un —
    /// `ReserveReinitialisations` le refuse. Un `applicable` négatif, comme dans
    /// `QuotaCodex`, reste `nil` : jamais zéro.
    static func decoderReserve(_ donnees: Data) -> ReserveReinitialisations? {
        guard let reponse = try? JSONDecoder().decode(ReponseReserve.self, from: donnees),
              let disponibles = reponse.disponibles else { return nil }
        let expirations = reponse.credits
            .filter { $0.statut == "available" }
            .compactMap { $0.expireA?.date }
            .sorted()
        return ReserveReinitialisations(disponibles: disponibles,
                                        applicables: reponse.applicables.flatMap { $0 >= 0 ? $0 : nil },
                                        expirations: expirations)
    }

    struct PageHistorique: Sendable, Equatable {
        /// Ce que la page dit de la suivante.
        enum Suite: Sendable, Equatable {
            /// `next_cursor` absent, `null` ou vide.
            case fin
            case curseur(String)
            /// `next_cursor` d'un autre type : une suite existe peut-être, illisible.
            case illisible
        }

        let evenements: [EvenementReinitialisation]
        let debutFenetre: Date?
        let aLa: Date?
        let suite: Suite
        /// Un événement publié n'a pas pu être lu — sans identifiant, sans date, sans
        /// nature, ou d'une forme inattendue. Un `kind` inconnu n'en est pas un : il est lu,
        /// puis écarté exprès.
        let evenementsIllisibles: Bool

        var curseurSuivant: String? {
            if case .curseur(let curseur) = suite { curseur } else { nil }
        }
    }

    private struct ReponseHistorique: Decodable {
        struct Evenement: Decodable {
            var identifiant: String?
            var nature: String?
            var survenuA: Horodatage?
            enum CodingKeys: String, CodingKey {
                case identifiant = "id"
                case nature = "kind"
                case survenuA = "occurred_at"
            }

            init(from decoder: Decoder) throws {
                let boite = try decoder.container(keyedBy: CodingKeys.self)
                identifiant = (try? boite.decodeIfPresent(String.self, forKey: .identifiant)) ?? nil
                nature = (try? boite.decodeIfPresent(String.self, forKey: .nature)) ?? nil
                survenuA = (try? boite.decodeIfPresent(Horodatage.self, forKey: .survenuA)) ?? nil
            }
        }

        var evenements: [Souple<Evenement>]?
        var debutFenetre: Horodatage?
        var aLa: Horodatage?
        var suite: PageHistorique.Suite

        enum CodingKeys: String, CodingKey {
            case evenements = "events"
            case debutFenetre = "window_start"
            case aLa = "as_of"
            case curseurSuivant = "next_cursor"
        }

        /// `events` reste strict — sans liste, pas d'historique —, mais chaque élément se
        /// décode seul : un événement mal typé ne coûte que lui-même, jamais la page.
        init(from decoder: Decoder) throws {
            let boite = try decoder.container(keyedBy: CodingKeys.self)
            evenements = try boite.decodeIfPresent([Souple<Evenement>].self, forKey: .evenements)
            debutFenetre = (try? boite.decodeIfPresent(Horodatage.self, forKey: .debutFenetre)) ?? nil
            aLa = (try? boite.decodeIfPresent(Horodatage.self, forKey: .aLa)) ?? nil
            if (try? boite.decodeNil(forKey: .curseurSuivant)) ?? true {
                suite = .fin
            } else if let curseur = try? boite.decode(String.self, forKey: .curseurSuivant) {
                suite = curseur.isEmpty ? .fin : .curseur(curseur)
            } else {
                suite = .illisible
            }
        }
    }

    /// ⚠️ Un `kind` inconnu, ou un événement sans date ni identifiant, est écarté : le
    /// ranger en « reçue » ou « utilisée » dirait au hasard qu'un crédit est arrivé ou parti.
    static func decoderPageHistorique(_ donnees: Data) -> PageHistorique? {
        guard let reponse = try? JSONDecoder().decode(ReponseHistorique.self, from: donnees),
              let bruts = reponse.evenements else { return nil }
        var illisibles = false
        let evenements = bruts.compactMap { souple -> EvenementReinitialisation? in
            guard let brut = souple.valeur,
                  let identifiant = brut.identifiant, !identifiant.isEmpty,
                  let date = brut.survenuA?.date,
                  let nature = brut.nature else {
                illisibles = true
                return nil
            }
            switch nature {
            case "granted": return EvenementReinitialisation(identifiant: identifiant, nature: .recue, survenuA: date)
            case "used": return EvenementReinitialisation(identifiant: identifiant, nature: .utilisee, survenuA: date)
            default: return nil
            }
        }
        return PageHistorique(evenements: evenements,
                              debutFenetre: reponse.debutFenetre?.date,
                              aLa: reponse.aLa?.date,
                              suite: reponse.suite,
                              evenementsIllisibles: illisibles)
    }
}
