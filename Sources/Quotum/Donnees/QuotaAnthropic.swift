import Foundation

/// Une limite telle que l'API la publie dans `limits`, seule liste normalisée de la
/// réponse : les fenêtres nommées (`five_hour`, `seven_day_opus`, `amber_ladder`…)
/// vont et viennent d'une version à l'autre. Mesuré le 2026-09-29 : `session`,
/// `weekly_all` et `weekly_scoped`, celle-ci seule portée (le modèle « Fable »).
struct LimiteAPI: Sendable, Equatable {
    var genre: String
    var groupe: String?
    var portee: Portee?
    var pourcentage: Double
    var severite: String?
    var seRechargeA: Date?
    var estActive: Bool

    /// Plusieurs fenêtres coexistent et une seule bloque : c'est le pourcentage qui
    /// dit qu'on est au bout, pas `estActive` — qui désigne la fenêtre courante,
    /// pleine ou vide.
    var estSaturee: Bool { pourcentage >= 100 }
}

/// Ce que le seul jeton au scope `user:profile` permet de savoir. Les jetons
/// `claude-oauth-*` du proxy n'ont pas ce scope : aucun autre compte ne publie de
/// pourcentage, et aucun ne doit en afficher un.
struct ReleveAnthropic: Sendable, Equatable {
    /// `nil` quand la réponse ne publie pas les fenêtres du forfait mais porte des crédits
    /// d'utilisation : ceux-ci se transmettent seuls, et aucune fenêtre n'est fabriquée
    /// pour les accompagner.
    var quota: Quota?
    var mesureA: Date = .now
    var courriel: String?
    var organisation: String?
    /// Identifiant d'organisation. C'est la clé d'appariement fiable : deux comptes
    /// peuvent partager un courriel et n'être pas la même organisation.
    var organisationIdentifiant: String?
    var jetonExpireA: Date?
    var limites: [LimiteAPI] = []
    var usagePayant: UsagePayant?
    var formule: Formule?
    /// La réponse publie `five_hour` et `seven_day` **nuls**, pas absents ni illisibles :
    /// l'offre ne compte pas en fenêtres (Enterprise facturé à l'usage), et la dépense est
    /// alors la seule mesure du compte.
    var sansFenetres = false
    /// Les natures d'argent que la réponse publiait sans qu'on puisse les lire. Une lecture
    /// empêchée n'est pas une absence : la mesure gardée de cette nature reste.
    var argentIllisible: Set<UsagePayant.Nature> = []

    /// La limite du compte épuisée dont l'échéance est la plus lointaine : c'est elle
    /// qui commande le retour, pas la première rencontrée.
    var limiteSaturee: LimiteAPI? {
        limites.filter { $0.estSaturee && $0.vautPourLeCompte }
            .max { ($0.seRechargeA ?? .distantPast) < ($1.seRechargeA ?? .distantPast) }
    }
}

/// Ce que la lecture du Trousseau a pu établir. Un jeton refusé n'est pas une absence
/// de mesure : c'est un `/login` à refaire, et c'est la seule façon de retrouver le
/// seul pourcentage exact du panneau. Le taire laissait la grille disparaître sans un
/// mot, indiscernable d'un compte qui n'a jamais rien publié.
enum ReleveTrousseau: Sendable, Equatable {
    case releve(ReleveAnthropic)
    /// Jeton présent mais refusé par l'API. Ne dit rien du quota : le compte peut être
    /// plein, c'est l'accès qui manque.
    case reconnexionNecessaire
    /// L'appel n'a rien établi — réseau coupé, statut inattendu, corps illisible. Il
    /// n'infirme donc rien : un refus constaté au cycle précédent reste vrai, et
    /// l'effacer ferait disparaître la demande de `/login` sans que rien ne la règle.
    case indetermine
    /// Aucun jeton dans le Trousseau : cette machine n'a pas de session Claude Code,
    /// il n'y a rien à relever et rien à reconnecter.
    case aucun
}

enum QuotaAnthropic {
    static let hote = "https://api.anthropic.com"
    static let versionBeta = "oauth-2025-04-20"

    /// Ce qu'un appel a rapporté. Le refus de jeton se distingue de l'échec ordinaire
    /// parce qu'il remonte jusqu'au panneau, là où l'autre reste dans le journal.
    enum ReponseAPI: Sendable, Equatable {
        case donnees(Data)
        case jetonRefuse
        case echec
    }

