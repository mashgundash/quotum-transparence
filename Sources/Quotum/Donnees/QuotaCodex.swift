import Foundation

/// Ce qu'un relevé direct de ChatGPT établit. Pendant de `ReleveAnthropic`, et sous
/// la même réserve : il ne vaut que pour le compte dont `auth.json` détient le jeton,
/// jamais pour ses voisins.
struct ReleveChatGPT: Sendable, Equatable {
    /// `nil` quand la réponse ne publie aucune fenêtre du forfait mais porte un solde de
    /// crédits ou une réserve : ceux-ci se transmettent seuls, sans fenêtre fabriquée.
    var quota: Quota?
    var mesureA: Date = .now
    var courriel: String?
    var plan: String?
    /// Rendu par l'API ; `compteProuve` : nommé d'un même accord par les jetons du fichier lu.
    var compteIdentifiant: String?, compteProuve: String?
    /// Le serveur a refusé le compte faute de crédit. C'est une constatation, pas une
    /// déduction sur le pourcentage : elle seule autorise à écrire « quota épuisé ».
    var limiteAtteinte = false
    /// Échéance de la fenêtre saturée, quand une l'est.
    var retour: Date?
    /// Réinitialisations anticipées encore disponibles — les « rate limit reset
    /// credits » d'OpenAI. ⚠️ Ressource **rare et périssable** : offertes par OpenAI ou
    /// gagnées par parrainage, elles périment au bout de trente jours.
    /// `nil` veut dire que la réponse n'en parle pas, ce qui n'est pas zéro.
    var reinitialisationsDisponibles: Int?
    var horsQuota = HorsQuotaChatGPT()
}

/// Ce que la lecture d'`auth.json` puis l'appel à l'API ont pu établir. Même
/// partition que `ReleveTrousseau` : un jeton refusé ne dit rien du quota, et une
/// coupure encore moins.
enum ReleveCodex: Sendable, Equatable {
    case releve(ReleveChatGPT)
    /// Jeton présent mais refusé. Ne dit rien du quota : le compte peut être plein,
    /// c'est l'accès qui manque, et il se retrouve par un `codex login`.
    case reconnexionNecessaire
    /// L'appel n'a rien établi — réseau coupé, statut inattendu, corps illisible.
    case indetermine
    /// Aucun jeton ChatGPT sur cette machine : rien à relever.
    case aucun
}

/// Relevé direct du quota ChatGPT, calqué sur `QuotaAnthropic`. Il vient **en plus**
/// de ce que `codex-proxy` publie : le proxy tient ses pourcentages des en-têtes de la
/// dernière requête d'un compte — parfois vieux de plusieurs heures — là où cet appel
/// interroge l'API et date sa réponse de l'instant. Un seul compte en bénéficie, celui
/// du dernier `codex login`, exactement comme le Trousseau côté Claude.
enum QuotaCodex {
    static let hote = "https://chatgpt.com"
    static let chemin = "/backend-api/wham/usage"

    /// Ce qu'un appel a rapporté. Le refus de jeton se distingue de l'échec ordinaire
    /// parce qu'il se règle par une reconnexion, là où l'autre ne demande rien.
    enum ReponseAPI: Sendable, Equatable {
        case donnees(Data)
        case jetonRefuse
        case echec
    }

    static func relever(session: URLSession = Reseau.session,
                        delai: TimeInterval = 8,
                        fichier: URL? = nil,
                        cheminSansLien: Bool = false) async -> ReleveCodex {
        switch await IdentifiantsCodex.jeton(fichier: fichier, cheminSansLien: cheminSansLien) {
        case .jeton(let jeton):
            return await relever(jeton: jeton, session: session, delai: delai)
        case .jetonPersonnel(let jeton):
            return await QuotaCodexJetonPersonnel.relever(jeton: jeton, session: session, delai: delai)
        case .absent:
            return .aucun
        // Une lecture empêchée n'établit pas l'absence de session : la prendre pour
        // telle effacerait une mesure que rien n'a infirmée.
        case .empechee:
            return .indetermine
        }
    }

    static func relever(jeton: JetonCodex,
                        session: URLSession = Reseau.session,
                        delai: TimeInterval = 8) async -> ReleveCodex {
        let reponse = await charger(jeton: jeton, session: session, delai: delai)
        let mesureA = Date()

        switch reponse {
        case .jetonRefuse:
            return .reconnexionNecessaire
        case .echec:
            return .indetermine
        case .donnees(let donnees):
            let resultat = analyser(donnees, mesureA: mesureA)
            guard case .releve(var releve) = resultat, case .prouve(let compte) = jeton.compteProuve else {
                return resultat
            }
            releve.compteProuve = compte
            return .releve(releve)
        }
    }

