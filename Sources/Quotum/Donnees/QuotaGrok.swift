import Foundation

/// Ce qu'un relevé direct de Grok Build établit. Comme chez Codebuff, l'identité ne
/// vient pas de la réponse mais du fichier d'identifiants : la réponse de facturation
/// ne nomme personne, et aucun second appel n'est fait pour aller le demander.
struct MesureGrok: Sendable, Equatable {
    var quota: Quota
    var mesureA: Date = .now
    /// `organization_name` du disque : l'ancre de la ligne, que `email` ou `team_id` ne
    /// remplacent pas sans changer l'identifiant des lignes existantes.
    var organisation: String?
    /// Lus dans la même réponse que le quota, et rangés à part exprès — voir
    /// `SoldesGrok`.
    var soldes: SoldesGrok?
}

/// ⛔ Deux mécanismes d'argent, **jamais additionnés** : le post-payé se consomme contre
/// un plafond, le prépayé est une réserve. Aucun ne devient une `Fenetre` — les verser
/// dans la grille ferait passer un porte-monnaie pour une consommation.
struct SoldesGrok: Sendable, Equatable {
    /// `onDemandUsed` contre `onDemandCap`, au-delà de l'allocation incluse.
    var aLaDemande: UsagePayant?
    /// `prepaidBalance`, les « Extra Usage Credits » achetés d'avance.
    var prepaye: UsagePayant?
    /// Les mécanismes publiés qu'on ne sait pas lire : ni zéro, ni absence — la mesure
    /// gardée de cette nature reste, voir `UsagesConserves`.
    var argentIllisible: Set<UsagePayant.Nature> = []
}

/// Ce que la lecture d'`auth.json` puis l'appel à l'API ont pu établir. Même partition
/// que `ReleveCodebuff` : un jeton refusé ne dit rien du quota, et une coupure encore
/// moins.
enum ReleveGrok: Sendable, Equatable {
    case releve(MesureGrok)
    /// Clé présente mais refusée. Le compte peut être plein, c'est l'accès qui manque,
    /// et il se retrouve par un `grok login`.
    case reconnexionNecessaire
    /// HTTP 412 « No personal team » : un compte d'équipe ou d'entreprise, que la route
    /// ne sait pas résoudre. La clé est bonne ; l'organisation garde la ligne du compte.
    case sansEquipePersonnelle(organisation: String?)
    /// HTTP 426 : le serveur exige la version d'un client officiel, que Quotum ne
    /// prétendra pas être. Rien ne viendra tant que la règle tient.
    case clientRefuse(organisation: String?)
    /// L'appel n'a rien établi — réseau coupé, statut inattendu, corps illisible.
    case indetermine
    /// Aucun identifiant Grok sur cette machine : rien à relever.
    case aucun
}

/// La clé que `grok login` dépose sur le disque, ou que `GROK_DEPLOYMENT_KEY` fournit.
/// Elle sert à un appel et n'est ni copiée sur disque, ni journalisée, ni conservée
/// au-delà du relevé.
struct JetonGrok: Sendable, Equatable {
    /// Une session de `grok login` et une clé de déploiement ne s'envoient pas de la même
    /// façon : seule la première relève de la famille que nomme `X-XAI-Token-Auth`.
    enum Origine: Sendable, Equatable {
        case session
        case cleDeDeploiement
    }

    let valeur: String
    /// `organization_name`, lu à côté de la clé. C'est l'ancre de la ligne : la remplacer
    /// par `email` ou `team_id` changerait l'identifiant des lignes existantes.
    let organisation: String?
    let origine: Origine
    /// `expires_at` de l'entrée. `nil` quand il manque ou ne se lit pas, et pour une clé
    /// de déploiement : rien n'établit alors l'expiration.
    var expireA: Date? = nil
}