    static func relever(session: URLSession = Reseau.session,
                        delai: TimeInterval = 8) async -> ReleveTrousseau {
        switch await Trousseau.jetonClaudeCode() {
        case .jeton(let jeton):
            return await relever(jeton: jeton, session: session, delai: delai)
        case .absent:
            return .aucun
        // Une lecture empêchée n'établit pas l'absence de session : la prendre pour
        // telle lèverait une demande de reconnexion que rien n'a réglée.
        case .empechee:
            return .indetermine
        }
    }

    /// Les deux appels sont indépendants une fois le jeton en main : les enchaîner
    /// doublait l'attente du seul compte qui publie un pourcentage exact.
    ///
    /// `/usage` est attendu ici, et non dans un tuple avec le profil : c'est lui qui
    /// tranche, et son refus n'a pas à patienter derrière un profil qui n'y changera
    /// rien. Le profil reste en vol, et le quitter l'annule.
    static func relever(jeton: JetonClaudeCode,
                        session: URLSession = Reseau.session,
                        delai: TimeInterval = 8) async -> ReleveTrousseau {
        async let profilEnVol = charger("/api/oauth/profile", jeton: jeton, session: session, delai: delai)
        let usage = await charger("/api/oauth/usage", jeton: jeton, session: session, delai: delai)
        // L'heure de la réponse du quota, pas celle de la fin de l'attente : un profil
        // lent rajeunirait sinon une mesure vieille de plusieurs secondes.
        let mesureA = Date()

        switch usage {
        case .jetonRefuse:
            return .reconnexionNecessaire
        case .echec:
            // Le même jeton porte les deux appels : un refus vu par le profil est un
            // refus établi, même quand `/usage` n'a rien pu dire.
            return await profilEnVol == .jetonRefuse ? .reconnexionNecessaire : .indetermine
        case .donnees(let donneesUsage):
            let quota = decoderUsage(donneesUsage)
            let argent = lireUsagePayant(donneesUsage, mesureA: mesureA)
            // Ni fenêtre ni crédit : la réponse n'a rien mesuré.
            guard quota != nil || argent.usage != nil else { return .indetermine }
            var releve = ReleveAnthropic(quota: quota,
                                         mesureA: mesureA,
                                         jetonExpireA: jeton.expireA,
                                         limites: decoderLimites(donneesUsage),
                                         usagePayant: argent.usage,
                                         sansFenetres: publieSansFenetres(donneesUsage),
                                         argentIllisible: argent.illisible)
            if case .donnees(let donneesProfil) = await profilEnVol {
                let details = decoderProfil(donneesProfil)
                releve.courriel = details.courriel
                releve.organisation = details.organisation
                releve.organisationIdentifiant = details.identifiant
                releve.formule = decoderFormule(donneesProfil)
            }
            return .releve(releve)
        }
    }

    static func requete(chemin: String, jeton: JetonClaudeCode, delai: TimeInterval) -> URLRequest? {
        guard let url = URL(string: hote + chemin) else { return nil }
        var requete = URLRequest(url: url)
        requete.httpMethod = "GET"
        requete.timeoutInterval = delai
        requete.setValue("Bearer \(jeton.valeur)", forHTTPHeaderField: "Authorization")
        requete.setValue(versionBeta, forHTTPHeaderField: "anthropic-beta")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        return requete
    }

    private static func charger(_ chemin: String,
                                jeton: JetonClaudeCode,
                                session: URLSession,
                                delai: TimeInterval) async -> ReponseAPI {
        guard let requete = requete(chemin: chemin, jeton: jeton, delai: delai) else { return .echec }

        do {
            let (donnees, reponse) = try await session.data(for: requete)
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            journaliser(code: code, chemin: chemin)
            return interpreter(code: code, donnees: donnees)
        } catch {
            Journal.donnees.debug("Quota Anthropic : api.anthropic.com injoignable")
            return .echec
        }
    }

    /// Le jeton du Trousseau vit quelques heures, et il se renouvelle par un `/login`,
    /// jamais en réessayant : le 401 est le seul statut dont l'utilisateur a quelque
    /// chose à faire. Les autres ne lui demandent rien.
    static func interpreter(code: Int, donnees: Data) -> ReponseAPI {
        switch code {
        case 200: .donnees(donnees)
        case 401: .jetonRefuse
        default: .echec
        }
    }