    /// Ce qu'un corps de `wham/usage` établit, quelle que soit la connexion qui l'a obtenu.
    static func analyser(_ donnees: Data, mesureA: Date) -> ReleveCodex {
        var quota = decoderUsage(donnees)
        quota?.limitesModele = decoderLimitesModele(donnees)
        let horsQuota = decoderHorsQuota(donnees, mesureA: mesureA)
        // Ni fenêtre, ni argent, ni réserve : la réponse n'a rien mesuré. La formule seule
        // n'est pas une mesure. Sur Business, `rate_limit` vaut `null` : le compte vit
        // alors de sa limite de dépense, sans fenêtre fabriquée.
        guard quota != nil || !horsQuota.usages.isEmpty || horsQuota.reserve != nil else {
            return .indetermine
        }
        let identite = decoderIdentite(donnees)
        let blocage = decoderBlocage(donnees)
        return .releve(ReleveChatGPT(quota: quota,
                                     mesureA: mesureA,
                                     courriel: identite.courriel,
                                     plan: identite.plan,
                                     compteIdentifiant: identite.compteIdentifiant,
                                     limiteAtteinte: blocage.atteinte,
                                     retour: blocage.retour,
                                     reinitialisationsDisponibles: decoderReinitialisations(donnees),
                                     horsQuota: horsQuota))
    }

    /// L'app s'annonce sous son propre nom. Se faire passer pour le client officiel
    /// stabiliserait peut-être l'accès à cet endpoint — c'est une infraction d'une
    /// autre nature que de lire un jeton qu'on a le droit de lire.
    static let agent = "Quotum"

