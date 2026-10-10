import Foundation

/// La session qu'`auggie` dépose sur le disque. Elle porte deux choses, et la seconde
/// n'a pas d'équivalent chez les fournisseurs déjà implémentés : **l'adresse de l'API
/// appartient au compte**. Elle se lit dans le fichier, elle ne se code pas en dur —
/// deux abonnements Augment ne parlent pas au même hôte.
struct JetonAugment: Sendable, Equatable {
    let valeur: String
    /// Racine du tenant, telle qu'écrite sur le disque : `https://<tenant>.api.augmentcode.com/`,
    /// avec ou sans barre finale. Brute ici, normalisée au moment de composer l'adresse.
    let tenant: String
}

/// Ce qu'une lecture de `session.json` a établi — même partition que `LectureCodex`.
enum LectureAugment: Sendable {
    case jeton(JetonAugment)
    /// Aucun fichier, ou un fichier lisible sans jeton : cette machine n'a pas de
    /// session Augment. Rien à relever, rien à reconnecter.
    case absent
    /// Lecture empêchée, ou session inexploitable. Rien n'est établi : la prendre pour
    /// une absence ferait disparaître le fournisseur sans qu'un mot le signale.
    case empechee
}

/// Ce qu'un résumé de facturation d'Augment établit. Pas d'identité ici : l'endpoint
/// n'en publie aucune, et c'est l'URL de tenant qui porte celle du compte.
struct ReleveAugment: Sendable, Equatable {
    var quota: Quota
    var mesureA: Date = .now
    var plan: String?
}

/// Ce que la lecture de la session puis l'appel ont pu établir. Même partition que
/// `ReleveCodex`, pour la même raison : un jeton refusé ne dit rien du quota.
enum ReleveAuggie: Sendable, Equatable {
    case releve(ReleveAugment)
    /// Jeton présent mais refusé. Se règle par un `auggie login`, pas en réessayant.
    case reconnexionNecessaire
    /// L'appel n'a rien établi — réseau coupé, statut inattendu, corps illisible.
    case indetermine
    /// Aucune session Augment sur cette machine.
    case aucun
}

/// L'unité dans laquelle Augment compte, telle que `usage_unit` la publie : une
/// énumération **numérique**, pas un nom.
enum UniteAugment: Int, Sendable, Equatable {
    case credits = 1
    case dollars = 2
}

/// La session d'`auggie` sur le disque. Pendant d'`IdentifiantsCodex`, à ceci près
/// qu'un jeton seul n'y suffit pas : sans l'adresse de tenant, il n'y a rien à
/// interroger.
enum SessionAugment {
    static func fichier(accueil: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        accueil.appendingPathComponent(".augment/session.json")
    }

    static func jeton(fichier url: URL? = nil) async -> LectureAugment {
        let cible = url ?? fichier()
        return await HorsFil.executer { lire(cible) }
    }

    static func lire(_ url: URL) -> LectureAugment {
        let donnees: Data
        do {
            donnees = try Data(contentsOf: url)
        } catch {
            guard estAbsence(error) else {
                Journal.donnees.notice("Augment : session.json illisible (\(error))")
                return .empechee
            }
            Journal.donnees.debug("Augment : aucune session sur cette machine")
            return .absent
        }
        return classer(donnees)
    }

    static func classer(_ donnees: Data) -> LectureAugment {
        guard let enveloppe = try? JSONDecoder().decode(Enveloppe.self, from: donnees) else {
            Journal.donnees.notice("Augment : session.json lu mais inexploitable")
            return .empechee
        }
        guard let acces = nonVide(enveloppe.acces) else { return .absent }
        // Un jeton sans adresse de tenant ne mène nulle part, et ce n'est pas une
        // absence de session : conclure l'absence effacerait en silence un compte qui
        // existe, au lieu de signaler une session à refaire.
        guard let tenant = nonVide(enveloppe.tenant) else {
            Journal.donnees.notice("Augment : session sans tenantURL, aucune adresse à interroger")
            return .empechee
        }
        return .jeton(JetonAugment(valeur: acces, tenant: tenant))
    }