    private static func journaliser(code: Int, chemin: String) {
        switch code {
        case 200:
            break
        case 401:
            Journal.donnees.notice("Quota Anthropic : jeton expiré (401) sur \(chemin, privacy: .public)")
        case 403:
            Journal.donnees.notice("Quota Anthropic : scope insuffisant (403) sur \(chemin, privacy: .public)")
        default:
            Journal.donnees.notice("Quota Anthropic : statut HTTP \(code) sur \(chemin, privacy: .public)")
        }
    }

    // MARK: - Analyses pures

    private struct ReponseUsage: Decodable {
        struct FenetreAPI: Decodable {
            var utilisation: Double?
            var seRechargeA: Horodatage?

            enum CodingKeys: String, CodingKey {
                case utilisation = "utilization"
                case seRechargeA = "resets_at"
            }
        }

        /// Toute portée non nulle en fait une, même de forme inattendue : la perdre au
        /// décodage rendrait au compte entier une limite qui ne le concerne pas.
        struct PorteeBrute: Decodable {
            var modele: String?

            private struct Modele: Decodable {
                var nom: String?
                enum CodingKeys: String, CodingKey { case nom = "display_name" }
            }

            private enum CodingKeys: String, CodingKey { case modele = "model" }

            init(from decoder: Decoder) throws {
                let boite = try? decoder.container(keyedBy: CodingKeys.self)
                modele = (try? boite?.decodeIfPresent(Modele.self, forKey: .modele))?.nom
            }
        }

        /// Le groupe n'est qu'informatif : un type inattendu ne doit pas faire tomber
        /// tout `limits`, et avec lui une semaine du compte réellement épuisée.
        struct GroupeBrut: Decodable {
            var valeur: String?

            init(from decoder: Decoder) throws {
                valeur = try? decoder.singleValueContainer().decode(String.self)
            }
        }

        struct LimiteBrute: Decodable {
            var genre: String?
            var groupe: GroupeBrut?
            var portee: PorteeBrute?
            var pourcentage: Double?
            var severite: String?
            var seRechargeA: Horodatage?
            var estActive: Bool?

            enum CodingKeys: String, CodingKey {
                case genre = "kind"
                case groupe = "group"
                case portee = "scope"
                case pourcentage = "percent"
                case severite = "severity"
                case seRechargeA = "resets_at"
                case estActive = "is_active"
            }

            /// Champ par champ : un `severity` ou un `is_active` d'un type inattendu ne doit
            /// pas emporter la limite, et avec elle une semaine du compte réellement épuisée.
            init(from decoder: Decoder) throws {
                let boite = try decoder.container(keyedBy: CodingKeys.self)
                genre = (try? boite.decodeIfPresent(String.self, forKey: .genre)) ?? nil
                groupe = (try? boite.decodeIfPresent(GroupeBrut.self, forKey: .groupe)) ?? nil
                portee = (try? boite.decodeIfPresent(PorteeBrute.self, forKey: .portee)) ?? nil
                pourcentage = (try? boite.decodeIfPresent(Double.self, forKey: .pourcentage)) ?? nil
                severite = (try? boite.decodeIfPresent(String.self, forKey: .severite)) ?? nil
                seRechargeA = (try? boite.decodeIfPresent(Horodatage.self, forKey: .seRechargeA)) ?? nil
                estActive = (try? boite.decodeIfPresent(Bool.self, forKey: .estActive)) ?? nil
            }
        }

        var cinqHeures: FenetreAPI?
        var septJours: FenetreAPI?
        var limites: [LimiteBrute]?
        var creditsUtilisation: CreditsUtilisationBruts?
        var depense: DepenseBrute?
        var fenetresNulles = false
        /// Une fenêtre publiée sous une forme qu'on ne sait pas lire. Elle n'est pas
        /// absente : elle peut être celle qui bloque.
        var fenetreIllisible = false

        enum CodingKeys: String, CodingKey {
            case cinqHeures = "five_hour"
            case septJours = "seven_day"
            case limites = "limits"
            case creditsUtilisation = "extra_usage"
            case depense = "spend"
        }