    static func requete(jeton: JetonCodex, delai: TimeInterval) -> URLRequest? {
        guard let url = URL(string: hote + chemin) else { return nil }
        var requete = URLRequest(url: url)
        requete.httpMethod = "GET"
        requete.timeoutInterval = delai
        requete.setValue("Bearer \(jeton.valeur)", forHTTPHeaderField: "Authorization")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue(agent, forHTTPHeaderField: "User-Agent")
        // Mesuré le 2026-09-17 : sans cet en-tête l'appel répond bien 200, mais
        // `account_id` revient vide — la réponse ne nomme plus le compte qu'elle
        // décrit, et il n'y a plus de quoi la poser sur une ligne.
        if let compte = jeton.compteIdentifiant {
            requete.setValue(compte, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return requete
    }

    private static func charger(jeton: JetonCodex,
                                session: URLSession,
                                delai: TimeInterval) async -> ReponseAPI {
        guard let requete = requete(jeton: jeton, delai: delai) else { return .echec }

        do {
            let (donnees, reponse) = try await session.data(for: requete)
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            journaliser(code: code)
            return interpreter(code: code, donnees: donnees)
        } catch {
            Journal.donnees.debug("Quota Codex : chatgpt.com injoignable")
            return .echec
        }
    }

    /// Le jeton d'`auth.json` se renouvelle par un `codex login`, jamais en
    /// réessayant : le 401 est le seul statut dont l'utilisateur ait quelque chose à
    /// faire. Mesuré le 2026-09-17 — un jeton illisible comme un en-tête absent
    /// rendent tous deux 401, en JSON.
    static func interpreter(code: Int, donnees: Data) -> ReponseAPI {
        switch code {
        case 200: .donnees(donnees)
        case 401: .jetonRefuse
        default: .echec
        }
    }

    private static func journaliser(code: Int) {
        switch code {
        case 200:
            break
        case 401:
            Journal.donnees.notice("Quota Codex : jeton refusé (401), `codex login` à refaire")
        default:
            Journal.donnees.notice("Quota Codex : statut HTTP \(code)")
        }
    }

    // MARK: - Analyses pures

    /// ⚠️ Chaque champ est décodé à part (`Souple`) : un champ annexe d'un autre type que
    /// prévu — `available_count: "un"` — ne devient absent qu'à lui seul, au lieu d'emporter
    /// avec lui les fenêtres et l'identité du compte.
    private struct ReponseUsage: Decodable {
        struct FenetreAPI: Decodable {
            var pourcentage: Souple<Double>?
            var dureeSecondes: Souple<Double>?
            var seRechargeA: Horodatage?

            enum CodingKeys: String, CodingKey {
                case pourcentage = "used_percent"
                case dureeSecondes = "limit_window_seconds"
                case seRechargeA = "reset_at"
            }
        }

        struct Limite: Decodable {
            var principale: Souple<FenetreAPI>?
            var secondaire: Souple<FenetreAPI>?
            var atteinte: Souple<Bool>?

            enum CodingKeys: String, CodingKey {
                case principale = "primary_window"
                case secondaire = "secondary_window"
                case atteinte = "limit_reached"
            }
        }

        /// Le compteur de réinitialisations voyage dans la même réponse que le quota :
        /// rien de plus n'est demandé au serveur pour l'obtenir.
        struct Reinitialisations: Decodable {
            var disponibles: Souple<Int>?

            enum CodingKeys: String, CodingKey {
                case disponibles = "available_count"
            }
        }

        var limite: Souple<Limite>?
        var courriel: Souple<String>?
        var plan: Souple<String>?
        var compteIdentifiant: Souple<String>?
        var reinitialisations: Souple<Reinitialisations>?

        enum CodingKeys: String, CodingKey {
            case limite = "rate_limit"
            case courriel = "email"
            case plan = "plan_type"
            case compteIdentifiant = "account_id"
            case reinitialisations = "rate_limit_reset_credits"
        }
    }

    private static func reponseUsage(_ donnees: Data) -> ReponseUsage? {
        try? JSONDecoder().decode(ReponseUsage.self, from: donnees)
    }

    private static let secondesParJour: TimeInterval = 86_400

    /// La sorte d'une fenêtre, lue dans sa durée **exacte** — le seul fournisseur
    /// implémenté qui la publie. Une durée qu'on ne reconnaît pas reste `.inconnue` :
    /// la ranger dans la plus proche lui prêterait un sigle faux, et une fenêtre d'un
    /// mois étiquetée « 7 j » dirait une recharge trois semaines trop tôt.
    ///
    /// Un mois n'a pas de durée fixe : de 28 à 31 jours, bornes comprises.
    private static func sorte(dureeSecondes: TimeInterval) -> Fenetre.Sorte {
        switch dureeSecondes {
        case 18_000: .cinqHeures
        case secondesParJour: .vingtQuatreHeures
        case 7 * secondesParJour: .septJours
        case 14 * secondesParJour: .quinzaine
        case (28 * secondesParJour)...(31 * secondesParJour): .mois
        default: .inconnue
        }
    }

    /// Une fenêtre sans sigle se lit sous son nom, au-dessus de la jauge : faute de
    /// sorte, c'est sa durée publiée qui la nomme, dans la langue servie.
    private static func libelle(sorte: Fenetre.Sorte, dureeSecondes: TimeInterval) -> String {
        switch sorte {
        case .cinqHeures: Fenetre.libelleCinqHeures
        case .vingtQuatreHeures: Fenetre.libelleVingtQuatreHeures
        case .septJours: Fenetre.libelleSeptJours
        case .quinzaine: Fenetre.libelleQuinzaine
        case .mois: Fenetre.libelleMois
        case .glissante, .cycle, .inconnue:
            Duration.seconds(dureeSecondes)
                .formatted(.units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 2)
                    .locale(Langue.locale))
        }
    }

    /// La fabrique des fenêtres de ChatGPT. Les deux lecteurs du fournisseur passent
    /// par ici — celui de l'API et celui des rollouts — parce qu'une règle écrite deux
    /// fois ne reçoit sa prochaine correction que d'un seul côté, et que l'erreur
    /// qu'elle produirait est silencieuse : une semaine affichée dans la jauge de cinq
    /// heures.
    ///
    /// La durée est en secondes ; les rollouts, qui la publient en minutes, la
    /// convertissent avant d'appeler — et cette conversion déborde à l'infini sur une
    /// valeur pourtant finie. `Fenetre` ne contrôle que son pourcentage : la durée se
    /// vérifie ici, pour les deux lecteurs à la fois.
    static func fenetreClassee(utilisation: Double,
                               dureeSecondes: TimeInterval,
                               seRechargeA: Date?) -> Fenetre? {
        guard dureeSecondes.isFinite, dureeSecondes > 0 else { return nil }
        let sorte = sorte(dureeSecondes: dureeSecondes)
        return Fenetre(libelle: libelle(sorte: sorte, dureeSecondes: dureeSecondes),
                       sorte: sorte,
                       utilisation: utilisation,
                       seRechargeA: seRechargeA,
                       duree: dureeSecondes)
    }

    /// De la plus courte à la plus longue, par la durée publiée — jamais par la place
    /// dans la réponse. Deux fenêtres de même sorte n'en font qu'une, la première
    /// publiée ; deux durées inconnues distinctes restent deux fenêtres.
    static func ordonner(_ fenetres: [Fenetre]) -> [Fenetre] {
        let triees = fenetres.enumerated().sorted {
            ($0.element.duree ?? .infinity, $0.offset) < ($1.element.duree ?? .infinity, $1.offset)
        }.map(\.element)
        var vues: Set<String> = []
        return triees.filter { fenetre in
            let cle = fenetre.sorte == .inconnue ? "inconnue:\(fenetre.duree ?? -1)" : "\(fenetre.sorte)"
            return vues.insert(cle).inserted
        }
    }

    /// ⚠️ Deux pièges, tous deux mesurés le 2026-09-17 sur une réponse réelle.
    ///
    /// La **place ne dit pas la durée** : `primary_window` du compte portait
    /// 604 800 s (7 j), tandis que la `primary_window` d'une entrée
    /// d'`additional_rate_limits` portait 18 000 s (5 h). Ranger les fenêtres par leur
    /// rang les échangerait un jour sur deux ; c'est `limit_window_seconds` qui tranche.
    ///
    /// Et `additional_rate_limits` n'est **pas** le niveau du compte : ce sont des
    /// limites par modèle. La ligne « GPT-5.3-Codex-Spark » affichait 0 % pendant que
    /// le compte était refusé à 100 % — même piège que `seven_day_breakdown` côté
    /// Anthropic, avec le même effet : dire l'inverse du vrai.
    static func decoderUsage(_ donnees: Data) -> Quota? {
        // La fenêtre de 5 h dépend de la formule : une formule qui ne publierait qu'elle
        // a son quota comme une autre. Aucune fenêtre n'est inventée pour compléter.
        // La courte d'abord : l'ordre de la liste est celui du tiroir.
        let publiees = ordonner(fenetres(donnees))
        guard !publiees.isEmpty else { return nil }
        return Quota(publiees)
    }

    /// `limit_reached` est un refus constaté par le serveur, pas une lecture du
    /// pourcentage — et `allowed` n'est volontairement pas consulté : il retombe aussi
    /// sur un plafond de dépense, où affirmer « quota épuisé » dirait plus que ce
    /// qu'on sait.
    static func decoderBlocage(_ donnees: Data) -> (atteinte: Bool, retour: Date?) {
        guard let limite = reponseUsage(donnees)?.limite?.valeur,
              limite.atteinte?.valeur == true else { return (false, nil) }
        // Le retour est l'échéance la plus lointaine des fenêtres saturées, et il n'est
        // connu que si toutes la publient : une fenêtre bloquante sans échéance peut durer
        // au-delà de celle des autres. Une fenêtre publiée mais illisible peut être celle
        // qui bloque, et rend le retour tout aussi inconnu.
        let classees = [limite.principale, limite.secondaire].compactMap { $0 }.map { classer($0.valeur) }
        guard !classees.contains(where: { $0 == nil }) else { return (true, nil) }
        let echeances = classees.compactMap { $0 }
            .filter { $0.utilisation >= 100 }
            .map(\.seRechargeA)
        guard !echeances.contains(where: { $0 == nil }) else { return (true, nil) }
        return (true, echeances.compactMap { $0 }.max())
    }

    static func decoderIdentite(_ donnees: Data)
        -> (courriel: String?, plan: String?, compteIdentifiant: String?) {
        guard let reponse = reponseUsage(donnees) else { return (nil, nil, nil) }
        return (nonVide(reponse.courriel?.valeur), nonVide(reponse.plan?.valeur),
                nonVide(reponse.compteIdentifiant?.valeur))
    }

    /// ⚠️ `nil` n'est pas zéro. Une réponse qui ne parle pas de réinitialisations ne dit
    /// pas qu'il n'en reste aucune — et la distinction commande l'affichage : un compte
    /// sans compteur ne doit rien montrer, surtout pas « 0 réinitialisation », qui
    /// affirmerait une pénurie que personne n'a relevée. Un compte négatif est traité
    /// comme une absence, pour la même raison.
    static func decoderReinitialisations(_ donnees: Data) -> Int? {
        guard let disponibles = reponseUsage(donnees)?.reinitialisations?.valeur?.disponibles?.valeur,
              disponibles >= 0 else { return nil }
        return disponibles
    }

    private static func fenetres(_ donnees: Data) -> [Fenetre] {
        guard let limite = reponseUsage(donnees)?.limite?.valeur else { return [] }
        return [limite.principale?.valeur, limite.secondaire?.valeur].compactMap(classer)
    }

    private static func classer(_ brute: ReponseUsage.FenetreAPI?) -> Fenetre? {
        // `used_percent` est déjà en 0-100, contrairement à l'API d'Anthropic. Le
        // bornage — et le refus d'une valeur non finie — est celui de `Fenetre`.
        guard let brute, let pourcentage = brute.pourcentage?.valeur, let duree = brute.dureeSecondes?.valeur
        else { return nil }
        return fenetreClassee(utilisation: pourcentage, dureeSecondes: duree, seRechargeA: brute.seRechargeA?.date)
    }

    private static func nonVide(_ valeur: String?) -> String? {
        guard let coupe = valeur?.trimmingCharacters(in: .whitespacesAndNewlines), !coupe.isEmpty else {
            return nil
        }
        return coupe
    }
}

/// Ce que la réponse de `/wham/usage` porte hors des fenêtres du compte : le solde de
/// crédits, la réserve de réinitialisations et la formule. Aucun ne demande de requête de plus.
struct HorsQuotaChatGPT: Sendable, Equatable {
    /// Le solde de crédits (`credits`).
    var usagePayant: UsagePayant?
    /// La limite qu'un administrateur Business, Enterprise ou Edu a fixée
    /// (`spend_control.individual_limit`) : consommé contre plafond.
    var limiteDepense: UsagePayant?
    var reserve: ReserveReinitialisations?
    var formule: Formule?
    /// Un solde publié qu'on ne sait pas lire : la mesure gardée reste, voir `UsagesConserves`.
    var argentIllisible: Set<UsagePayant.Nature> = []

