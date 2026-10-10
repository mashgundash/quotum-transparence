import Foundation

/// Le jeton d'identification que Warp dépose au Trousseau. Il sert à un appel et n'est
/// ni copié sur disque, ni journalisé, ni conservé au-delà du relevé.
struct JetonWarp: Sendable {
    let valeur: String
    let expireA: Date?
    /// `local_id` — l'identifiant que Warp garde de l'utilisateur hors ligne. C'est la
    /// seule identité disponible sans second appel : la requête de quota ne demande
    /// pas le profil, et n'a pas à le demander.
    let utilisateurIdentifiant: String?
}

/// Ce qu'une lecture du Trousseau a établi pour Warp — même partition que
/// `LectureTrousseau` et `LectureCodex`, pour la même raison : une lecture empêchée et
/// une absence de session se ressemblent, et une seule des deux conclut.
enum LectureWarp: Sendable {
    case jeton(JetonWarp)
    /// Aucun élément Warp au Trousseau : cette machine n'a pas de session Warp.
    case absent
    /// Lecture empêchée — autorisation refusée, utilitaire injoignable, délai dépassé,
    /// élément lu mais inexploitable. Rien n'est établi.
    case empechee
}

/// Les identifiants de Warp, lus au Trousseau par `/usr/bin/security` — jamais par
/// `SecItemCopyMatching` : l'ACL d'un élément fait confiance au binaire `security`, pas
/// au processus appelant, et Quotum signée en ad-hoc change de `cdhash` à chaque build.
/// Le délai de garde est la seconde raison : `security` attend indéfiniment quand le
/// Trousseau est verrouillé, et le panneau doit rester dessinable pendant ce temps.
enum IdentifiantsWarp {
    /// Identifiant de bundle de l'application stable, relevé dans `app/Cargo.toml` de
    /// Warp. ⚠️ Que Warp s'en serve **aussi** comme nom de service au Trousseau est une
    /// hypothèse : ce nom est calculé à l'exécution et aucune constante publique ne le
    /// fige. D'où la trace explicite quand aucun service ne répond — sans elle, un nom
    /// devenu faux serait indiscernable d'une machine sans Warp.
    static let serviceApplication = "dev.warp.Warp-Stable"
    /// Le TUI range son jeton sous un service voisin. Ne sonder que celui de
    /// l'application graphique raterait un utilisateur qui n'a que le TUI.
    static let serviceTUI = "dev.warp.Warp-Stable.tui"
    static let servicesConnus = [serviceApplication, serviceTUI]

    /// Compte de l'élément. Hypothèse au même titre que le service, d'où la seconde
    /// tentative sans `-a`, qui survit à un changement de cette convention.
    static let compte = "User"

    static func jeton(services: [String] = servicesConnus) async -> LectureWarp {
        var empechee = false

        for service in services {
            switch await lire(service: service) {
            case .jeton(let jeton):
                return .jeton(jeton)
            case .empechee:
                empechee = true
            case .absent:
                continue
            }
        }

        guard !empechee else { return .empechee }
        Journal.donnees.notice("Warp : aucun jeton sous \(servicesConnus.joined(separator: ", "))")
        return .absent
    }

    /// L'invocation de `security` n'a qu'une source, `Trousseau.executerLecture` : seul
    /// le classement du secret est propre à Warp, pas la façon de le lire.
    static func lire(service: String) async -> LectureWarp {
        conclure(await Trousseau.executerLecture(service: service,
                                                 comptes: [compte, nil],
                                                 sujet: "Warp"),
                 service: service)
    }

