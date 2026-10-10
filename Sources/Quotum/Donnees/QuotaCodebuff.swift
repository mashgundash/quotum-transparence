import Foundation

/// Ce qu'un relevé direct de Codebuff établit. À la différence de Claude et de
/// ChatGPT, l'identité ne vient pas de la réponse mais du fichier d'identifiants,
/// qui porte le courriel à côté du jeton : la ligne se nomme sans appel réseau.
struct MesureCodebuff: Sendable, Equatable {
    var quota: Quota
    var mesureA: Date = .now
    var courriel: String?
    var nom: String?
    /// Le serveur a refusé le compte faute de quota. C'est une constatation, pas une
    /// déduction sur le pourcentage : elle seule autorise à écrire « quota épuisé ».
    var limiteAtteinte = false
    /// Échéance de la fenêtre qui bloque, quand la réponse la nomme.
    var retour: Date?
}

/// Ce que la lecture de `credentials.json` puis l'appel à l'API ont pu établir. Même
/// partition que `ReleveCodex` : un jeton refusé ne dit rien du quota, et une coupure
/// encore moins.
enum ReleveCodebuff: Sendable, Equatable {
    case releve(MesureCodebuff)
    /// Jeton présent mais refusé. Le compte peut être plein, c'est l'accès qui manque,
    /// et il se retrouve par une reconnexion du CLI.
    case reconnexionNecessaire
    /// L'appel n'a rien établi — réseau coupé, statut inattendu, corps illisible.
    case indetermine
    /// Aucun identifiant Codebuff sur cette machine : rien à relever.
    case aucun
}

/// Le jeton de session posé par le CLI de Codebuff. Il sert à un appel et n'est ni
/// copié sur disque, ni journalisé, ni conservé au-delà du relevé.
struct JetonCodebuff: Sendable {
    let valeur: String
    /// Lus dans le même fichier que le jeton. C'est le seul fournisseur implémenté
    /// dont l'identité ne coûte aucune requête.
    let courriel: String?
    let nom: String?
}

/// Ce qu'une lecture de `credentials.json` a établi — même partition que
/// `LectureCodex`, pour la même raison : un fichier illisible et un poste sans session
/// se ressemblent, et un seul des deux dit quelque chose du compte.
enum LectureCodebuff: Sendable {
    case jeton(JetonCodebuff)
    /// Aucun fichier, ou un fichier lisible sans jeton. Il n'y a rien à relever.
    case absent
    /// Lecture empêchée — droits refusés, contenu inexploitable. Rien n'est établi.
    case empechee
}

/// Les identifiants que le CLI de Codebuff dépose sur le disque.
enum IdentifiantsCodebuff {
    /// ⚠️ Le fichier garde le nom du produit d'avant son changement de nom, et
    /// **aucune variable d'environnement ne le déplace** : ni un `HOME` de Codebuff,
    /// ni `XDG_CONFIG_HOME`. Honorer une variable inventée ferait chercher un fichier
    /// qui n'est nulle part, et conclure à l'absence de session sur un poste connecté.
    static func fichier(accueil: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        accueil.appendingPathComponent(".config/manicode/credentials.json")
    }

    static func jeton(fichier url: URL? = nil) async -> LectureCodebuff {
        let cible = url ?? fichier()
        return await HorsFil.executer { lire(cible) }
    }

    static func lire(_ url: URL) -> LectureCodebuff {
        let donnees: Data
        do {
            donnees = try Data(contentsOf: url)
        } catch {
            guard estAbsence(error) else {
                Journal.donnees.notice("Codebuff : credentials.json illisible (\(error))")
                return .empechee
            }
            Journal.donnees.debug("Codebuff : aucun credentials.json sur cette machine")
            return .absent
        }
        return classer(donnees)
    }

    /// Ce qu'un contenu de `credentials.json` établit. Un JSON valide sans jeton
    /// conclut — ce poste n'a pas de session ; un contenu illisible ne conclut rien.
    static func classer(_ donnees: Data) -> LectureCodebuff {
        guard let enveloppe = try? JSONDecoder().decode(Enveloppe.self, from: donnees) else {
            Journal.donnees.notice("Codebuff : credentials.json lu mais inexploitable")
            return .empechee
        }
        let brut = enveloppe.defaut?.jeton?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !brut.isEmpty else { return .absent }
        return .jeton(JetonCodebuff(valeur: brut,
                                    courriel: nonVide(enveloppe.defaut?.courriel),
                                    nom: nonVide(enveloppe.defaut?.nom)))
    }