    /// La dépense avant la réserve, comme la fusion les range.
    var usages: [UsagePayant] { [limiteDepense, usagePayant].compactMap { $0 } }
}

extension QuotaCodex {
    /// Décodée à part de `ReponseUsage` : un champ hors quota illisible ne peut pas coûter
    /// le relevé des fenêtres.
    private struct ReponseHorsQuota: Decodable {
        struct Credits: Decodable {
            var actif: Souple<Bool>?
            var illimite: Souple<Bool>?
            var depassementAtteint: Souple<Bool>?
            /// ⛔ Une chaîne, jamais un `Double` : `Montant(texteDecimal:)` la lit chiffre à chiffre.
            var solde: Souple<String>?

            enum CodingKeys: String, CodingKey {
                case actif = "has_credits"
                case illimite = "unlimited"
                case depassementAtteint = "overage_limit_reached"
                case solde = "balance"
            }
        }

        struct ControleDepense: Decodable {
            /// Forme RAPPORTÉE, jamais observée sur un compte réel : captures Business de
            /// zioder/TaskbarQuota#102 et cortexkit/openai-auth#158.
            struct LimiteIndividuelle: Decodable {
                var source: Souple<String>?
                var unite: Souple<String>?
                /// ⛔ Des chaînes, jamais des `Double` (`"501.7787666320801"`).
                var plafond: Souple<String>?
                var consomme: Souple<String>?
                var restant: Souple<String>?
                var pourcentage: Souple<Double>?
                var rechargeDans: Souple<Double>?
                var rechargeA: Horodatage?