        /// Chaque bloc se décode seul, et `limits` élément par élément : un élément mal typé
        /// ne coûte que lui-même, jamais les fenêtres ni les crédits de la même réponse.
        init(from decoder: Decoder) throws {
            let boite = try decoder.container(keyedBy: CodingKeys.self)
            cinqHeures = (try? boite.decodeIfPresent(FenetreAPI.self, forKey: .cinqHeures)) ?? nil
            septJours = (try? boite.decodeIfPresent(FenetreAPI.self, forKey: .septJours)) ?? nil
            limites = ((try? boite.decodeIfPresent([Souple<LimiteBrute>].self, forKey: .limites)) ?? nil)?
                .compactMap(\.valeur)
            creditsUtilisation = (try? boite.decodeIfPresent(CreditsUtilisationBruts.self,
                                                             forKey: .creditsUtilisation)) ?? nil
            depense = (try? boite.decodeIfPresent(DepenseBrute.self, forKey: .depense)) ?? nil
            // Une clé absente ou mal typée n'est pas un `null` publié : elle ne dit pas que
            // l'offre se passe de fenêtres.
            let nulle = { (cle: CodingKeys) in boite.contains(cle) && (try? boite.decodeNil(forKey: cle)) == true }
            fenetresNulles = nulle(.cinqHeures) && nulle(.septJours)
            let illisible = { (cle: CodingKeys, lue: FenetreAPI?) in
                boite.contains(cle) && !nulle(cle) && lue == nil
            }
            fenetreIllisible = illisible(.cinqHeures, cinqHeures) || illisible(.septJours, septJours)
        }
    }

    static func publieSansFenetres(_ donnees: Data) -> Bool {
        (try? JSONDecoder().decode(ReponseUsage.self, from: donnees))?.fenetresNulles ?? false
    }

    /// Chaque fenêtre publiée en fait une, et seulement elle : une offre peut ne publier
    /// que la semaine, et lui refuser toute grille faute de 5 h effaçait un compte mesuré.
    /// Une clé absente, `null`, ou sans `utilization` n'est pas publiée.
    ///
    /// ⛔ Une fenêtre publiée mais illisible — mal typée, ou que `Fenetre` refuse — fait
    /// tomber le quota entier : c'est peut-être elle qui bloque, et montrer l'autre seule
    /// donnerait le feu vert sur un compte à sec.
    static func decoderUsage(_ donnees: Data) -> Quota? {
        guard let reponse = try? JSONDecoder().decode(ReponseUsage.self, from: donnees),
              !reponse.fenetreIllisible else { return nil }
        // `duree` reste nulle : l'API nomme ses fenêtres (`five_hour`, `seven_day`)
        // sans jamais publier leur durée. La déduire du nom serait une convention de
        // notre côté, pas une mesure du sien.
        var fenetres: [Fenetre] = []
        if let session = reponse.cinqHeures, let utilisation = session.utilisation {
            guard let fenetre = Fenetre.cinqHeures(utilisation: utilisation,
                                                   seRechargeA: session.seRechargeA?.date) else { return nil }
            fenetres.append(fenetre)
        }
        if let semaine = reponse.septJours, let utilisation = semaine.utilisation {
            guard let fenetre = Fenetre.septJours(utilisation: utilisation,
                                                  seRechargeA: semaine.seRechargeA?.date) else { return nil }
            fenetres.append(fenetre)
        }
        guard !fenetres.isEmpty else { return nil }
        return Quota(fenetres, limitesModele: limitesModele(limitesAPI(reponse.limites)))
    }

    /// ⚠️ Ne jamais lire `seven_day_breakdown` comme un niveau : ses lignes sont une
    /// RÉPARTITION dont la somme fait 100. Mesuré le 2026-09-16, « Claude Code : 100 % »
    /// sur un compte consommé à 46 % — l'afficher comme un quota dirait l'inverse du vrai.
    static func decoderLimites(_ donnees: Data) -> [LimiteAPI] {
        guard let reponse = try? JSONDecoder().decode(ReponseUsage.self, from: donnees) else { return [] }
        return limitesAPI(reponse.limites)
    }

    private static func limitesAPI(_ brutes: [ReponseUsage.LimiteBrute]?) -> [LimiteAPI] {
        guard let brutes else { return [] }
        return brutes.compactMap { brute in
            guard let genre = brute.genre, let pourcentage = brute.pourcentage else { return nil }
            return LimiteAPI(genre: genre,
                             groupe: nonVide(brute.groupe?.valeur),
                             portee: brute.portee.map { LimiteAPI.Portee(modele: nonVide($0.modele)) },
                             pourcentage: borner(pourcentage),
                             severite: nonVide(brute.severite),
                             seRechargeA: brute.seRechargeA?.date,
                             estActive: brute.estActive ?? false)
        }
    }