    /// Le schéma tolère d'autres clés que `default`, mais aucun appelant n'en produit :
    /// se rabattre sur une clé voisine poserait la mesure d'un compte sur la ligne d'un
    /// autre. Les clés inconnues, elles, sont ignorées sans faire échouer la lecture.
    private struct Enveloppe: Decodable {
        struct Profil: Decodable {
            var jeton: String?
            var courriel: String?
            var nom: String?

            enum CodingKeys: String, CodingKey {
                case jeton = "authToken"
                case courriel = "email"
                case nom = "name"
            }
        }

        var defaut: Profil?

        enum CodingKeys: String, CodingKey {
            case defaut = "default"
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

/// Relevé direct du quota Codebuff, calqué sur `QuotaCodex`. C'est le fournisseur dont
/// le modèle colle le mieux au panneau : deux fenêtres indépendantes, un bloc court et
/// une semaine, comme Claude.
enum QuotaCodebuff {
    static let hote = "https://www.codebuff.com"
    /// Trois routes portent la consommation, chacune avec sa forme d'authentification.
    /// Celle-ci est la seule à publier les **deux** fenêtres, et elle s'authentifie par
    /// cookie de session.
    static let chemin = "/api/user/subscription"
    static let cookieSession = "next-auth.session-token"

    /// L'app s'annonce sous son propre nom. Se faire passer pour le client officiel
    /// stabiliserait peut-être l'accès — c'est une infraction d'une autre nature que
    /// de lire un jeton qu'on a le droit de lire.
    static let agent = "Quotum"

    /// Les deux motifs de refus publiés. Ils nomment la fenêtre qui bloque, donc
    /// l'échéance à afficher.
    static let motifBlocEpuise = "block_exhausted"
    static let motifSemaineEpuisee = "weekly_limit"

    /// Ce qu'un appel a rapporté. Le refus de jeton se distingue de l'échec ordinaire
    /// parce qu'il se règle par une reconnexion, là où l'autre ne demande rien.
    enum ReponseAPI: Sendable, Equatable {
        case donnees(Data)
        case jetonRefuse
        case echec
    }