/// Ce qu'une lecture d'`auth.json` a établi — même partition que `LectureCodebuff`,
/// pour la même raison : un fichier illisible et un poste sans session se ressemblent,
/// et un seul des deux dit quelque chose du compte.
enum LectureGrok: Sendable {
    case jeton(JetonGrok)
    /// Aucun fichier, ou un fichier lisible sans clé exploitable.
    case absent
    /// Lecture empêchée — droits refusés, contenu inexploitable, fichier tronqué.
    case empechee
}

/// Les identifiants que le CLI `grok` dépose sur le disque.
///
/// ⛔ **Lecture seule, sans exception.** Le CLI protège ce fichier par un verrou
/// (`flock`, battement de cœur, contrôle d'inode) parce qu'un jeton de rafraîchissement
/// ne sert qu'une fois : le renouveler ici invaliderait celui du CLI. Quotum ne
/// rafraîchit rien, n'écrit rien, et tolère de tomber sur une réécriture en cours — un
/// JSON tronqué est une lecture empêchée, pas un plantage.
enum IdentifiantsGrok {
    /// La portée OIDC en cours. La clé du dictionnaire vaut `émetteur::client`.
    static let porteeActuelle = "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828"
    /// Celle que laissaient les connexions d'avant le passage à OIDC.
    static let porteeHeritee = "https://accounts.x.ai/sign-in"
    static let porteesConnues = [porteeActuelle, porteeHeritee]

    /// ⛔ Une clé d'API se range sous cette portée-là, et elle n'est **jamais** reprise :
    /// c'est une autre famille d'identifiant — celle que l'acheteur colle à la main, et
    /// que ce produit s'interdit de détenir. La retenir en repli ferait partir la clé de
    /// facturation de quelqu'un sur une route qui ne l'attend pas.
    static let porteeCleAPI = "xai::api_key"

    /// L'émetteur ne change pas, l'identifiant de client peut changer. Une portée
    /// inconnue qui commence par là reste le même émetteur, et c'est le seul repli
    /// qui ne range rien au hasard.
    static let prefixeEmetteur = "https://auth.x.ai::"

    /// ⚠️ Elle ne sert **qu'en repli**, quand le fichier ne porte aucune session : c'est la
    /// clé de gestion d'un déploiement d'entreprise, et le client officiel n'interroge la
    /// facturation qu'avec la session de `grok login`.
    ///
    /// Portée mesurée sur cette machine (macOS 26.6) : ces trois surcharges lisent
    /// `ProcessInfo.processInfo.environment`, qui reflète l'environnement de session
    /// GUI — celui que peuple `launchctl setenv`, hérité aussi bien par un lancement
    /// Finder/Dock que par le LaunchAgent d'ouverture au démarrage. Un `export` posé
    /// seulement dans un profil de shell (`~/.zshrc`) n'y entre pas : il ne vaut que
    /// pour les descendants de ce shell, pas pour Quotum lancé autrement. Pour que ces
    /// variables atteignent réellement l'app, l'acheteur pose `launchctl setenv
    /// GROK_DEPLOYMENT_KEY <valeur>` (persistant pour la session), pas un export de
    /// profil.
    static let variableCle = "GROK_DEPLOYMENT_KEY"
    /// Désigne un `auth.json` précis, et prime sur `GROK_HOME`.
    static let variableFichier = "GROK_AUTH_PATH"
    /// Déplace tout le dossier de Grok.
    static let variableDossier = "GROK_HOME"

