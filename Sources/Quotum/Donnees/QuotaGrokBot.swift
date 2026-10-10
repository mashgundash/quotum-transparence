import Foundation

/// Ce qu'un relevé direct de Grok Bot établit.
///
/// Grok Bot est un agent « toujours actif » construit, hébergé et facturé par Cursor :
/// son quota ne vit ni chez Grok ni chez X mais sur le compte Cursor, dans une réserve
/// hebdomadaire **séparée** du forfait mensuel que lit déjà `QuotaCursor`. L'identité
/// vient du même jeton que `QuotaCursor` — un JWT porteur de son `sub` et de son
/// `email` —, donc aucun second appel n'est fait pour la demander.
struct MesureGrokBot: Sendable, Equatable {
    var quota: Quota
    var mesureA: Date = .now
    var courriel: String?
    /// Identifiant tiré du `sub` du JWT. Clé d'appariement, au même titre que chez Cursor.
    var utilisateurIdentifiant: String?
}

/// Ce que la lecture du jeton de l'éditeur Cursor puis l'appel à `GetSandUsageStatus` ont
/// pu établir. Même partition que `ResultatCursor` : un jeton refusé ne dit rien du quota,
/// une coupure encore moins.
enum ReleveGrokBot: Sendable, Equatable {
    case releve(MesureGrokBot)
    /// Jeton présent mais refusé ou périmé. Le compte peut être plein, c'est l'accès qui
    /// manque, et il se retrouve par une reconnexion dans l'éditeur Cursor.
    case reconnexionNecessaire
    /// L'appel n'a rien établi — réseau coupé, statut inattendu, corps illisible.
    case indetermine
    /// Aucune session Cursor sur cette machine : rien à relever.
    case aucun
}

/// Relevé direct du quota Grok Bot.
///
/// ⛔ **Aucune source d'identifiants nouvelle, et aucun rafraîchissement.** Le jeton est
/// le `cursorAuth/accessToken` que `IdentifiantsCursor` lit déjà dans la base de l'éditeur
/// Cursor : on le relit en lecture seule, exactement comme `QuotaCursor`, et on ne touche
/// jamais au `refreshToken` voisin — le consommer déconnecterait l'éditeur.
///
/// ⛔ **La route `api2.cursor.sh` admet une requête minimale.** Cinq clients tiers
/// l'appellent avec le seul `Bearer`, sans les en-têtes du client officiel
/// (`x-cursor-client-type: sand`, `x-cursor-checksum`, `x-sand-box-namespace`…) : les
/// reprendre reviendrait à se déguiser en client officiel, ce que la garde réseau
/// interdit. L'app s'annonce sous son propre `User-Agent`.
///
/// ⚠️ Aucune réponse réelle n'a pu être observée : aucun compte Grok Bot ni éditeur Cursor
/// n'existe sur cette machine. La forme des champs est établie par des sources tierces
/// (lecteurs libres, tickets), jamais mesurée ici.
enum QuotaGrokBot {
    static let hote = "https://api2.cursor.sh"
    static let chemin = "/aiserver.v1.DashboardService/GetSandUsageStatus"

    /// L'app s'annonce sous son propre nom, jamais sous celui du client officiel « sand ».
    static let agent = "Quotum"

    /// La réserve incluse dure sept jours, ancrée sur chaque compte et non glissante : la
    /// fenêtre est donc de sorte 7 j, avec son échéance, et surtout pas `.glissante`.
    static let dureeSemaine: TimeInterval = 604_800

    /// Ce qu'un appel a rapporté. Le refus de jeton se distingue de l'échec ordinaire
    /// parce qu'il se règle par une reconnexion, là où l'autre ne demande rien.
    enum ReponseAPI: Sendable, Equatable {
        case donnees(Data)
        case jetonRefuse
        case echec
    }

    static func relever(session: URLSession = Reseau.session,
                        delai: TimeInterval = 8,
                        maintenant: Date = .now) async -> ReleveGrokBot {
        switch await IdentifiantsCursor.jeton() {
        case .jeton(let jeton):
            return await relever(jeton: jeton, session: session, delai: delai, maintenant: maintenant)
        case .absent:
            return .aucun
        // Une lecture empêchée n'établit pas l'absence de session : la prendre pour telle
        // effacerait une mesure que rien n'a infirmée.
        case .empechee:
            return .indetermine
        }
    }