                enum CodingKeys: String, CodingKey {
                    case source
                    case unite = "unit"
                    case plafond = "limit"
                    case consomme = "used"
                    case restant = "remaining"
                    case pourcentage = "used_percent"
                    case rechargeDans = "reset_after_seconds"
                    case rechargeA = "reset_at"
                }
            }

            var atteint: Souple<Bool>?
            var limite: Souple<LimiteIndividuelle>?

            enum CodingKeys: String, CodingKey {
                case atteint = "reached"
                case limite = "individual_limit"
            }
        }

        struct Reinitialisations: Decodable {
            var disponibles: Souple<Int>?
            var applicables: Souple<Int>?

            enum CodingKeys: String, CodingKey {
                case disponibles = "available_count"
                case applicables = "applicable_available_count"
            }
        }

        struct LimiteAPI: Decodable {
            struct Fenetres: Decodable {
                var principale: Souple<ReponseUsage.FenetreAPI>?
                var secondaire: Souple<ReponseUsage.FenetreAPI>?

                enum CodingKeys: String, CodingKey {
                    case principale = "primary_window"
                    case secondaire = "secondary_window"
                }
            }

            var nom: Souple<String>?
            var limite: Souple<Fenetres>?

            enum CodingKeys: String, CodingKey {
                case nom = "limit_name"
                case limite = "rate_limit"
            }
        }