    /// Même règle que côté Trousseau, et pour le même motif : un jeton obtenu reste
    /// bon quand la tentative suivante n'aboutit pas, mais l'absence, elle, cesse
    /// d'être établie dès qu'une tentative manque. Warp y est deux fois exposé — deux
    /// services connus, deux comptes candidats chacun.
    static func conclure(_ brute: LectureBrute, service: String) -> LectureWarp {
        var empechee = brute.interrompue

        for resultat in brute.resultats {
            switch classer(resultat) {
            case .jeton(let jeton):
                return .jeton(jeton)
            case .empechee:
                // Le code, jamais la sortie : c'est elle qui porte le secret.
                if resultat.reussi {
                    Journal.donnees.notice("Warp : élément « \(service) » lu mais inexploitable")
                } else {
                    Journal.donnees.notice("Warp : lecture de « \(service) » refusée (code \(resultat.code))")
                }
                empechee = true
            case .absent:
                continue
            }
        }

        return empechee ? .empechee : .absent
    }

    /// Le code 44 est le seul qui conclue — l'élément n'existe pas ; tous les autres
    /// disent qu'on n'a pas pu lire, pas qu'il n'y a rien à lire. Une sortie qui ne rend
    /// aucun jeton ne conclut rien non plus : l'élément est là, son contenu échappe.
    static func classer(_ resultat: ResultatProcessus) -> LectureWarp {
        guard resultat.reussi else {
            return resultat.code == Trousseau.codeAbsent ? .absent : .empechee
        }
        guard let jeton = decoder(Data(resultat.sortie.utf8)) else { return .empechee }
        return .jeton(jeton)
    }

    /// ⛔ Le `refresh_token` posé à la racine est déprécié : il n'est pas déclaré ici,
    /// donc jamais lu. Un jeton de rafraîchissement n'ouvre d'ailleurs aucun appel.
    static func decoder(_ donnees: Data) -> JetonWarp? {
        guard let enveloppe = try? JSONDecoder().decode(Enveloppe.self, from: donnees),
              let valeur = nonVide(enveloppe.jeton?.valeur) else { return nil }
        return JetonWarp(valeur: valeur,
                         expireA: enveloppe.jeton?.expireA,
                         utilisateurIdentifiant: nonVide(enveloppe.identifiantLocal))
    }

    /// ⚠️ `id_token` porte un **objet** — sa valeur utile est l'`id_token` intérieur.
    /// Prendre la clé pour une chaîne rendrait `nil` et ferait conclure à l'absence de
    /// session. La chaîne nue est acceptée quand même : rien de public ne fige ce
    /// format, et une variante ferait échouer le lecteur sans un mot.
    private struct JetonImbrique: Decodable {
        var valeur: String?
        var expireA: Date?

        init(from decodeur: Decoder) throws {
            if let nu = try? decodeur.singleValueContainer().decode(String.self) {
                valeur = nu
                expireA = nil
                return
            }
            let conteneur = try decodeur.container(keyedBy: Cles.self)
            valeur = try? conteneur.decode(String.self, forKey: .valeur)
            expireA = (try? conteneur.decode(Horodatage.self, forKey: .expireA))?.date
        }

        enum Cles: String, CodingKey {
            case valeur = "id_token"
            case expireA = "expiration_time"
        }
    }

    private struct Enveloppe: Decodable {
        var jeton: JetonImbrique?
        var identifiantLocal: String?

        enum CodingKeys: String, CodingKey {
            case jeton = "id_token"
            case identifiantLocal = "local_id"
        }
    }

    private static func nonVide(_ valeur: String?) -> String? {
        guard let coupe = valeur?.trimmingCharacters(in: .whitespacesAndNewlines), !coupe.isEmpty else {
            return nil
        }
        return coupe
    }
}

/// Ce qu'un relevé de Warp établit. Warp n'a qu'un compte à la fois — le jeton du
/// Trousseau est le seul — et ne publie qu'une fenêtre.
struct ReleveWarp: Sendable, Equatable {
    var quota: Quota
    var mesureA: Date = .now
    var utilisateurIdentifiant: String?
    /// Le serveur déclare le compte sans plafond. `quota` est alors vide, et ce drapeau
    /// est le seul moyen de distinguer « rien à jauger » de « rien de mesuré » : sans
    /// lui, un compte illimité s'afficherait comme un compte jamais relevé.
    var illimite = false
}