    private struct Enveloppe: Decodable {
        var acces: String?
        var tenant: String?

        enum CodingKeys: String, CodingKey {
            case acces = "accessToken"
            case tenant = "tenantURL"
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

/// CFNetwork suit les redirections de lui-même. L'hôte est contrôlé avant l'appel,
/// mais un `302` le remplacerait après coup — et cet hôte-là vient d'un fichier du
/// disque, pas d'une constante. La cible repasse donc par la même liste.
final class RedirectionAugmentSeulement: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, QuotaAugment.urlAutorisee(url) else { return nil }
        return request
    }
}

/// Relevé du quota Augment. Une seule fenêtre — le cycle de facturation mensuel — et
/// aucun pourcentage livré : il se calcule à partir d'un **restant**, ce qui impose
/// une inversion que rien dans la réponse ne rappelle.
enum QuotaAugment {
    /// Le domaine hors duquel aucun jeton ne part. L'hôte vient du disque : rien dans
    /// `URL(string:)` n'empêche cette ligne de nommer une machine étrangère, à qui
    /// partirait alors le `Bearer`. Une liste de refus laisserait toujours passer la
    /// forme qu'on n'a pas prévue ; celle-ci nomme ce qu'elle accepte.
    static let domaine = "augmentcode.com"
    static let chemin = "get-billing-summary"

    /// L'app s'annonce sous son propre nom, jamais sous celui du client officiel.
    static let agent = "Quotum"

    /// Identifiant de session de l'exécution en cours : un corrélateur de journal
    /// serveur, tiré au sort au lancement. Il ne désigne ni compte ni machine.
    static let sessionIdentifiant = UUID().uuidString

    enum ReponseAPI: Sendable, Equatable {
        case donnees(Data)
        case jetonRefuse
        case echec
    }

    // MARK: - Adresse

    /// ⛔ `URL(string:relativeTo:)` **écrase le dernier segment** quand la base n'a pas
    /// de barre finale — mesuré : `https://hôte/t/abc` + `get-billing-summary` donne
    /// `https://hôte/t/get-billing-summary`, un 404 silencieux sur une route voisine.
    /// D'où la normalisation explicite, qui accepte les deux écritures du fichier.
    static func adresseFacturation(tenant: String) -> URL? {
        var racine = tenant.trimmingCharacters(in: .whitespacesAndNewlines)
        while racine.hasSuffix("/") { racine.removeLast() }
        guard !racine.isEmpty, let url = URL(string: racine + "/" + chemin) else { return nil }
        return urlAutorisee(url) ? url : nil
    }

    static func urlAutorisee(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user(percentEncoded: true) == nil,
              url.password(percentEncoded: true) == nil,
              // La route ne porte ni l'un ni l'autre : les accepter ferait viser autre
              // chose que ce que la composition a écrit.
              url.query(percentEncoded: true) == nil,
              url.fragment(percentEncoded: true) == nil,
              let hote = url.host(percentEncoded: true),
              // Un hôte percent-encodé se lit différemment selon qui le décode ; le
              // refuser supprime l'écart entre ce qui est validé ici et ce que la pile
              // réseau joindra.
              hote == url.host(percentEncoded: false),
              hoteAutorise(hote),
              url.port.map((1...65_535).contains) ?? true
        else { return false }
        return true
    }

    /// Le point qui précède le domaine n'est pas décoratif : sans lui,
    /// `evilaugmentcode.com` passerait.
    static func hoteAutorise(_ hote: String) -> Bool {
        let bas = hote.lowercased()
        return bas == domaine || bas.hasSuffix("." + domaine)
    }

    // MARK: - Appel

    static func relever(session: URLSession = Reseau.session,
                        delai: TimeInterval = 8) async -> ReleveAuggie {
        switch await SessionAugment.jeton() {
        case .jeton(let jeton):
            return await relever(jeton: jeton, session: session, delai: delai)
        case .absent:
            return .aucun
        case .empechee:
            return .indetermine
        }
    }