        var credits: Souple<Credits>?
        var controleDepense: Souple<ControleDepense>?
        var reinitialisations: Souple<Reinitialisations>?
        var limitesModele: Souple<[Souple<LimiteAPI>]>?

        enum CodingKeys: String, CodingKey {
            case credits
            case controleDepense = "spend_control"
            case reinitialisations = "rate_limit_reset_credits"
            case limitesModele = "additional_rate_limits"
        }
    }

    private static func reponseHorsQuota(_ donnees: Data) -> ReponseHorsQuota? {
        try? JSONDecoder().decode(ReponseHorsQuota.self, from: donnees)
    }

    static func decoderHorsQuota(_ donnees: Data, mesureA: Date) -> HorsQuotaChatGPT {
        let reponse = reponseHorsQuota(donnees)
        let illisible = reponse.map(soldeIllisible) ?? false
        let controle = reponse?.controleDepense
        let limite = controle?.valeur?.limite
        let limiteDepense = limite?.valeur.flatMap { limiteDepense($0, reponse: reponse, mesureA: mesureA) }
        var illisibles: Set<UsagePayant.Nature> = illisible ? [.solde] : []
        // Publiée mais illisible — le contrôle entier, sa limite, ou un seul de ses champs : la
        // limite déjà mesurée reste, comme un solde illisible. Un contrôle illisible n'est pas
        // l'absence de limite.
        if (controle != nil && controle?.valeur == nil) || (limite != nil && limiteDepense == nil) {
            illisibles.insert(.depense)
        }
        return HorsQuotaChatGPT(usagePayant: illisible ? nil : reponse.flatMap { usagePayant($0, mesureA: mesureA) },
                                limiteDepense: limiteDepense,
                                reserve: reponse.flatMap(reserve),
                                formule: Formule.codex(plan: decoderIdentite(donnees).plan),
                                argentIllisible: illisibles)
    }

    /// `individual_limit: null` ne fait rien : pas de limite, rien à dire.
    ///
    /// ⛔ Un montant, une unité ou un pourcentage publié mais illisible rend `nil` : la mesure
    /// entière est illisible. Rendue sans ce champ, elle remplacerait la précédente — « 0 %
    /// utilisé » —, clorait l'épisode de dépense, et la mesure lisible suivante le rouvrirait
    /// en une seconde alerte. Une échéance illisible, elle, ne fait que se taire.
    ///
    /// ⚠️ Une unité autre que `credit` ne prête son unité à aucun montant : il ne reste que le
    /// pourcentage, sans somme inventée.
    private static func limiteDepense(_ brute: ReponseHorsQuota.ControleDepense.LimiteIndividuelle,
                                      reponse: ReponseHorsQuota?,
                                      mesureA: Date) -> UsagePayant? {
        if let unite = brute.unite, unite.valeur == nil { return nil }
        let enCredits = brute.unite?.valeur == "credit"
        var illisible = false
        let montant = { (champ: Souple<String>?) -> Montant? in
            guard enCredits, let champ else { return nil }
            guard let lu = champ.valeur.flatMap({ Montant(texteDecimal: $0, unite: .credits) }) else {
                illisible = true
                return nil
            }
            return lu
        }
        let consomme = montant(brute.consomme)
        let plafond = montant(brute.plafond)
        let restant = montant(brute.restant)
        let utilisation = brute.pourcentage?.valeur.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if brute.pourcentage != nil, utilisation == nil { illisible = true }
        guard !illisible else { return nil }
        let bloque = (restant.map { $0.unitesMineures <= 0 } ?? false)
            || reponse?.controleDepense?.valeur?.atteint?.valeur == true
        let echeance = brute.rechargeA?.date ?? brute.rechargeDans?.valeur.flatMap { secondes in
            secondes.isFinite && secondes >= 0 ? mesureA.addingTimeInterval(secondes) : nil
        }
        let portee: UsagePayant.Portee = brute.source?.valeur?.hasPrefix("workspace") == true
            ? .espaceDeTravail : .personnelle
        return UsagePayant(nature: .depense,
                           unite: consomme != nil || plafond != nil ? .credits : nil,
                           consomme: consomme,
                           plafond: plafond,
                           solde: nil,
                           utilisation: utilisation,
                           illimite: nil,
                           actif: nil,
                           bloque: bloque,
                           motif: nil,
                           echeance: echeance,
                           mesureA: mesureA,
                           portee: portee)
    }