/// Ce que l'appel a pu établir. Nommé `Resultat` et non `ReleveWarp` parce que la
/// source d'identifiants et le fournisseur portent ici le même nom, là où `ReleveCodex`
/// et `ReleveChatGPT` pouvaient se distinguer.
enum ResultatWarp: Sendable, Equatable {
    case releve(ReleveWarp)
    /// Jeton présent mais refusé. Ne dit rien du quota : le compte peut être plein,
    /// c'est l'accès qui manque, et il se retrouve par une reconnexion dans Warp.
    case reconnexionNecessaire
    /// L'appel n'a rien établi — réseau coupé, statut inattendu, corps illisible.
    case indetermine
    /// Aucun jeton Warp sur cette machine : rien à relever.
    case aucun
}

/// Relevé direct du quota Warp, calqué sur `QuotaCodex`. L'API est un GraphQL, ce qui
/// change deux choses : la requête est un POST qui porte son document dans le corps, et
/// un refus applicatif peut arriver en 200 — le champ demandé est simplement absent, et
/// la mesure reste indéterminée plutôt que de se transformer en zéro.
enum QuotaWarp {
    static let adresse = "https://app.warp.dev/graphql/v2"
    static let operation = "GetRequestLimitInfo"

    /// Sélection minimale : les cinq champs qui décrivent le compte, et rien d'autre.
    /// Le chemin vient du schéma publié — `user` rend une union, d'où le fragment sur
    /// `UserOutput` ; la branche d'erreur ne porte pas `requestLimitInfo`, et son
    /// absence suffit à conclure qu'on n'a rien mesuré.
    static let document = """
        query GetRequestLimitInfo($requestContext: RequestContext!) {\
         user(requestContext: $requestContext) {\
         ... on UserOutput { user { requestLimitInfo {\
         isUnlimited requestLimit requestsUsedSinceLastRefresh\
         nextRefreshTime requestLimitRefreshDuration } } } } }
        """

    /// ⛔ `requestLimitRefreshDuration` n'est pas une durée : c'est une énumération, et
    /// c'est le **seul** champ qui classe la fenêtre — Warp ne publie aucune seconde.
    enum Periode: String, Sendable, CaseIterable {
        case hebdomadaire = "WEEKLY"
        case quinzaine = "EVERY_TWO_WEEKS"
        case mensuelle = "MONTHLY"

        var libelle: String {
            switch self {
            case .hebdomadaire: "Cette semaine"
            case .quinzaine: "Ces deux semaines"
            case .mensuelle: Fenetre.libelleMois
            }
        }

        /// Une semaine et une quinzaine ont un nombre de secondes exact, que
        /// l'énumération nomme sans ambiguïté. Un mois n'en a pas — 28 à 31 jours —
        /// et publier 30 jours inventerait un chiffre. `duree` admet `nil` pour ça.
        var duree: TimeInterval? {
            switch self {
            case .hebdomadaire: 604_800
            case .quinzaine: 1_209_600
            case .mensuelle: nil
            }
        }

        var sorte: Fenetre.Sorte {
            switch self {
            case .hebdomadaire: .septJours
            case .quinzaine: .quinzaine
            case .mensuelle: .mois
            }
        }
    }

    /// Une énumération peut gagner un cas. Ranger l'inconnu sous « Cette semaine »
    /// donnerait une échéance fausse à la fenêtre ; la fenêtre existe quand même, elle
    /// n'a simplement plus de période nommée.
    static let libellePeriodeInconnue = "Fenêtre en cours"

    /// Ce qu'un appel a rapporté. Le refus de jeton se distingue de l'échec ordinaire
    /// parce qu'il se règle par une reconnexion, là où l'autre ne demande rien.
    enum ReponseAPI: Sendable, Equatable {
        case donnees(Data)
        case jetonRefuse
        case echec
    }

