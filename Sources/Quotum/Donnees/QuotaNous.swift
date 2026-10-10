import Foundation

/// Ce qu'un relevé de Nous Portal établit, pour le compte dont Hermes a posé le jeton.
struct MesureNous: Sendable, Equatable {
    var quota: Quota
    var mesureA: Date
    /// `user.email`, tel que publié.
    var courriel: String?
    /// `organisation.name`, tel que publié.
    var organisation: String?
    /// `subscription.plan` (« Ultra »…), tel que publié.
    var formule: String?
}

/// Ce que la lecture du fichier d'Hermes puis l'appel au portail ont pu établir.
enum ReleveNous: Sendable, Equatable {
    case releve(MesureNous)
    /// Jeton expiré — constaté localement, sans aucune requête — ou refusé par le portail.
    /// Seul Hermes le renouvelle : la ligne dit de rouvrir Hermes, jamais de se reconnecter
    /// dans Quotum.
    case reconnexionNecessaire
    /// Rien d'établi : réseau, statut inattendu (403, 429, 5xx), corps illisible, fichier
    /// empêché.
    case indetermine
    /// Aucun jeton Nous sur cette machine : rien à relever.
    case aucun
}

/// Le jeton qu'Hermes dépose sur le disque. Il sert à un appel et n'est ni copié, ni
/// journalisé, ni conservé au-delà du relevé.
struct JetonNous: Sendable, Equatable {
    let valeur: String
    /// L'origine qui recevra le jeton, déjà passée par `IdentifiantsNous.portail(stocke:)`.
    let portail: URL
    let expireA: Date?
}

enum LectureNous: Sendable, Equatable {
    case jeton(JetonNous)
    /// Un jeton existe, mais aucun n'est encore valable : il ne part pas.
    case expire
    /// Aucun fichier, ou des fichiers sans jeton.
    case absent
    /// Lecture empêchée — droits refusés, contenu inexploitable, `HERMES_HOME` relatif.
    case empechee
}

/// Ce que le relevé lit du poste, passé en entier par l'appelant.
///
/// ⛔ **Aucune valeur par défaut** : un test qui oublierait d'en fournir une ne compile pas,
/// au lieu de lire le vrai `~/.hermes` en silence. L'app passe `SourcesNous.poste`.
struct SourcesNous: Sendable {
    var environnement: [String: String]
    var accueil: URL
    var lire: @Sendable (URL) throws(LectureFichier.Echec) -> Data
    var maintenant: @Sendable () -> Date

    static var poste: SourcesNous {
        SourcesNous(environnement: ProcessInfo.processInfo.environment,
                    accueil: FileManager.default.homeDirectoryForCurrentUser,
                    lire: { url throws(LectureFichier.Echec) in try LectureFichier.lire(url) },
                    maintenant: { Date() })
    }
}

/// ⛔ **Lecture seule, et jamais de renouvellement.** Le jeton de rafraîchissement d'Hermes
/// tourne à chaque usage et un rejeu révoque toute la session : seul le jeton d'accès,
/// valable environ une heure, est lu.
enum IdentifiantsNous {
    static let variableRacine = "HERMES_HOME"
    /// Le fichier du profil, puis la copie qu'Hermes partage entre profils.
    static let fichiers = ["auth.json", "shared/nous_auth.json"]
    static let portailParDefaut = URL(string: "https://portal.nousresearch.com")!
    static let domaineDuPortail = "nousresearch.com"
    /// Un jeton à moins d'une minute de sa fin est tenu pour expiré : il le serait à
    /// l'arrivée.
    static let marge: TimeInterval = 60