    static func relever(jeton: JetonAugment,
                        session: URLSession = Reseau.session,
                        delai: TimeInterval = 8) async -> ReleveAuggie {
        let reponse = await charger(jeton: jeton, session: session, delai: delai)
        let mesureA = Date()

        switch reponse {
        case .jetonRefuse:
            return .reconnexionNecessaire
        case .echec:
            return .indetermine
        case .donnees(let donnees):
            guard let quota = decoderFacturation(donnees) else { return .indetermine }
            return .releve(ReleveAugment(quota: quota, mesureA: mesureA, plan: decoderPlan(donnees)))
        }
    }

    /// Le corps utile est vide, mais la méthode reste POST : c'est un RPC, pas une
    /// lecture de ressource.
    static func requete(jeton: JetonAugment, delai: TimeInterval) -> URLRequest? {
        guard let url = adresseFacturation(tenant: jeton.tenant) else { return nil }
        var requete = URLRequest(url: url)
        requete.httpMethod = "POST"
        requete.timeoutInterval = delai
        requete.httpBody = Data("{}".utf8)
        requete.setValue("Bearer \(jeton.valeur)", forHTTPHeaderField: "Authorization")
        requete.setValue("application/json", forHTTPHeaderField: "Content-Type")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue(agent, forHTTPHeaderField: "User-Agent")
        requete.setValue(UUID().uuidString, forHTTPHeaderField: "x-request-id")
        requete.setValue(sessionIdentifiant, forHTTPHeaderField: "x-request-session-id")
        return requete
    }

    private static func charger(jeton: JetonAugment,
                                session: URLSession,
                                delai: TimeInterval) async -> ReponseAPI {
        guard let requete = requete(jeton: jeton, delai: delai) else {
            Journal.donnees.notice("Quota Augment : adresse de tenant refusée, hors du domaine d'Augment")
            return .echec
        }

        do {
            let (donnees, reponse) = try await session.data(for: requete,
                                                            delegate: RedirectionAugmentSeulement())
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            journaliser(code: code)
            return interpreter(code: code, donnees: donnees)
        } catch {
            Journal.donnees.debug("Quota Augment : tenant injoignable")
            return .echec
        }
    }