    private struct ReponseProfil: Decodable {
        struct Compte: Decodable {
            var courriel: String?
            var courrielHerite: String?

            // Mesuré le 2026-09-16 : la clé est `email`. `email_address` était une
            // supposition, et elle rendait le courriel toujours nul — le relevé ne
            // retrouvait alors jamais le compte qui le porte.
            enum CodingKeys: String, CodingKey {
                case courriel = "email"
                case courrielHerite = "email_address"
            }
        }

        struct Organisation: Decodable {
            var nom: String?
            var identifiant: String?
            var type: TexteSouple?
            var palier: TexteSouple?

            enum CodingKeys: String, CodingKey {
                case nom = "name"
                case identifiant = "uuid"
                case type = "organization_type"
                case palier = "rate_limit_tier"
            }
        }

        var compte: Compte?
        var organisation: Organisation?

        enum CodingKeys: String, CodingKey {
            case compte = "account"
            case organisation = "organization"
        }
    }

    static func decoderProfil(_ donnees: Data)
        -> (courriel: String?, organisation: String?, identifiant: String?) {
        guard let reponse = try? JSONDecoder().decode(ReponseProfil.self, from: donnees) else {
            return (nil, nil, nil)
        }
        let courriel = nonVide(reponse.compte?.courriel) ?? nonVide(reponse.compte?.courrielHerite)
        return (courriel, nonVide(reponse.organisation?.nom), nonVide(reponse.organisation?.identifiant))
    }

    private static func borner(_ valeur: Double) -> Double {
        min(100, max(0, valeur))
    }

    private static func nonVide(_ valeur: String?) -> String? {
        guard let coupe = valeur?.trimmingCharacters(in: .whitespacesAndNewlines), !coupe.isEmpty else {
            return nil
        }
        return coupe
    }
}

extension LimiteAPI {
    /// Ce à quoi une limite se restreint. Une portée présente, quelle qu'en soit la
    /// forme, dit que la limite ne vaut pas pour tout le compte.
    struct Portee: Sendable, Equatable {
        /// Le nom du modèle tel que publié : `scope.model.id` revient nul, c'est le
        /// seul identifiant.
        var modele: String?
    }

    /// Les seules limites qui bloquent le compte entier. Liste de ce qui est admis,
    /// jamais de ce qui est exclu : une limite de modèle (Fable à 100 %) ou de
    /// dépense (`spend`) laisse passer les autres requêtes, et un genre inconnu ne
    /// prouve rien — c'est le proxy, qui encaisse les vrais refus, qui le dira.
    static let genresDuCompte: Set<String> = ["session", "weekly_all"]

    var vautPourLeCompte: Bool { portee == nil && Self.genresDuCompte.contains(genre) }
}

// MARK: - Hors quota : limites de modèle, crédits d'utilisation, formule

/// Un texte publié, ou rien : un type inattendu ne fait pas tomber la réponse qui le porte
/// — le profil perdrait son courriel.
struct TexteSouple: Decodable, Sendable, Equatable {
    var valeur: String?

    init(from decoder: Decoder) throws {
        valeur = try? decoder.singleValueContainer().decode(String.self)
    }
}

/// Un nombre publié, décodé sans passer par `Double`. Présent mais d'un autre type, il
/// reste là avec une valeur nulle : c'est un chiffre illisible, pas un chiffre absent.
struct NombreSouple: Decodable, Sendable, Equatable {
    var valeur: Decimal?

    init(from decoder: Decoder) throws {
        valeur = try? decoder.singleValueContainer().decode(Decimal.self)
    }
}