    /// Un solde présent, non nul, qui ne fait pas de montant. La ligne entière tombe alors,
    /// comme chez Claude : publiée sans son solde, elle chasserait le solde déjà mesuré.
    private static func soldeIllisible(_ reponse: ReponseHorsQuota) -> Bool {
        guard let solde = reponse.credits?.valeur?.solde else { return false }
        return solde.valeur.flatMap { Montant(texteDecimal: $0, unite: .credits) } == nil
    }

    /// `balance: "0"` est une mesure ; une réponse sans `credits`, ou dont `credits` ne dit
    /// rien, n'en est pas une. Le solde peut être négatif (documenté) : il reste tel quel.
    private static func usagePayant(_ reponse: ReponseHorsQuota, mesureA: Date) -> UsagePayant? {
        guard let credits = reponse.credits?.valeur else { return nil }
        let solde = credits.solde?.valeur.flatMap { Montant(texteDecimal: $0, unite: .credits) }
        let actif = credits.actif?.valeur
        let illimite = credits.illimite?.valeur
        let depassement = credits.depassementAtteint?.valeur
        guard solde != nil || actif != nil || illimite != nil || depassement != nil else { return nil }
        // Deux refus constatés par le serveur : le plafond de dépassement, et le contrôle
        // de dépense — qui revient à la limite individuelle dès qu'elle est publiée, lisible
        // ou non. Suivre sa lisibilité ferait passer le même refus d'une nature à l'autre, et
        // chacune a sa propre alerte : une limite illisible garde la mesure précédente.
        let controle = reponse.controleDepense?.valeur
        let bloque = depassement == true || (controle?.atteint?.valeur == true && controle?.limite == nil)
        return UsagePayant(nature: .solde,
                           unite: .credits,
                           consomme: nil,
                           plafond: nil,
                           solde: solde,
                           utilisation: nil,
                           illimite: illimite,
                           actif: actif,
                           bloque: bloque,
                           motif: nil,
                           echeance: nil,
                           mesureA: mesureA)
    }

    /// ⚠️ Mesuré le 29/09 : `applicable_available_count` vaut 0 quand `available_count`
    /// vaut 1, sur un compte à 0 % — rien à rouvrir. Les deux se gardent tels quels ; un
    /// `applicable` absent ou négatif reste `nil`, jamais 0.
    private static func reserve(_ reponse: ReponseHorsQuota) -> ReserveReinitialisations? {
        guard let brute = reponse.reinitialisations?.valeur,
              let disponibles = brute.disponibles?.valeur else { return nil }
        let applicables = brute.applicables?.valeur.flatMap { $0 >= 0 ? $0 : nil }
        return ReserveReinitialisations(disponibles: disponibles, applicables: applicables, expirations: [])
    }

    /// ⛔ Des limites **par modèle**, jamais le niveau du compte : « GPT-5.3-Codex-Spark »
    /// affichait 0 % pendant que le compte était refusé à 100 %. Elles vont dans
    /// `Quota.limitesModele`, que ni la jauge résumée, ni la barre de menus, ni les alertes
    /// ne lisent. La durée publiée classe chaque fenêtre, la courte d'abord.
    static func decoderLimitesModele(_ donnees: Data) -> [LimiteModele] {
        guard let entrees = reponseHorsQuota(donnees)?.limitesModele?.valeur else { return [] }
        return entrees.compactMap(\.valeur).flatMap { entree -> [LimiteModele] in
            guard let nom = entree.nom?.valeur, let limite = entree.limite?.valeur else { return [] }
            let classees = [limite.principale?.valeur, limite.secondaire?.valeur].compactMap(classer)
            return ordonner(classees).compactMap { LimiteModele(modele: nom, fenetre: $0) }
        }
    }
}