    /// Le jeton de session se renouvelle par un `auggie login` : le 401 est le seul
    /// statut dont l'utilisateur ait quelque chose à faire.
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
            Journal.donnees.notice("Quota Augment : jeton refusé (401), `auggie login` à refaire")
        default:
            Journal.donnees.notice("Quota Augment : statut HTTP \(code)")
        }
    }

    // MARK: - Analyses pures

    /// Un montant, que la réponse le rende en nombre ou en chaîne. Chez ChatGPT
    /// `credits.balance` est déjà une chaîne : abandonner la réponse entière sur cette
    /// variante-là coûterait la mesure.
    private struct Montant: Decodable {
        let valeur: Double?

        init(from decodeur: Decoder) throws {
            let brut = try decodeur.singleValueContainer()
            if brut.decodeNil() {
                valeur = nil
            } else if let nombre = try? brut.decode(Double.self) {
                valeur = nombre
            } else if let texte = try? brut.decode(String.self) {
                valeur = Double(texte.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                valeur = nil
            }
        }
    }

    private struct Echeance: Decodable {
        let date: Date?

        init(from decodeur: Decoder) throws {
            let brut = try decodeur.singleValueContainer()
            if brut.decodeNil() {
                date = nil
            } else if let texte = try? brut.decode(String.self) {
                date = QuotaAugment.analyserEcheance(texte)
            } else if let nombre = try? brut.decode(Double.self) {
                date = Horodatage.analyser(epoch: nombre)
            } else {
                date = nil
            }
        }
    }

    private struct ResumeFacturation: Decodable {
        var plan: String?
        var unite: Montant?
        var restant: Montant?
        var inclus: Montant?
        var finDeCycle: Echeance?

        enum CodingKeys: String, CodingKey {
            case plan = "plan_name"
            case unite = "usage_unit"
            case restant = "amount_remaining"
            case inclus = "amount_included_per_cycle"
            case finDeCycle = "billing_cycle_end_date_iso"
        }
    }

    /// `billing_cycle_end_date_iso` est une **date de fin**, pas une durée : elle
    /// alimente `seRechargeA` et `Fenetre.duree` reste `nil`. Un champ nommé `…_date_iso`
    /// peut ne porter qu'un jour, que l'analyseur maison refuse — le compléter à
    /// minuit UTC vaut mieux que perdre la seule échéance publiée par ce fournisseur.
    static func analyserEcheance(_ texte: String?) -> Date? {
        guard let coupe = texte?.trimmingCharacters(in: .whitespacesAndNewlines), !coupe.isEmpty else {
            return nil
        }
        if let complet = Horodatage.analyser(coupe) { return complet }
        guard !coupe.contains("T") else { return nil }
        return Horodatage.analyser(coupe + "T00:00:00Z")
    }

    /// `Quota([])` et `nil` ne disent pas la même chose. Le premier est une réponse
    /// comprise dont aucun chiffre n'est exploitable — plan sans quota publié, unité
    /// qui n'est pas du crédit, plafond absent : la grille disparaît, et **aucune
    /// fenêtre à 0 % n'est fabriquée**, qui afficherait un compte plein comme vide.
    /// Le second est un corps qui n'était pas un résumé de facturation.
    static func decoderFacturation(_ donnees: Data) -> Quota? {
        guard let resume = try? JSONDecoder().decode(ResumeFacturation.self, from: donnees) else {
            return nil
        }
        guard let fenetre = fenetre(de: resume) else { return Quota([]) }
        return Quota(fenetre)
    }

    static func decoderPlan(_ donnees: Data) -> String? {
        guard let resume = try? JSONDecoder().decode(ResumeFacturation.self, from: donnees),
              let coupe = resume.plan?.trimmingCharacters(in: .whitespacesAndNewlines),
              !coupe.isEmpty else { return nil }
        return coupe
    }

    /// ⛔ `amount_remaining` est ce qu'**il reste**, là où `Fenetre.utilisation` attend
    /// ce qui est **consommé** : l'inversion est obligatoire, et l'oublier affiche un
    /// compte plein comme vide. Et un plafond nul ou absent ne donne pas 0 % — il ne
    /// donne aucune fenêtre, sans quoi la division rendrait un compte à sec
    /// parfaitement plein.
    ///
    /// La consommation s'écrit `(plafond − restant) / plafond` plutôt que
    /// `1 − restant / plafond` : les deux sont la même quantité, mais la seconde perd
    /// ses derniers chiffres quand le restant approche le plafond — un compte intact à
    /// 90 % en sortait à 9,999999999999998 %.
    ///
    /// ⛔ Seul le crédit remplit une grille. Facturé au dollar, ce que la réponse
    /// décrit est un **solde** : il ne bloque rien, il se dépasse et se facture, et le
    /// projet ne met pas un solde dans une grille. Une unité inconnue suit la même
    /// règle — elle n'est pas rangée au hasard avec le crédit.
    private static func fenetre(de resume: ResumeFacturation) -> Fenetre? {
        guard unite(resume) == .credits,
              let inclus = resume.inclus?.valeur, inclus.isFinite, inclus > 0,
              let restant = resume.restant?.valeur, restant.isFinite else { return nil }
        return Fenetre(libelle: Fenetre.libelleMois,
                       sorte: .mois,
                       utilisation: 100 * (inclus - restant) / inclus,
                       seRechargeA: resume.finDeCycle?.date)
    }

    private static func unite(_ resume: ResumeFacturation) -> UniteAugment? {
        guard let brut = resume.unite?.valeur, let entier = Int(exactly: brut.rounded()) else {
            return nil
        }
        return UniteAugment(rawValue: entier)
    }
}