extension QuotaAnthropic {
    /// `extra_usage`, mesuré le 2026-09-29. Chaque champ se décode seul : un champ d'un type
    /// inattendu se perd sans emporter les autres, ni le quota de la même réponse.
    fileprivate struct CreditsUtilisationBruts: Decodable {
        var actif: Bool?
        /// En unités mineures (`17000` = 170,00 €), comme le consommé.
        var plafondMensuel: NombreSouple?
        var consomme: NombreSouple?
        var devise: String?
        var decimales: Int?
        var motif: String?
        var plafondAtteint: Bool?

        private enum CodingKeys: String, CodingKey {
            case actif = "is_enabled"
            case plafondMensuel = "monthly_limit"
            case consomme = "used_credits"
            case devise = "currency"
            case decimales = "decimal_places"
            case motif = "disabled_reason"
            case plafondAtteint = "spend_limit_reached"
        }

        /// Le bloc publié n'est pas un objet : une lecture empêchée, pas un silence.
        var formeInattendue = false

        // ⛔ `utilization` n'est pas lu : c'est un rapport, jamais un consommé.
        init(from decoder: Decoder) throws {
            let boite = try? decoder.container(keyedBy: CodingKeys.self)
            formeInattendue = boite == nil
            actif = (try? boite?.decodeIfPresent(Bool.self, forKey: .actif)) ?? nil
            plafondMensuel = (try? boite?.decodeIfPresent(NombreSouple.self, forKey: .plafondMensuel)) ?? nil
            consomme = (try? boite?.decodeIfPresent(NombreSouple.self, forKey: .consomme)) ?? nil
            devise = (try? boite?.decodeIfPresent(String.self, forKey: .devise)) ?? nil
            decimales = (try? boite?.decodeIfPresent(Int.self, forKey: .decimales)) ?? nil
            motif = (try? boite?.decodeIfPresent(String.self, forKey: .motif)) ?? nil
            plafondAtteint = (try? boite?.decodeIfPresent(Bool.self, forKey: .plafondAtteint)) ?? nil
        }
    }

    /// `spend` : le même usage, mieux typé. Il ne sert ici qu'au solde prépayé — une seule
    /// source pour le consommé et le plafond, celle que lisent les deux clients officiels.
    fileprivate struct DepenseBrute: Decodable {
        var solde: MontantBrut?
        /// Un solde présent et non nul, lisible ou non.
        var soldePublie = false

        private enum CodingKeys: String, CodingKey { case solde = "balance" }

        init(from decoder: Decoder) throws {
            let boite = try? decoder.container(keyedBy: CodingKeys.self)
            solde = (try? boite?.decodeIfPresent(MontantBrut.self, forKey: .solde)) ?? nil
            soldePublie = boite.map { $0.contains(.solde) && (try? $0.decodeNil(forKey: .solde)) == false } ?? false
        }
    }

    fileprivate struct MontantBrut: Decodable {
        var unitesMineures: Decimal
        var devise: String
        var exposant: Int

        private enum CodingKeys: String, CodingKey {
            case unitesMineures = "amount_minor"
            case devise = "currency"
            case exposant = "exponent"
        }
    }

    /// Les limites propres à un modèle (« Fable »), hors des fenêtres du compte. Seul
    /// `weekly_scoped` en porte, mesuré ; son genre la dit hebdomadaire, et un groupe qui
    /// le contredirait ne laisse pas deviner laquelle des deux durées est la vraie.
    static func limitesModele(_ limites: [LimiteAPI]) -> [LimiteModele] {
        limites.compactMap { limite in
            guard limite.genre == "weekly_scoped",
                  limite.groupe == nil || limite.groupe == "weekly",
                  let modele = limite.portee?.modele,
                  let fenetre = Fenetre.septJours(utilisation: limite.pourcentage,
                                                  seRechargeA: limite.seRechargeA)
            else { return nil }
            return LimiteModele(modele: modele, fenetre: fenetre)
        }
    }

    /// Les crédits d'utilisation, datés par **leur** réponse. `nil` quand la réponse n'en
    /// dit rien, ou pas assez pour les chiffrer juste : sans devise ni `decimal_places`,
    /// « 17000 » n'est pas un montant — le diviser par cent serait faux pour une devise
    /// sans décimales. Quand `extra_usage` ne dit rien de l'argent, le solde de `spend`
    /// suffit seul à faire une réserve.
    ///
    /// ⚠️ Aucune échéance : l'API n'en publie pas, « le 1er du mois » est un calcul de client.
    static func decoderUsagePayant(_ donnees: Data, mesureA: Date) -> UsagePayant? {
        lireUsagePayant(donnees, mesureA: mesureA).usage
    }