    static func relever(jeton: JetonCursor,
                        session: URLSession = Reseau.session,
                        delai: TimeInterval = 8,
                        maintenant: Date = .now) async -> ReleveGrokBot {
        // ⛔ Un `exp` dépassé se constate sans appel, et ne se répare pas ici : le jeton
        // se renouvelle par une reconnexion dans l'éditeur, jamais en le rafraîchissant.
        if let expireA = jeton.expireA, expireA <= maintenant { return .reconnexionNecessaire }

        let reponse = await charger(jeton: jeton, session: session, delai: delai)
        let mesureA = Date()

        switch reponse {
        case .jetonRefuse:
            return .reconnexionNecessaire
        case .echec:
            return .indetermine
        case .donnees(let donnees):
            guard let quota = decoderUsage(donnees, maintenant: mesureA) else { return .indetermine }
            return .releve(MesureGrokBot(quota: quota,
                                         mesureA: mesureA,
                                         courriel: jeton.courriel,
                                         utilisateurIdentifiant: jeton.utilisateurIdentifiant))
        }
    }

    /// ⚠️ Le `Bearer` se pose **sur la requête**, jamais dans la configuration de session :
    /// CFNetwork rejoue celle-ci sur la cible d'une redirection, autre hôte compris.
    static func requete(jeton: JetonCursor, delai: TimeInterval) -> URLRequest? {
        // Le secret ne doit jamais partir vers un autre hôte : s'il ne peut voyager tel
        // quel dans un en-tête, on préfère ne pas appeler plutôt que de l'assainir.
        guard QuotaCursor.transportable(jeton.valeur),
              let url = URL(string: hote + chemin) else { return nil }
        var requete = URLRequest(url: url)
        requete.httpMethod = "POST"
        requete.timeoutInterval = delai
        // Corps vide `{}` : la route ne prend aucun paramètre, et le compte est celui du jeton.
        requete.httpBody = Data("{}".utf8)
        requete.setValue("Bearer \(jeton.valeur)", forHTTPHeaderField: "Authorization")
        requete.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Connect-RPC : la seule en-tête de protocole, déjà admise pour Windsurf. Rien du
        // client officiel « sand » ne l'accompagne.
        requete.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        requete.setValue(agent, forHTTPHeaderField: "User-Agent")
        return requete
    }

    private static func charger(jeton: JetonCursor,
                                session: URLSession,
                                delai: TimeInterval) async -> ReponseAPI {
        guard let requete = requete(jeton: jeton, delai: delai) else { return .echec }

        do {
            let (donnees, reponse) = try await session.data(for: requete,
                                                            delegate: RedirectionMemeHoteSeulement(hote: "api2.cursor.sh"))
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            journaliser(code: code)
            return interpreter(code: code, donnees: donnees)
        } catch {
            Journal.donnees.debug("Quota Grok Bot : api2.cursor.sh injoignable")
            return .echec
        }
    }

    /// Le jeton se renouvelle par une reconnexion dans l'éditeur, jamais en réessayant :
    /// le 401 est le seul statut dont l'utilisateur ait quelque chose à faire.
    static func interpreter(code: Int, donnees: Data) -> ReponseAPI {
        switch code {
        case 200: .donnees(donnees)
        case 401, 403: .jetonRefuse
        default: .echec
        }
    }

    private static func journaliser(code: Int) {
        switch code {
        case 200:
            break
        case 401, 403:
            Journal.donnees.notice("Quota Grok Bot : jeton refusé (\(code)), reconnexion à faire dans l'éditeur Cursor")
        default:
            Journal.donnees.notice("Quota Grok Bot : statut HTTP \(code)")
        }
    }

    // MARK: - Analyses pures

    /// ⚠️ Les champs sont établis par des sources tierces, jamais observés ici.
    ///
    /// Quatre d'entre eux décident s'il y a une fenêtre à montrer :
    /// - `usesPooledEnterpriseAllowance` : siège mutualisé, aucune allocation propre.
    /// - `includedLimitZero`, et à défaut l'ancien drapeau `hasNonZeroIncludedLimit`,
    ///   disent si le compte a une allocation payante. Le premier l'emporte.
    /// - `sandTrialExpiresAt` ne fait un essai que sur un compte **sans** allocation
    ///   payante, et tant que la date n'est pas passée : un payant qui porte encore ce
    ///   champ garde sa recharge hebdomadaire, et un essai expiré n'a plus rien à jauger.
    private struct ReponseSand: Decodable {
        var usagePercent: NombreProto?
        var nextResetTimestampUtc: Horodatage?
        var includedLimitZero: Bool?
        var hasNonZeroIncludedLimit: Bool?
        var usesPooledEnterpriseAllowance: Bool?
        var sandTrialExpiresAt: Horodatage?
    }