    static func relever(session: URLSession = Reseau.session,
                        delai: TimeInterval = 8) async -> ResultatWarp {
        switch await IdentifiantsWarp.jeton() {
        case .jeton(let jeton):
            return await relever(jeton: jeton, session: session, delai: delai)
        case .absent:
            return .aucun
        // Une lecture empêchée n'établit pas l'absence de session : la prendre pour
        // telle effacerait une mesure que rien n'a infirmée.
        case .empechee:
            return .indetermine
        }
    }

    static func relever(jeton: JetonWarp,
                        session: URLSession = Reseau.session,
                        delai: TimeInterval = 8) async -> ResultatWarp {
        let reponse = await charger(jeton: jeton, session: session, delai: delai)
        let mesureA = Date()

        switch reponse {
        case .jetonRefuse:
            return .reconnexionNecessaire
        case .echec:
            return .indetermine
        case .donnees(let donnees):
            guard let quota = decoderUsage(donnees) else { return .indetermine }
            return .releve(ReleveWarp(quota: quota,
                                      mesureA: mesureA,
                                      utilisateurIdentifiant: jeton.utilisateurIdentifiant,
                                      illimite: estIllimite(donnees)))
        }
    }

    /// ⚠️ L'`Authorization` se pose **sur la requête**, jamais dans la configuration de
    /// session : CFNetwork rejoue celle-ci sur la cible d'une redirection, autre hôte
    /// compris. Le paramètre `op` de l'URL ne remplace pas `operationName` du corps —
    /// il nomme l'opération dans les journaux du serveur.
    static func requete(jeton: JetonWarp, delai: TimeInterval) -> URLRequest? {
        guard let url = URL(string: "\(adresse)?op=\(operation)"),
              let corps = try? JSONEncoder().encode(Corps()) else { return nil }
        var requete = URLRequest(url: url)
        requete.httpMethod = "POST"
        requete.timeoutInterval = delai
        requete.httpBody = corps
        requete.setValue("Bearer \(jeton.valeur)", forHTTPHeaderField: "Authorization")
        requete.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return requete
    }

    private static func charger(jeton: JetonWarp,
                                session: URLSession,
                                delai: TimeInterval) async -> ReponseAPI {
        guard let requete = requete(jeton: jeton, delai: delai) else { return .echec }

        do {
            let (donnees, reponse) = try await session.data(for: requete)
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            journaliser(code: code)
            return interpreter(code: code, donnees: donnees)
        } catch {
            Journal.donnees.debug("Quota Warp : app.warp.dev injoignable")
            return .echec
        }
    }