    static func fichier(environnement: [String: String] = ProcessInfo.processInfo.environment,
                        accueil: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let declare = nonVide(environnement[variableFichier]) {
            return URL(fileURLWithPath: (declare as NSString).expandingTildeInPath)
        }
        if let dossier = nonVide(environnement[variableDossier]) {
            return URL(fileURLWithPath: (dossier as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("auth.json")
        }
        return accueil.appendingPathComponent(".grok/auth.json")
    }

    static func jeton(environnement: [String: String] = ProcessInfo.processInfo.environment,
                      fichier url: URL? = nil) async -> LectureGrok {
        let cible = url ?? fichier(environnement: environnement)
        let lecture = await HorsFil.executer { lire(cible) }
        // Seule l'absence établie ouvre le repli : un fichier en cours de réécriture
        // ferait sinon mesurer, le temps d'un relevé, un tout autre compte.
        guard case .absent = lecture, let cle = nonVide(environnement[variableCle]) else {
            return lecture
        }
        // Une clé de déploiement ne porte pas d'organisation : elle vient de
        // l'environnement, pas d'un fichier qui décrirait le compte.
        return .jeton(JetonGrok(valeur: cle, organisation: nil, origine: .cleDeDeploiement))
    }

    static func lire(_ url: URL) -> LectureGrok {
        let donnees: Data
        do {
            donnees = try Data(contentsOf: url)
        } catch {
            guard estAbsence(error) else {
                Journal.donnees.notice("Grok : auth.json illisible (\(error))")
                return .empechee
            }
            Journal.donnees.debug("Grok : aucun auth.json sur cette machine")
            return .absent
        }
        return classer(donnees)
    }

    /// Ce qu'un contenu d'`auth.json` établit. Un JSON valide sans portée exploitable
    /// conclut — ce poste n'a pas de session ; un contenu illisible ne conclut rien.
    static func classer(_ donnees: Data) -> LectureGrok {
        guard let entrees = try? JSONDecoder().decode([String: Entree].self, from: donnees) else {
            Journal.donnees.notice("Grok : auth.json lu mais inexploitable")
            return .empechee
        }
        guard let retenue = choisir(entrees) else { return .absent }
        return .jeton(JetonGrok(valeur: retenue.cle, organisation: retenue.organisation, origine: .session,
                                expireA: retenue.expireA))
    }

    /// ⚠️ Le fichier est indexé par **portée**, et deux comptes produisent la même clé :
    /// l'identifiant de client de xAI est une constante, et rien dans la portée ne nomme
    /// le compte. Un second `grok login` écrase donc le premier — c'est une ligne, jamais
    /// un groupe, et le cloisonnement passe par `GROK_AUTH_PATH` ou `GROK_HOME`.
    static func choisir(_ entrees: [String: Entree]) -> (cle: String, organisation: String?, expireA: Date?)? {
        for portee in porteesConnues {
            if let entree = entrees[portee], let cle = nonVide(entree.cle) {
                return (cle, nonVide(entree.organisation), entree.expireA)
            }
        }
        // Le tri n'est pas cosmétique : l'ordre d'un dictionnaire n'est pas stable, et
        // sans lui deux portées voisines donneraient un compte différent à chaque appel.
        let voisines = entrees
            .filter { $0.key.hasPrefix(prefixeEmetteur) && nonVide($0.value.cle) != nil }
            .sorted { $0.key < $1.key }
        guard let (portee, entree) = voisines.first, let cle = nonVide(entree.cle) else {
            return nil
        }
        Journal.donnees.notice("Grok : portée inconnue « \(portee) », même émetteur — clé retenue")
        return (cle, nonVide(entree.organisation), entree.expireA)
    }

    /// Les champs voisins — `create_time`, `email`, `team_id`, `user_id`, `oidc_issuer` —
    /// ne sont pas déclarés, donc jamais lus. Une valeur qui n'est pas un objet ne fait
    /// pas échouer la lecture : un fichier peut porter un numéro de version à côté de
    /// ses portées, et le refuser ferait conclure à l'absence de session.
    struct Entree: Decodable {
        var cle: String?
        var organisation: String?
        /// ISO 8601, à fraction de seconde. Illisible, il vaut absent : il ne prouve
        /// rien, et une clé encore valable ne doit pas se perdre sur une date mal écrite.
        var expireA: Date?

        init(cle: String?, organisation: String? = nil, expireA: Date? = nil) {
            self.cle = cle
            self.organisation = organisation
            self.expireA = expireA
        }

        init(from decodeur: Decoder) throws {
            guard let conteneur = try? decodeur.container(keyedBy: Cles.self) else { return }
            cle = try? conteneur.decode(String.self, forKey: .cle)
            organisation = try? conteneur.decode(String.self, forKey: .organisation)
            expireA = (try? conteneur.decode(Horodatage.self, forKey: .expireA))?.date
        }

        enum Cles: String, CodingKey {
            case cle = "key"
            case organisation = "organization_name"
            case expireA = "expires_at"
        }
    }

    private static func estAbsence(_ erreur: Error) -> Bool {
        let brute = erreur as NSError
        guard brute.domain == NSCocoaErrorDomain else { return false }
        return brute.code == NSFileReadNoSuchFileError || brute.code == NSFileNoSuchFileError
    }

    private static func nonVide(_ valeur: String?) -> String? {
        guard let coupe = valeur?.trimmingCharacters(in: .whitespacesAndNewlines), !coupe.isEmpty else {
            return nil
        }
        return coupe
    }
}

/// Relevé direct du quota de Grok Build. Le fournisseur est le seul du champ à publier
/// le **type** de sa fenêtre dans un champ dédié, et le seul à mêler dans la même
/// réponse un quota et des soldes : le premier fait la grille, les seconds n'y entrent
/// jamais.
enum QuotaGrok {
    static let adresse = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"

    /// L'app s'annonce sous son propre nom. Se faire passer pour le client officiel
    /// stabiliserait peut-être l'accès — c'est une infraction d'une autre nature que
    /// de lire une clé qu'on a le droit de lire.
    static let agent = "Quotum"

    /// ⚠️ Cet en-tête ne décrit pas le client, il décrit **la clé** : il dit de quelle
    /// famille d'identifiant relève le `Bearer` qui l'accompagne, et l'affirmation est
    /// vraie pour une session de `grok login`, et pour elle seule : une clé de déploiement
    /// part sans lui, comme le client officiel l'envoie. L'identité de
    /// l'app, elle, reste dans le `User-Agent`, qui dit « Quotum ». L'omettre exposerait
    /// à un refus qu'on lirait à tort comme une mesure indéterminée.
    ///
    /// ⛔ Ce que le client officiel envoie en plus n'est **pas** repris : `x-userid`,
    /// qu'aucun champ d'`auth.json` ne publie — le fabriquer répéterait le piège de
    /// `ChatGPT-Account-Id`, où l'identité envoyée est ignorée et seule celle du jeton
    /// compte ; et `x-grok-client-version`, qui annoncerait la version d'un client
    /// qu'on n'est pas.
    static let enteteFamilleDeCle = "X-XAI-Token-Auth"
    static let familleDeCle = "xai-grok-cli"

    /// ⛔ Grok ne publie **aucune fenêtre courte** : le dépassement s'y manifeste par un
    /// 429 assorti d'un `retry-after` sur la route de conversation, pas par une jauge.
    /// Une seconde fenêtre n'existe donc pas, et n'a pas à être inventée.
    ///
    /// ⚠️ `USAGE_PERIOD_TYPE_WEEKLY` nomme un nombre de secondes exact. `MONTHLY` non —
    /// un mois vaut de 28 à 31 jours, et publier 30 jours inventerait un chiffre.
    enum Periode: String, Sendable, CaseIterable {
        case hebdomadaire = "USAGE_PERIOD_TYPE_WEEKLY"
        case mensuelle = "USAGE_PERIOD_TYPE_MONTHLY"

        var libelle: String {
            switch self {
            case .hebdomadaire: "Cette semaine"
            case .mensuelle: "Ce mois"
            }
        }

        var duree: TimeInterval? {
            switch self {
            case .hebdomadaire: 604_800
            case .mensuelle: nil
            }
        }

        var sorte: Fenetre.Sorte {
            switch self {
            case .hebdomadaire: .septJours
            case .mensuelle: .mois
            }
        }
    }

    /// Une énumération peut gagner un cas. Ranger l'inconnu sous « Cette semaine »
    /// donnerait une échéance fausse à la fenêtre ; la fenêtre existe quand même, elle
    /// n'a simplement plus de période nommée.
    static let libellePeriodeInconnue = "Fenêtre en cours"

    /// Ce qu'un appel a rapporté. Le refus de clé se distingue de l'échec ordinaire
    /// parce qu'il se règle par une reconnexion, là où l'autre ne demande rien.
    enum ReponseAPI: Sendable, Equatable {
        case donnees(Data)
        case jetonRefuse
        case sansEquipePersonnelle
        case clientRefuse
        case echec
    }

    static func relever(session: URLSession = Reseau.session,
                        delai: TimeInterval = 8) async -> ReleveGrok {
        switch await IdentifiantsGrok.jeton() {
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

    static func relever(jeton: JetonGrok,
                        session: URLSession = Reseau.session,
                        delai: TimeInterval = 8,
                        maintenant: Date = .now) async -> ReleveGrok {
        // ⛔ Un `expires_at` dépassé se constate sans appel : envoyer la clé ne servirait
        // qu'à se faire refuser. Elle se renouvelle par `grok login`, jamais ici.
        if let expireA = jeton.expireA, expireA <= maintenant { return .reconnexionNecessaire }

        let reponse = await charger(jeton: jeton, session: session, delai: delai)
        let mesureA = Date()

        switch reponse {
        case .jetonRefuse:
            return .reconnexionNecessaire
        case .sansEquipePersonnelle:
            return .sansEquipePersonnelle(organisation: jeton.organisation)
        case .clientRefuse:
            return .clientRefuse(organisation: jeton.organisation)
        case .echec:
            return .indetermine
        case .donnees(let donnees):
            guard let quota = decoderUsage(donnees) else { return .indetermine }
            return .releve(MesureGrok(quota: quota,
                                      mesureA: mesureA,
                                      organisation: jeton.organisation,
                                      soldes: decoderSoldes(donnees, mesureA: mesureA)))
        }
    }

    /// ⚠️ L'`Authorization` se pose **sur la requête**, jamais dans la configuration de
    /// session : CFNetwork rejoue celle-ci sur la cible d'une redirection, autre hôte
    /// compris.
    static func requete(jeton: JetonGrok, delai: TimeInterval) -> URLRequest? {
        guard let url = URL(string: adresse) else { return nil }
        var requete = URLRequest(url: url)
        requete.httpMethod = "GET"
        requete.timeoutInterval = delai
        requete.setValue("Bearer \(jeton.valeur)", forHTTPHeaderField: "Authorization")
        if jeton.origine == .session {
            requete.setValue(familleDeCle, forHTTPHeaderField: enteteFamilleDeCle)
        }
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue(agent, forHTTPHeaderField: "User-Agent")
        return requete
    }

    private static func charger(jeton: JetonGrok,
                                session: URLSession,
                                delai: TimeInterval) async -> ReponseAPI {
        guard let requete = requete(jeton: jeton, delai: delai) else { return .echec }

        do {
            let (donnees, reponse) = try await session.data(for: requete)
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            journaliser(code: code)
            return interpreter(code: code, donnees: donnees)
        } catch {
            Journal.donnees.debug("Quota Grok : cli-chat-proxy.grok.com injoignable")
            return .echec
        }
    }

    /// Le 401 est le seul statut dont l'utilisateur ait quelque chose à faire. Le 412 et le
    /// 426 se rangent à part parce qu'ils durent : les lire en échec ordinaire laisserait la
    /// ligne attendre une mesure qui ne viendra pas.
    ///
    /// ⛔ Le 429 reste un échec ordinaire : celui qui signale un quota épuisé est rendu
    /// par la route de conversation, pas par celle-ci. Lire un 429 de facturation comme
    /// un épuisement annoncerait un état qu'on n'a pas mesuré.
    static func interpreter(code: Int, donnees: Data) -> ReponseAPI {
        switch code {
        case 200: .donnees(donnees)
        case 401: .jetonRefuse
        case 412: .sansEquipePersonnelle
        case 426: .clientRefuse
        default: .echec
        }
    }

    private static func journaliser(code: Int) {
        switch code {
        case 200:
            break
        case 401:
            Journal.donnees.notice("Quota Grok : clé refusée (401), reconnexion à refaire")
        case 412:
            Journal.donnees.notice("Quota Grok : compte sans équipe personnelle (412), aucune mesure possible")
        case 426:
            Journal.donnees.notice("Quota Grok : version de client exigée (426), relevé refusé")
        default:
            Journal.donnees.notice("Quota Grok : statut HTTP \(code)")
        }
    }

    // MARK: - Analyses pures

    /// ⚠️ Tous les champs vivent sous `config` — c'est ainsi que le client officiel
    /// désérialise la réponse (`BillingConfigResponse`), et toutes les réponses réelles
    /// publiées ont cette forme. Aucune forme à plat n'est attestée, et aucune n'est lue.
    /// Un `config` absent ou nul est une réponse sans données de crédit ; un `config` qui
    /// n'est pas un objet fait échouer le décodage, comme un corps illisible.
    private struct ReponseFacturation: Decodable {
        var config: Facturation?
    }

    /// ⛔ Un seul champ de cette réponse va dans la grille : `creditUsagePercent`, la
    /// part consommée de l'allocation **incluse dans l'abonnement**. Les trois montants
    /// qui l'entourent sont des soldes en cents, et les quatre champs dépréciés
    /// (`monthlyLimit`, `used`, `billingPeriodStart`, `billingPeriodEnd`) ne sont pas
    /// déclarés, donc jamais lus. `productUsage[]` non plus : le client officiel ne le
    /// désérialise pas davantage.
    private struct Facturation: Decodable {
        struct Cycle: Decodable {
            var type: String?
            var fin: Date?

            init(from decodeur: Decoder) throws {
                let conteneur = try decodeur.container(keyedBy: Cles.self)
                type = try? conteneur.decode(String.self, forKey: .type)
                fin = (try? conteneur.decode(Horodatage.self, forKey: .fin))?.date
            }

            enum Cles: String, CodingKey {
                case type
                case fin = "end"
            }
        }

        /// ⚠️ Singulier : il n'y a qu'un cycle, et c'est son champ `type` qui le classe,
        /// jamais sa position.
        var cycle: Cycle?
        var pourcentage: NombreProto?
        var plafondALaDemande: Cents?
        var consommeALaDemande: Cents?
        var prepaye: Cents?

        enum CodingKeys: String, CodingKey {
            case cycle = "currentPeriod"
            case pourcentage = "creditUsagePercent"
            case plafondALaDemande = "onDemandCap"
            case consommeALaDemande = "onDemandUsed"
            case prepaye = "prepaidBalance"
        }
    }

    /// Le wrapper `Cent` de la réponse : un nombre entier de **cents de dollar**, porté par
    /// un champ `val`.
    ///
    /// ⛔ **proto3 omet les scalaires à zéro** : un montant de 0 $ arrive comme objet
    /// **vide** `{}`, pas comme `{"val":0}`. Sans défaut, tout le décodage échouerait sur
    /// le cas le plus ordinaire — un compte qui n'a rien dépensé à la demande.
    ///
    /// ⚠️ L'entier 64 bits de proto3 s'écrit en chaîne (`"1250"`), mais un client peut
    /// aussi l'écrire nu (`1250`) : les deux écritures plausibles sont acceptées. Toute
    /// autre — décimale, exposant, texte, dépassement — rend `nil`, jamais un zéro : un
    /// montant illisible n'est pas un compte qui n'a rien dépensé. ⛔ Aucun `Double` : un
    /// flottant ne garde pas un entier au-delà de 2⁵³, et arrondirait un montant.
    private struct Cents: Decodable {
        var valeur: Int64?

        init(from decodeur: Decoder) throws {
            guard let conteneur = try? decodeur.container(keyedBy: Cles.self) else {
                valeur = nil
                return
            }
            guard conteneur.contains(.valeur) else {
                valeur = 0
                return
            }
            if let texte = try? conteneur.decode(String.self, forKey: .valeur) {
                valeur = Self.entier(texte)
            } else if let nombre = try? conteneur.decode(Int64.self, forKey: .valeur) {
                valeur = nombre
            } else {
                valeur = nil
            }
        }

        /// Des chiffres, précédés au plus d'un signe moins. `Int64(_:)` seul accepterait
        /// aussi « +12 ».
        private static func entier(_ texte: String) -> Int64? {
            let chiffres = texte.hasPrefix("-") ? texte.dropFirst() : Substring(texte)
            guard !chiffres.isEmpty, chiffres.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) })
            else { return nil }
            return Int64(texte)
        }

        enum Cles: String, CodingKey {
            case valeur = "val"
        }
    }

    /// ⚠️ Second effet du format JSON de proto3 : un entier 64 bits s'y écrit **en
    /// chaîne** — `"1200"`, pas `1200`. Un décodeur qui n'attend qu'un nombre rendrait
    /// `nil` sur une réponse parfaitement normale. Les valeurs non finies sont écartées
    /// **au décodage**, parce que proto3 écrit `"NaN"` et `"Infinity"` en toutes
    /// lettres : ce sont des mots que `Double(_: String)` accepte, là où le décodeur
    /// JSON rejette le littéral. Seul le pourcentage passe par ici — les montants ont
    /// leur propre lecture, sans flottant.
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

    /// ⛔ Un pourcentage **absent** ne vaut pas zéro ici, à la différence d'un montant :
    /// l'omission de proto3 et un compte sans allocation incluse se ressemblent trait
    /// pour trait, et lire zéro afficherait une grille pleine sur un compte qui n'a rien
    /// à jauger. Le quota est alors vide, la grille disparaît — là où le client officiel
    /// affiche 0 %. `nil` reste réservé à ce qui n'est même pas un objet JSON : une page
    /// d'erreur servie en 200, un corps tronqué.
    static func decoderUsage(_ donnees: Data) -> Quota? {
        guard let enveloppe = try? JSONDecoder().decode(ReponseFacturation.self, from: donnees) else {
            return nil
        }
        guard let reponse = enveloppe.config,
              let pourcentage = reponse.pourcentage?.valeur else { return Quota([]) }

        let type = reponse.cycle?.type
        let periode = type.flatMap(Periode.init(rawValue:))
        if periode == nil {
            Journal.donnees.notice("Quota Grok : type de période inconnu « \(type ?? "absent") »")
        }

        // Une valeur non finie suit la règle du pourcentage absent : le quota est vide
        // et la grille disparaît, plutôt qu'un chiffre inventé.
        guard let fenetre = Fenetre(libelle: periode?.libelle ?? libellePeriodeInconnue,
                                    sorte: periode?.sorte ?? .cycle,
                                    utilisation: pourcentage,
                                    seRechargeA: reponse.cycle?.fin,
                                    duree: periode?.duree) else { return Quota([]) }
        return Quota(fenetre)
    }

    /// L'unité de tous les montants de la réponse : le cent de dollar US. La réponse ne la
    /// nomme pas ; c'est la convention de son wrapper `Cent`, et xAI facture en dollars.
    static let devise = Montant.Unite.devise("USD")
    static let exposant = 2

    /// Les soldes, lus mais tenus hors de la grille. Rendre `nil` quand la réponse n'en
    /// porte aucun distingue « ce compte n'a rien dépensé » de « cette réponse ne parle
    /// pas d'argent » — un zéro couvrirait les deux.
    ///
    /// ⛔ Aucune échéance : la réponse n'en publie pas pour l'argent, et « au prochain
    /// cycle » serait une convention de client.
    static func decoderSoldes(_ donnees: Data, mesureA: Date) -> SoldesGrok? {
        guard let reponse = (try? JSONDecoder().decode(ReponseFacturation.self, from: donnees))?.config
        else { return nil }
        // Un montant présent mais illisible fait tomber tout son mécanisme : un consommé
        // perdu devant un plafond positif se lirait « rien dépensé », un plafond perdu
        // laisserait lire la dépense comme sans limite.
        var illisible: Set<UsagePayant.Nature> = []
        if estIllisible(reponse.plafondALaDemande) || estIllisible(reponse.consommeALaDemande) {
            illisible.insert(.depense)
        }
        if estIllisible(reponse.prepaye) { illisible.insert(.solde) }
        let soldes = SoldesGrok(
            aLaDemande: illisible.contains(.depense)
                ? nil
                : aLaDemande(plafond: reponse.plafondALaDemande,
                             consomme: reponse.consommeALaDemande,
                             mesureA: mesureA),
            prepaye: illisible.contains(.solde) ? nil : prepaye(reponse.prepaye, mesureA: mesureA),
            argentIllisible: illisible)
        guard soldes.aLaDemande != nil || soldes.prepaye != nil || !illisible.isEmpty else { return nil }
        return soldes
    }

    private static func estIllisible(_ lu: Cents?) -> Bool {
        lu != nil && lu?.valeur == nil
    }

    /// Le post-payé. ⚠️ Un plafond à zéro est un **vrai plafond nul** — à la demande
    /// désactivé, ou jamais réglé, sans qu'on sache lequel : il reste un montant de 0 $,
    /// jamais une absence, et ne dit pas pour autant que le mécanisme est éteint. Seul un
    /// plafond positif l'établit actif.
    private static func aLaDemande(plafond lu: Cents?, consomme luConsomme: Cents?,
                                   mesureA: Date) -> UsagePayant? {
        let plafond = montant(lu)
        let consomme = montant(luConsomme)
        guard plafond != nil || consomme != nil else { return nil }
        let positif = (plafond?.unitesMineures ?? 0) > 0
        // Atteint seulement contre un plafond positif : un plafond nul ne s'« atteint » pas,
        // il n'a jamais rien laissé dépenser — et c'est celui de tout compte qui n'a rien réglé.
        var atteint = false
        if let plafond, positif, let consomme {
            atteint = consomme.unitesMineures >= plafond.unitesMineures
        }
        return UsagePayant(nature: .depense,
                           unite: devise,
                           consomme: consomme,
                           plafond: plafond,
                           solde: nil,
                           utilisation: nil,
                           illimite: nil,
                           actif: positif ? true : nil,
                           bloque: atteint,
                           motif: nil,
                           echeance: nil,
                           mesureA: mesureA)
    }

    /// Le prépayé. Un solde nul se dit, mais ne bloque rien : il est aussi celui d'un
    /// compte qui n'a jamais rien acheté.
    private static func prepaye(_ lu: Cents?, mesureA: Date) -> UsagePayant? {
        guard let solde = montant(lu) else { return nil }
        return UsagePayant(nature: .solde,
                           unite: devise,
                           consomme: nil,
                           plafond: nil,
                           solde: solde,
                           utilisation: nil,
                           illimite: nil,
                           actif: nil,
                           bloque: false,
                           motif: nil,
                           echeance: nil,
                           mesureA: mesureA)
    }

    private static func montant(_ lu: Cents?) -> Montant? {
        guard let cents = lu?.valeur else { return nil }
        return Montant(unitesMineures: cents, unite: devise, exposant: exposant)
    }
}