    /// ⛔ Un pourcentage absent ou non fini ne fait **aucune** fenêtre — il n'est pas un
    /// zéro : zéro dirait une grille pleine, feu vert pour un gros travail, sur un compte
    /// dont on ne sait rien. Le quota est alors vide, et l'interface n'affiche pas de
    /// jauge. `nil` reste réservé à ce qui n'est même pas un objet JSON.
    ///
    /// ⚠️ `hasAvailableUsage` n'est volontairement pas lu : un `usagePercent` à 100 avec
    /// l'usage à la demande qui a pris le relais n'est pas un épuisement, et Quotum ne
    /// déduit jamais d'épuisement d'un pourcentage — seule une constatation le ferait, et
    /// cette route n'en publie pas. Le dépassement, facturé en dollars, relève de l'usage
    /// payant, que `GetSandUsageStatus` ne porte pas (c'est une autre route, non appelée).
    ///
    /// ⚠️ Ni `includedLimitZero` ni `hasNonZeroIncludedLimit` publié : la réponse de
    /// `api2.cursor.sh` est du JSON Connect, où proto3 omet un booléen faux — l'absence
    /// des deux est d'abord celle d'un `includedLimitZero: false`, donc d'un payant. Sauf
    /// si un essai est déclaré : c'est alors lui qui décide.
    static func decoderUsage(_ donnees: Data, maintenant: Date = .now) -> Quota? {
        guard let reponse = try? JSONDecoder().decode(ReponseSand.self, from: donnees) else {
            return nil
        }
        if reponse.usesPooledEnterpriseAllowance == true { return Quota([]) }

        let allocationPubliee = reponse.includedLimitZero.map { !$0 } ?? reponse.hasNonZeroIncludedLimit
        let finEssai = reponse.sandTrialExpiresAt?.date
        let payant: Bool
        let essaiEnCours: Bool
        switch allocationPubliee {
        case true?:
            payant = true
            essaiEnCours = false
        case false?:
            payant = false
            essaiEnCours = finEssai.map { $0 > maintenant } ?? false
        case nil:
            payant = finEssai == nil
            essaiEnCours = finEssai.map { $0 > maintenant } ?? false
        }
        // Ni allocation ni essai en cours : compte mesuré, mais rien à jauger. Un essai
        // expiré ne garde pas sa jauge — elle dirait une réserve qui n'existe plus.
        guard payant || essaiEnCours else { return Quota([]) }
        guard let pourcentage = reponse.usagePercent?.valeur else { return Quota([]) }

        guard let fenetre = Fenetre(libelle: Fenetre.libelleSeptJours,
                                    sorte: .septJours,
                                    utilisation: pourcentage,
                                    // Un essai ne se recharge pas : son expiration ne rend
                                    // pas le quota, elle le ferme.
                                    seRechargeA: payant ? reponse.nextResetTimestampUtc?.date : nil,
                                    duree: payant ? dureeSemaine : nil) else { return Quota([]) }
        return Quota(fenetre)
    }

    /// Le même décodeur de pourcentage que `QuotaGrok` : proto3 écrit un entier 64 bits en
    /// chaîne, et les valeurs non finies en toutes lettres (`"NaN"`, `"Infinity"`), que
    /// `Double(_: String)` accepte là où le décodeur JSON les rejette.
    private struct NombreProto: Decodable {
        let valeur: Double?

        init(from decodeur: Decoder) throws {
            let conteneur = try decodeur.singleValueContainer()
            if let nombre = try? conteneur.decode(Double.self) {
                valeur = nombre.isFinite ? nombre : nil
            } else if let texte = try? conteneur.decode(String.self),
                      let nombre = Double(texte.trimmingCharacters(in: .whitespaces)),
                      nombre.isFinite {
                valeur = nombre
            } else {
                valeur = nil
            }
        }
    }
}