    /// `$HERMES_HOME` est **exclusif** : posé, `~/.hermes` n'est jamais lu, pour qu'un profil
    /// expiré ou absent ne retombe pas en silence sur le jeton d'un autre profil. `nil`
    /// quand la variable désigne un chemin relatif, qui dépendrait du dossier courant.
    static func racine(environnement: [String: String], accueil: URL) -> URL? {
        guard let posee = environnement[variableRacine]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !posee.isEmpty else {
            return accueil.appendingPathComponent(".hermes", isDirectory: true)
        }
        if posee == "~" { return accueil }
        if posee.hasPrefix("~/") {
            return accueil.appendingPathComponent(String(posee.dropFirst(2)), isDirectory: true)
        }
        guard posee.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: posee, isDirectory: true)
    }

    static func jeton(_ sources: SourcesNous) async -> LectureNous {
        await HorsFil.executer { lire(sources) }
    }

    /// Premier jeton valable dans l'ordre des fichiers ; à défaut, un jeton expiré l'emporte
    /// sur un fichier empêché, qui l'emporte sur l'absence.
    static func lire(_ sources: SourcesNous) -> LectureNous {
        guard let racine = racine(environnement: sources.environnement, accueil: sources.accueil) else {
            Journal.donnees.notice("Nous : HERMES_HOME relatif, relevé abandonné")
            return .empechee
        }
        let maintenant = sources.maintenant()
        var expire = false
        var empechee = false
        for relatif in fichiers {
            let url = racine.appendingPathComponent(relatif)
            let donnees: Data
            do {
                donnees = try sources.lire(url)
            } catch .absent {
                continue
            } catch {
                Journal.donnees.notice("Nous : fichier d'Hermes illisible (\(String(describing: error)))")
                empechee = true
                continue
            }
            switch classer(donnees, maintenant: maintenant) {
            case .jeton(let jeton): return .jeton(jeton)
            case .expire: expire = true
            case .empechee: empechee = true
            case .absent: break
            }
        }
        if expire { return .expire }
        return empechee ? .empechee : .absent
    }

    /// Trois formes écrites par Hermes : `providers.nous`, la liste `credential_pool.nous`,
    /// ou l'état nu à la racine.
    static func classer(_ donnees: Data, maintenant: Date) -> LectureNous {
        guard let racine = (try? JSONSerialization.jsonObject(with: donnees)) as? [String: Any] else {
            Journal.donnees.notice("Nous : fichier d'Hermes lu mais inexploitable")
            return .empechee
        }
        var candidats: [Candidat] = []
        if let fournisseurs = racine["providers"] as? [String: Any],
           let etat = fournisseurs["nous"] as? [String: Any],
           let candidat = Candidat(etat) {
            candidats = [candidat]
        } else if let reserve = racine["credential_pool"] as? [String: Any],
                  let entrees = reserve["nous"] as? [Any],
                  case let lus = entrees.compactMap({ ($0 as? [String: Any]).flatMap(Candidat.init) }),
                  !lus.isEmpty {
            candidats = lus
        } else if let candidat = Candidat(racine) {
            candidats = [candidat]
        }
        guard !candidats.isEmpty else { return .absent }

        let valables = candidats.filter { !$0.expire(a: maintenant) }
        guard let retenu = valables.max(by: Candidat.precede) else { return .expire }
        return .jeton(JetonNous(valeur: retenu.valeur,
                                portail: portail(stocke: retenu.portail),
                                expireA: retenu.expireA))
    }

    /// ⛔ Le jeton ne part que vers `nousresearch.com` ou l'un de ses sous-domaines, en HTTPS,
    /// sans port, chemin, paramètre ni identifiant dans l'adresse. Toute autre valeur
    /// stockée — modifiée, périmée ou malveillante — renvoie au portail par défaut.
    static func portail(stocke: String?) -> URL {
        guard var texte = stocke?.trimmingCharacters(in: .whitespacesAndNewlines) else { return portailParDefaut }
        while texte.hasSuffix("/") { texte.removeLast() }
        guard let composants = URLComponents(string: texte),
              composants.scheme?.lowercased() == "https",
              composants.user == nil, composants.password == nil, composants.port == nil,
              composants.path.isEmpty, composants.query == nil, composants.fragment == nil,
              let hote = composants.host?.lowercased(), hoteAdmis(hote),
              let url = URL(string: "https://\(hote)")
        else {
            if stocke != nil { Journal.donnees.notice("Nous : portail stocké hors de nousresearch.com, ignoré") }
            return portailParDefaut
        }
        return url
    }

    static func hoteAdmis(_ hote: String) -> Bool {
        guard hote.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              !hote.contains("..") else { return false }
        return hote == domaineDuPortail || hote.hasSuffix("." + domaineDuPortail)
    }

    private struct Candidat {
        let valeur: String
        let portail: String?
        let expireA: Date?
        let cleAgentExpireA: Date?
        let priorite: Int

        init?(_ etat: [String: Any]) {
            guard let valeur = (etat["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !valeur.isEmpty else { return nil }
            self.valeur = valeur
            portail = etat["portal_base_url"] as? String
            expireA = IdentifiantsNous.date(etat["expires_at"]) ?? IdentifiantsNous.expirationJWT(valeur)
            cleAgentExpireA = IdentifiantsNous.date(etat["agent_key_expires_at"])
            priorite = (etat["priority"] as? NSNumber)?.intValue ?? 0
        }

        /// Sans échéance connue, le jeton part : c'est le portail qui dira s'il vaut encore.
        func expire(a maintenant: Date) -> Bool {
            guard let expireA else { return false }
            return expireA.timeIntervalSince(maintenant) <= IdentifiantsNous.marge
        }

        /// L'ordre de la réserve d'Hermes : la clé d'agent la plus tardive, puis le jeton
        /// d'accès le plus tardif, puis la priorité la plus basse.
        static func precede(_ a: Candidat, _ b: Candidat) -> Bool {
            let agentA = a.cleAgentExpireA?.timeIntervalSince1970 ?? 0
            let agentB = b.cleAgentExpireA?.timeIntervalSince1970 ?? 0
            if agentA != agentB { return agentA < agentB }
            let accesA = a.expireA?.timeIntervalSince1970 ?? 0
            let accesB = b.expireA?.timeIntervalSince1970 ?? 0
            if accesA != accesB { return accesA < accesB }
            return a.priorite > b.priorite
        }
    }

    private static func date(_ valeur: Any?) -> Date? {
        if let texte = valeur as? String { return Horodatage.analyser(texte) }
        if let nombre = valeur as? NSNumber, CFGetTypeID(nombre) != CFBooleanGetTypeID() {
            return Horodatage.analyser(epoch: nombre.doubleValue)
        }
        return nil
    }

    /// La revendication `exp` d'un JWT, quand le fichier ne porte pas `expires_at`. Le jeton
    /// n'est pas vérifié ici : seule son échéance déclarée sert, à ne pas l'envoyer périmé.
    static func expirationJWT(_ jeton: String) -> Date? {
        let parties = jeton.split(separator: ".", omittingEmptySubsequences: false)
        guard parties.count == 3 else { return nil }
        var base64 = parties[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let octets = Data(base64Encoded: base64),
              let revendications = (try? JSONSerialization.jsonObject(with: octets)) as? [String: Any],
              let exp = revendications["exp"] as? NSNumber,
              CFGetTypeID(exp) != CFBooleanGetTypeID() else { return nil }
        return Horodatage.analyser(epoch: exp.doubleValue)
    }
}

/// Relevé de la dotation mensuelle de Nous Portal par `GET <portail>/api/oauth/account`.
///
/// ⚠️ Route non documentée publiquement ; forme relevée chez un tiers, aucune réponse réelle
/// observée sur ce Mac. Le portail publie un **restant** (`credits_remaining`) contre une
/// dotation (`monthly_credits`) : l'inversion en consommé est faite ici.
enum QuotaNous {
    static let agent = "Quotum"
    static let chemin = "/api/oauth/account"

    enum ReponseAPI: Sendable, Equatable {
        case donnees(Data)
        case jetonRefuse
        case echec
    }

    /// Point d'entrée de l'inventaire : `QuotaNous.relever(sources: .poste, session: Reseau.session, delai: 8)`.
    static func relever(sources: SourcesNous, session: URLSession, delai: TimeInterval) async -> ReleveNous {
        switch await IdentifiantsNous.jeton(sources) {
        case .jeton(let jeton):
            let reponse = await charger(jeton: jeton, session: session, delai: delai)
            return conclure(reponse, mesureA: sources.maintenant())
        case .expire:
            return .reconnexionNecessaire
        case .absent:
            return .aucun
        case .empechee:
            return .indetermine
        }
    }

    static func conclure(_ reponse: ReponseAPI, mesureA: Date) -> ReleveNous {
        switch reponse {
        case .jetonRefuse: return .reconnexionNecessaire
        case .echec: return .indetermine
        case .donnees(let donnees):
            guard let mesure = decoder(donnees, mesureA: mesureA) else { return .indetermine }
            return .releve(mesure)
        }
    }

    /// ⚠️ L'`Authorization` se pose **sur la requête**, jamais dans la configuration de
    /// session : CFNetwork rejoue celle-ci sur la cible d'une redirection, autre hôte compris.
    static func requete(jeton: JetonNous, delai: TimeInterval) -> URLRequest? {
        guard let hote = jeton.portail.host(percentEncoded: true)?.lowercased(),
              jeton.portail.scheme?.lowercased() == "https",
              IdentifiantsNous.hoteAdmis(hote),
              let url = URL(string: "https://\(hote)\(chemin)") else { return nil }
        var requete = URLRequest(url: url)
        requete.httpMethod = "GET"
        requete.timeoutInterval = delai
        requete.setValue("Bearer \(jeton.valeur)", forHTTPHeaderField: "Authorization")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue(agent, forHTTPHeaderField: "User-Agent")
        return requete
    }

    private static func charger(jeton: JetonNous, session: URLSession, delai: TimeInterval) async -> ReponseAPI {
        guard let requete = requete(jeton: jeton, delai: delai),
              let hote = requete.url?.host(percentEncoded: true) else { return .echec }
        do {
            let (donnees, reponse) = try await session.data(for: requete,
                                                            delegate: RedirectionMemeHoteSeulement(hote: hote))
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            if code != 200 { Journal.donnees.notice("Quota Nous : statut HTTP \(code)") }
            return interpreter(code: code, donnees: donnees)
        } catch {
            Journal.donnees.debug("Quota Nous : portail injoignable")
            return .echec
        }
    }

    /// Seul le 401 dit un jeton périmé. Le 403 refuse l'accès au compte sans dire pourquoi :
    /// rouvrir Hermes n'y changerait rien de certain, et on n'affirme pas plus qu'on ne sait.
    /// Une redirection refusée par la garde revient ici avec son 3xx, donc en échec.
    static func interpreter(code: Int, donnees: Data) -> ReponseAPI {
        switch code {
        case 200: .donnees(donnees)
        case 401: .jetonRefuse
        default: .echec
        }
    }

    // MARK: - Analyse pure

    /// `nil` seulement pour un corps qui n'est pas l'objet attendu, ou qui déclare une erreur.
    static func decoder(_ donnees: Data, mesureA: Date) -> MesureNous? {
        guard let racine = (try? JSONSerialization.jsonObject(with: donnees)) as? [String: Any] else { return nil }
        if let erreur = racine["error"], !(erreur is NSNull) {
            let fauxDeclare = (erreur as? NSNumber).map {
                CFGetTypeID($0) == CFBooleanGetTypeID() && !$0.boolValue
            } ?? false
            guard fauxDeclare else { return nil }
        }
        let abonnement = racine["subscription"] as? [String: Any] ?? [:]
        let acces = racine["paid_service_access"] as? [String: Any] ?? [:]
        let utilisateur = racine["user"] as? [String: Any]
        let organisation = racine["organisation"] as? [String: Any]

        var mesure = MesureNous(quota: Quota([]),
                                mesureA: mesureA,
                                courriel: texte(utilisateur?["email"]),
                                organisation: texte(organisation?["name"]),
                                formule: texte(abonnement["plan"]))

        let publie = montant(abonnement["credits_remaining"])
        let restant = publie == .absent ? montant(acces["subscription_credits_remaining"]) : publie
        if let fenetre = fenetre(dotation: montant(abonnement["monthly_credits"]),
                                 restant: restant,
                                 recharge: (abonnement["current_period_end"] as? String).flatMap(Horodatage.analyser)) {
            mesure.quota = Quota(fenetre)
        }
        return mesure
    }

    /// Un montant publié : absent, illisible, ou un nombre fini.
    enum Montant: Equatable {
        case absent
        case illisible
        case valeur(Double)
    }

    /// Nombre JSON ou chaîne décimale. Un booléen, un infini ou du texte libre sont
    /// illisibles — ni zéro, ni absence.
    static func montant(_ brut: Any?) -> Montant {
        switch brut {
        case nil, is NSNull:
            return .absent
        case let nombre as NSNumber:
            guard CFGetTypeID(nombre) != CFBooleanGetTypeID(), nombre.doubleValue.isFinite else { return .illisible }
            return .valeur(nombre.doubleValue)
        case let texte as String:
            let coupe = texte.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !coupe.isEmpty,
                  coupe.allSatisfy({ $0.isASCII && ($0.isNumber || "+-.eE".contains($0)) }),
                  let valeur = Double(coupe), valeur.isFinite else { return .illisible }
            return .valeur(valeur)
        default:
            return .illisible
        }
    }

    /// ⛔ Une fenêtre exige une dotation **positive** et un restant **lu** : sans l'un des deux,
    /// aucun pourcentage n'est défendable. Palier gratuit (aucune dotation) : pas de fenêtre.
    /// Un restant négatif est un découvert, compté comme dotation entière consommée ; un
    /// restant supérieur à la dotation (report) ne consomme rien du mois.
    static func fenetre(dotation: Montant, restant: Montant, recharge: Date?) -> Fenetre? {
        guard case .valeur(let mensuel) = dotation, mensuel > 0,
              case .valeur(let reste) = restant else { return nil }
        // Borné avant la division : un restant immense ne fait pas déborder le rapport.
        let consomme = min(mensuel, max(0, mensuel - max(0, reste)))
        return Fenetre(libelle: Fenetre.libelleMois,
                       sorte: .mois,
                       utilisation: consomme / mensuel * 100,
                       seRechargeA: recharge)
    }

    private static func texte(_ brut: Any?) -> String? {
        guard let coupe = (brut as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !coupe.isEmpty else { return nil }
        return coupe
    }
}