    static func relever(session: URLSession = Reseau.session,
                        delai: TimeInterval = 8) async -> ReleveCodebuff {
        switch await IdentifiantsCodebuff.jeton() {
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

    static func relever(jeton: JetonCodebuff,
                        session: URLSession = Reseau.session,
                        delai: TimeInterval = 8) async -> ReleveCodebuff {
        let reponse = await charger(jeton: jeton, session: session, delai: delai)
        let mesureA = Date()

        switch reponse {
        case .jetonRefuse:
            return .reconnexionNecessaire
        case .echec:
            return .indetermine
        case .donnees(let donnees):
            guard let quota = decoderUsage(donnees) else { return .indetermine }
            let blocage = decoderBlocage(donnees)
            return .releve(MesureCodebuff(quota: quota,
                                          mesureA: mesureA,
                                          courriel: jeton.courriel,
                                          nom: jeton.nom,
                                          limiteAtteinte: blocage.atteinte,
                                          retour: blocage.retour))
        }
    }

    static func requete(jeton: JetonCodebuff, delai: TimeInterval) -> URLRequest? {
        guard let url = URL(string: hote + chemin), valeurDeCookieValide(jeton.valeur) else {
            return nil
        }
        var requete = URLRequest(url: url)
        requete.httpMethod = "GET"
        requete.timeoutInterval = delai
        // ⚠️ Le secret voyage dans un cookie, et il se pose **sur la requête** : un
        // en-tête d'identification placé dans la configuration de session est rejoué
        // vers l'hôte cible d'une redirection, autre domaine compris.
        requete.setValue("\(cookieSession)=\(jeton.valeur)", forHTTPHeaderField: "Cookie")
        // Sans cela, le magasin de cookies de la session pourrait remplacer l'en-tête
        // posé ici, ou retenir un `Set-Cookie` de la réponse pour l'appel suivant.
        requete.httpShouldHandleCookies = false
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue(agent, forHTTPHeaderField: "User-Agent")
        return requete
    }

    /// RFC 6265 : la valeur d'un cookie n'admet que de l'ASCII imprimable, sans espace,
    /// guillemet, point-virgule ni antislash. Un jeton qui en sort n'est pas un jeton,
    /// et un saut de ligne y ouvrirait une injection d'en-tête — d'où le refus, plutôt
    /// qu'un échappement qui laisserait partir la valeur.
    static func valeurDeCookieValide(_ valeur: String) -> Bool {
        guard !valeur.isEmpty else { return false }
        return valeur.unicodeScalars.allSatisfy { scalaire in
            switch scalaire.value {
            case 0x21, 0x23...0x2B, 0x2D...0x3A, 0x3C...0x5B, 0x5D...0x7E: true
            default: false
            }
        }
    }

    private static func charger(jeton: JetonCodebuff,
                                session: URLSession,
                                delai: TimeInterval) async -> ReponseAPI {
        guard let requete = requete(jeton: jeton, delai: delai) else { return .echec }

        do {
            let (donnees, reponse) = try await session.data(for: requete,
                                                              delegate: RedirectionCodebuffSeulement())
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            journaliser(code: code)
            return interpreter(code: code, donnees: donnees)
        } catch {
            Journal.donnees.debug("Quota Codebuff : codebuff.com injoignable")
            return .echec
        }
    }

    /// Le cookie de session se retrouve par une reconnexion du CLI, jamais en
    /// réessayant : le 401 est le seul statut dont l'utilisateur ait quelque chose à
    /// faire. Une page de connexion rendue en 200 tombe, elle, sur un corps illisible.
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
            Journal.donnees.notice("Quota Codebuff : jeton refusé (401), reconnexion à refaire")
        default:
            Journal.donnees.notice("Quota Codebuff : statut HTTP \(code)")
        }
    }

    // MARK: - Analyses pures

    private struct ReponseAbonnement: Decodable {
        struct Limite: Decodable {
            var limitee: Bool?
            var motif: String?
            var blocConsomme: Double?
            var blocPlafond: Double?
            var blocSeRechargeA: Horodatage?
            var semaineConsomme: Double?
            var semainePlafond: Double?
            var semainePourcentage: Double?
            var semaineSeRechargeA: Horodatage?

            enum CodingKeys: String, CodingKey {
                case limitee = "limited"
                case motif = "reason"
                case blocConsomme = "blockUsed"
                case blocPlafond = "blockLimit"
                case blocSeRechargeA = "blockResetsAt"
                case semaineConsomme = "weeklyUsed"
                case semainePlafond = "weeklyLimit"
                case semainePourcentage = "weeklyPercentUsed"
                case semaineSeRechargeA = "weeklyResetsAt"
            }
        }

        var limite: Limite?

        enum CodingKeys: String, CodingKey {
            case limite = "rateLimit"
        }
    }

    /// ⛔ Un compte **sans abonnement** n'a aucune fenêtre : il ne lui reste qu'un solde
    /// de crédits à la carte, dont le plafond n'est pas publié. Il rend donc un quota
    /// **vide**, jamais une fenêtre à 0 % — qui annoncerait un bloc intact là où rien
    /// n'est mesuré. `nil` est réservé à ce qui n'est même pas un objet JSON : une page
    /// de connexion servie en 200, un corps tronqué.
    static func decoderUsage(_ donnees: Data) -> Quota? {
        guard let reponse = try? JSONDecoder().decode(ReponseAbonnement.self, from: donnees) else {
            return nil
        }
        guard let limite = reponse.limite else { return Quota([]) }
        return Quota(fenetres(limite))
    }

    /// `limited` est un refus constaté par le serveur, pas une lecture du pourcentage.
    /// ⚠️ `canStartNewBlock` n'est volontairement pas consulté : aucune réponse réelle
    /// n'a été observée, et s'en servir pour contredire `limited` affirmerait plus que
    /// ce qu'on sait.
    static func decoderBlocage(_ donnees: Data) -> (atteinte: Bool, retour: Date?) {
        guard let reponse = try? JSONDecoder().decode(ReponseAbonnement.self, from: donnees),
              let limite = reponse.limite, limite.limitee == true else { return (false, nil) }
        return (true, echeance(limite))
    }