    /// Le 401 est le seul statut dont l'utilisateur ait quelque chose à faire. Le 403
    /// reste un échec ordinaire : côté Anthropic, c'est le statut d'un jeton valide
    /// auquel il manque un scope — une reconnexion n'y changerait rien.
    ///
    /// ⚠️ Un GraphQL répond aussi 200 à un refus applicatif. Ce cas-là ne passe pas
    /// par ici : le corps n'a pas de `requestLimitInfo`, et l'appel reste indéterminé
    /// plutôt que de réclamer une reconnexion sur un motif qu'on n'a pas lu.
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
            Journal.donnees.notice("Quota Warp : jeton refusé (401), reconnexion à faire dans Warp")
        default:
            Journal.donnees.notice("Quota Warp : statut HTTP \(code)")
        }
    }

    // MARK: - Analyses pures

    /// ⛔ Quatre champs du même type ne disent **pas** le niveau du compte, et trois
    /// d'entre eux rendraient un chiffre parfaitement crédible :
    ///
    /// - `acceptedAutosuggestionsLimit` et `acceptedAutosuggestionsSinceLastRefresh`
    ///   sont dépréciés et rendent toujours 0 — le schéma le dit mot pour mot ;
    /// - `isUnlimitedAutosuggestions`, `isUnlimitedVoice` et `maxCodebaseIndices`
    ///   portent sur d'autres fonctions que les requêtes ;
    /// - `bonusGrants` ajoute des crédits **hors** de `requestLimit` : les verser au
    ///   dénominateur inventerait un plafond que le compte ne publie pas.
    ///
    /// Aucun n'est demandé par le document, donc aucun n'arrive ici.
    static func decoderUsage(_ donnees: Data) -> Quota? {
        guard let limite = limite(donnees) else { return nil }

        // ⛔ Un compte sans plafond n'a rien à jauger. Une fenêtre à 0 % annoncerait un
        // crédit intact *mesuré*, alors que rien n'est mesuré : le quota est vide, et
        // c'est la grille qui disparaît — le comportement voulu.
        if limite.illimite == true { return Quota([]) }

        // Un plafond nul ou absent ne donne pas de rapport, et un plafond sans
        // consommation n'en donne pas davantage : ni division par zéro, ni demi-mesure.
        guard let plafond = limite.plafond, plafond > 0,
              let consommees = limite.consommees else { return nil }

        let periode = limite.periode.flatMap(Periode.init(rawValue:))
        if periode == nil {
            Journal.donnees.notice("Quota Warp : période inconnue « \(limite.periode ?? "absente") »")
        }

        guard let fenetre = Fenetre(libelle: periode?.libelle ?? libellePeriodeInconnue,
                                    sorte: periode?.sorte ?? .cycle,
                                    utilisation: 100 * Double(consommees) / Double(plafond),
                                    seRechargeA: limite.prochainRenouvellement?.date,
                                    duree: periode?.duree) else { return nil }
        return Quota(fenetre)
    }

    /// Le compte est déclaré sans plafond. C'est une constatation du serveur, pas une
    /// déduction du pourcentage — et c'est la seule chose qui explique un quota vide.
    static func estIllimite(_ donnees: Data) -> Bool {
        limite(donnees)?.illimite == true
    }

    private static func limite(_ donnees: Data) -> ReponseGraphQL.Limite? {
        try? JSONDecoder().decode(ReponseGraphQL.self, from: donnees).donnees?.resultat?.utilisateur?.limite
    }

    fileprivate struct ReponseGraphQL: Decodable {
        struct Limite: Decodable {
            var illimite: Bool?
            var plafond: Int?
            var consommees: Int?
            var prochainRenouvellement: Horodatage?
            var periode: String?

            enum CodingKeys: String, CodingKey {
                case illimite = "isUnlimited"
                case plafond = "requestLimit"
                case consommees = "requestsUsedSinceLastRefresh"
                case prochainRenouvellement = "nextRefreshTime"
                case periode = "requestLimitRefreshDuration"
            }
        }

        struct Utilisateur: Decodable {
            var limite: Limite?

            enum CodingKeys: String, CodingKey {
                case limite = "requestLimitInfo"
            }
        }

        /// `user` rend une union : la branche d'erreur n'a pas de champ `user`, et le
        /// décodage s'arrête donc ici, sans rien conclure.
        struct Resultat: Decodable {
            var utilisateur: Utilisateur?

            enum CodingKeys: String, CodingKey {
                case utilisateur = "user"
            }
        }

        struct Contenu: Decodable {
            var resultat: Resultat?

            enum CodingKeys: String, CodingKey {
                case resultat = "user"
            }
        }

        var donnees: Contenu?

        enum CodingKeys: String, CodingKey {
            case donnees = "data"
        }
    }

    /// Le schéma exige `clientContext` et `osContext`, mais tous leurs champs y sont
    /// optionnels : on les envoie vides plutôt que d'y publier la version de macOS,
    /// qu'un relevé de quota n'a aucun besoin de dire.
    private struct Corps: Encodable {
        struct Vide: Encodable {}

        struct Contexte: Encodable {
            var client = Vide()
            var systeme = Vide()

            enum CodingKeys: String, CodingKey {
                case client = "clientContext"
                case systeme = "osContext"
            }
        }

        struct Variables: Encodable {
            var contexte = Contexte()

            enum CodingKeys: String, CodingKey {
                case contexte = "requestContext"
            }
        }

        var document = QuotaWarp.document
        var operation = QuotaWarp.operation
        var variables = Variables()

        enum CodingKeys: String, CodingKey {
            case document = "query"
            case operation = "operationName"
            case variables
        }
    }
}