    /// Comme `decoderUsagePayant`, en disant en plus quelle nature d'argent la réponse
    /// publiait sans qu'on puisse la lire — un chiffre mal typé, un montant sans unité
    /// lisible, un bloc qui n'est pas un objet.
    static func lireUsagePayant(_ donnees: Data, mesureA: Date)
        -> (usage: UsagePayant?, illisible: Set<UsagePayant.Nature>) {
        guard let reponse = try? JSONDecoder().decode(ReponseUsage.self, from: donnees) else { return (nil, []) }
        guard let credits = reponse.creditsUtilisation else {
            return soldeSeul(reponse.depense, mesureA: mesureA)
        }
        if credits.formeInattendue { return (nil, [.depense]) }
        let argentPublie = credits.consomme != nil || credits.plafondMensuel != nil
        guard let code = credits.devise, let decimales = credits.decimales,
              Montant.exposantsAdmis.contains(decimales), Montant.Unite.devise(code).estReconnue
        else {
            return argentPublie ? (nil, [.depense]) : soldeSeul(reponse.depense, mesureA: mesureA)
        }
        let unite = Montant.Unite.devise(code)

        // Un chiffre publié qui ne fait pas de montant fait tomber la ligne entière : un
        // plafond perdu laisserait lire « 25,74 € » comme une dépense sans limite.
        var consomme: Montant?
        if let publie = credits.consomme {
            guard let valeur = publie.valeur,
                  let lu = montant(valeur, unite: unite, decimales: decimales) else { return (nil, [.depense]) }
            consomme = lu
        }
        var plafond: Montant?
        if let publie = credits.plafondMensuel {
            guard let valeur = publie.valeur,
                  let lu = montant(valeur, unite: unite, decimales: decimales) else { return (nil, [.depense]) }
            plafond = lu
        }
        // Le solde n'est qu'un complément : d'une autre devise, ou illisible, il se tait seul.
        let solde = reponse.depense?.solde.flatMap { brut -> Montant? in
            guard brut.devise == code else { return nil }
            return montant(brut.unitesMineures, unite: unite, decimales: brut.exposant)
        }

        let usage = UsagePayant(nature: .depense,
                           unite: unite,
                           consomme: consomme,
                           plafond: plafond,
                           solde: solde,
                           utilisation: nil,
                           illimite: nil,
                           actif: credits.actif,
                           bloque: credits.plafondAtteint == true,
                           motif: nonVide(credits.motif),
                           echeance: nil,
                           mesureA: mesureA)
        return usage.map { ($0, []) } ?? soldeSeul(reponse.depense, mesureA: mesureA)
    }

    /// Le solde prépayé de `spend`, quand `extra_usage` ne dit rien de l'argent : une réserve,
    /// dans **sa** devise, la seule que la réponse publie alors.
    private static func soldeSeul(_ depense: DepenseBrute?, mesureA: Date)
        -> (usage: UsagePayant?, illisible: Set<UsagePayant.Nature>) {
        guard let depense, depense.soldePublie else { return (nil, []) }
        let unite = depense.solde.map { Montant.Unite.devise($0.devise) }
        guard let brut = depense.solde, let unite,
              let solde = montant(brut.unitesMineures, unite: unite, decimales: brut.exposant),
              let usage = UsagePayant(nature: .solde, unite: unite, consomme: nil, plafond: nil,
                                      solde: solde, utilisation: nil, illimite: nil, actif: nil,
                                      bloque: false, motif: nil, echeance: nil, mesureA: mesureA)
        else { return (nil, [.solde]) }
        return (usage, [])
    }

    /// Un nombre d'unités mineures tel que publié, sans passer par `Double`. Des décimales
    /// au-delà de l'unité mineure (`2574.5` centimes) allongent l'exposant au lieu d'être
    /// arrondies : 25,745 €, exactement.
    ///
    /// ⛔ L'exposant publié est validé **avant** toute somme, et la somme est contrôlée :
    /// `exponent: Int.max` ferait sinon planter l'app sur une simple réponse du serveur.
    private static func montant(_ valeur: Decimal, unite: Montant.Unite, decimales: Int) -> Montant? {
        guard Montant.exposantsAdmis.contains(decimales),
              let ecrit = Montant(texteDecimal: valeur.description, unite: unite) else { return nil }
        let (exposant, deborde) = decimales.addingReportingOverflow(ecrit.exposant)
        guard !deborde else { return nil }
        return Montant(unitesMineures: ecrit.unitesMineures, unite: unite, exposant: exposant)
    }

    /// La formule, par la table fermée de `Formule` : un code qu'elle ne connaît pas ne
    /// donne rien.
    static func decoderFormule(_ donnees: Data) -> Formule? {
        guard let reponse = try? JSONDecoder().decode(ReponseProfil.self, from: donnees) else { return nil }
        return Formule.claude(typeOrganisation: reponse.organisation?.type?.valeur,
                              palier: reponse.organisation?.palier?.valeur)
    }
}