    /// ⛔ La durée des fenêtres n'est publiée **nulle part** : « 5 h » est une constante
    /// du client, variable selon le palier, et le serveur ne donne que des dates
    /// absolues. `duree` reste donc `nil` — l'inventer ferait passer une convention
    /// pour une mesure, et fausserait le classement d'une fenêtre d'un autre palier.
    ///
    /// ⚠️ Les deux fenêtres sont indépendantes : le bloc court et la semaine ne
    /// s'épuisent pas ensemble. La plus courte vient en tête, parce que c'est elle qui
    /// se rouvre la première et que l'ordre de la liste départage les ex æquo.
    private static func fenetres(_ limite: ReponseAbonnement.Limite) -> [Fenetre] {
        [bloc(limite), semaine(limite)].compactMap { $0 }
    }

    private static func bloc(_ limite: ReponseAbonnement.Limite) -> Fenetre? {
        guard let consomme = pourcentage(consomme: limite.blocConsomme,
                                         plafond: limite.blocPlafond) else { return nil }
        return Fenetre.cinqHeures(utilisation: consomme, seRechargeA: limite.blocSeRechargeA?.date)
    }

    private static func semaine(_ limite: ReponseAbonnement.Limite) -> Fenetre? {
        // Un plafond hebdomadaire nul n'est pas une semaine intacte, c'est l'absence de
        // fenêtre — et le pourcentage publié vaut alors zéro, ce qui dirait l'inverse.
        if let plafond = limite.semainePlafond, plafond <= 0 { return nil }
        // Le pourcentage hebdomadaire est publié, contrairement à celui du bloc ; le
        // calcul ne sert que s'il manque.
        guard let consomme = limite.semainePourcentage
            ?? pourcentage(consomme: limite.semaineConsomme,
                           plafond: limite.semainePlafond) else { return nil }
        return Fenetre.septJours(utilisation: consomme, seRechargeA: limite.semaineSeRechargeA?.date)
    }

    /// ⛔ `blockPercentUsed` n'existe pas : il se calcule. Un plafond nul ou absent ne
    /// donne pas 0 %, il ne donne rien — un rapport sans dénominateur n'est pas une
    /// mesure à zéro. ⚠️ Le produit, lui, peut déborder à l'infini sur deux valeurs
    /// pourtant finies (`100 × 1e308`) : c'est `Fenetre` qui l'écarte, et la fenêtre
    /// disparaît alors au lieu de s'afficher intacte.
    private static func pourcentage(consomme: Double?, plafond: Double?) -> Double? {
        guard let consomme, let plafond, plafond > 0, consomme.isFinite else { return nil }
        return 100 * consomme / plafond
    }

    private static func echeance(_ limite: ReponseAbonnement.Limite) -> Date? {
        switch limite.motif {
        case motifBlocEpuise:
            return limite.blocSeRechargeA?.date
        case motifSemaineEpuisee:
            return limite.semaineSeRechargeA?.date
        default:
            // Motif absent ou inconnu : l'échéance la plus lointaine parmi les fenêtres
            // saturées, jamais la première rencontrée.
            return fenetres(limite)
                .filter { $0.utilisation >= 100 }
                .compactMap(\.seRechargeA)
                .max()
        }
    }
}

/// ⛔ Le secret de Codebuff voyage dans un **cookie**, pas dans `Authorization`. La mesure
/// du 2026-09-17 sur CFNetwork ne couvre que l'en-tête d'autorisation : rien ne dit
/// qu'un cookie posé par requête ne serait pas rejoué vers la cible d'une redirection.
/// Faute de l'avoir mesuré, on ne suit aucune redirection qui quitte l'hôte du produit.
final class RedirectionCodebuffSeulement: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              url.user(percentEncoded: true) == nil,
              url.password(percentEncoded: true) == nil,
              url.host(percentEncoded: true)?.lowercased() == "www.codebuff.com"
        else { return nil }
        return request
    }
}
