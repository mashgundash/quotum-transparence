import Foundation

/// Le jeton que `kilo auth login` dépose sur le disque. Il sert à un appel et n'est ni
/// copié, ni journalisé, ni conservé au-delà du relevé.
struct JetonKilo: Sendable, Equatable {
    let valeur: String
}

/// Ce qu'une lecture d'`auth.json` a établi — même partition que `LectureAugment`.
enum LectureKilo: Sendable, Equatable {
    case jeton(JetonKilo)
    /// Aucun fichier, ou un fichier sans entrée `kilo` : cette machine n'a pas de session
    /// Kilo. Rien à relever, rien à reconnecter.
    case absent
    /// Lecture empêchée, ou entrée `kilo` inexploitable. Rien n'est établi : la prendre pour
    /// une absence ferait disparaître l'outil sans qu'un mot le signale.
    case empechee
}

/// Ce qu'un relevé de Kilo Pass établit. La réponse ne nomme personne : la ligne garde un
/// nom de repli.
struct MesureKilo: Sendable, Equatable {
    /// Une fenêtre au plus : la période de Kilo Pass. Vide quand l'abonnement existe mais
    /// que ses chiffres ne se lisent pas — jamais une grille inventée.
    var quota: Quota
    var mesureA: Date = .now
    /// `subscription.tier`, tel que publié (`tier_19`, `tier_49`…).
    var palier: String?
}

/// Ce que la lecture du jeton puis l'appel à `kiloPass.getState` ont pu établir.
enum ReleveKilo: Sendable, Equatable {
    case releve(MesureKilo)
    /// Le compte répond, mais sans Kilo Pass (`subscription: null`). Il n'a que des blocs
    /// de crédits — un solde sans plafond ni échéance, que le modèle ne met pas dans une
    /// grille. Une reconnexion n'y change rien.
    case sansAbonnement
    /// Jeton présent mais refusé : il se renouvelle par `kilo auth login`.
    case reconnexionNecessaire
    /// L'appel n'a rien établi — réseau coupé, statut inattendu, corps illisible.
    case indetermine
    /// Aucune session Kilo sur cette machine.
    case aucun
}

/// ⛔ **Lecture seule.** Le jeton de rafraîchissement voisin n'est jamais lu : le renouveler
/// ici invaliderait celui du CLI.
enum IdentifiantsKilo {
    /// L'entrée d'`auth.json` qui porte la session de Kilo, et la seule qu'on lise.
    static let entree = "kilo"

    /// `~/.local/share/kilo/auth.json`, ou sous `XDG_DATA_HOME` quand il est déclaré.
    ///
    /// ⚠️ Un `XDG_DATA_HOME` relatif est ignoré : la spécification XDG l'écarte, et un chemin
    /// relatif se résoudrait contre le dossier courant de l'app, que rien ne fixe.
    static func fichier(environnement: [String: String], accueil: URL) -> URL {
        let declare = environnement["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let declare, !declare.isEmpty {
            let etendu = (declare as NSString).expandingTildeInPath
            if etendu.hasPrefix("/") {
                return URL(fileURLWithPath: etendu, isDirectory: true).appendingPathComponent("kilo/auth.json")
            }
        }
        return accueil.appendingPathComponent(".local/share/kilo/auth.json")
    }

    static func jeton(fichier url: URL) async -> LectureKilo {
        await HorsFil.executer { lire(url) }
    }

    static func lire(_ url: URL) -> LectureKilo {
        let donnees: Data
        do {
            donnees = try LectureFichier.lire(url, tailleMaximale: 256 * 1024)
        } catch .absent {
            Journal.donnees.debug("Kilo : aucune session sur cette machine")
            return .absent
        } catch {
            Journal.donnees.notice("Kilo : auth.json illisible (\(String(describing: error)))")
            return .empechee
        }
        return classer(donnees)
    }

    /// ⛔ L'entrée `kilo` et elle seule : le fichier peut en ranger d'autres, et se rabattre
    /// sur un voisin enverrait à Kilo l'identifiant d'un autre service.
    static func classer(_ donnees: Data) -> LectureKilo {
        guard let entrees = try? JSONDecoder().decode([String: Souple<Entree>].self, from: donnees) else {
            Journal.donnees.notice("Kilo : auth.json lu mais inexploitable")
            return .empechee
        }
        guard let brute = entrees[entree] else { return .absent }
        // Une entrée `kilo` qui ne porte pas de jeton d'accès lisible n'est pas une absence :
        // une session existe, sous une forme qu'on ne sait pas lire.
        guard let valeur = brute.valeur?.acces?.trimmingCharacters(in: .whitespacesAndNewlines),
              !valeur.isEmpty else {
            Journal.donnees.notice("Kilo : entrée « kilo » sans jeton d'accès lisible")
            return .empechee
        }
        // Le jeton part dans un en-tête : un caractère de contrôle ou un espace y ouvrirait
        // un second en-tête, ou le couperait.
        guard valeur.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            Journal.donnees.notice("Kilo : jeton d'accès mal formé, relevé abandonné")
            return .empechee
        }
        return .jeton(JetonKilo(valeur: valeur))
    }

    /// Chaque champ se lit seul : `refresh`, `expires` ou `type` peuvent changer de forme
    /// sans emporter le jeton.
    struct Entree: Decodable {
        var acces: String?

        init(from decodeur: Decoder) throws {
            let conteneur = try decodeur.container(keyedBy: CodingKeys.self)
            acces = try? conteneur.decode(String.self, forKey: .acces)
        }

        enum CodingKeys: String, CodingKey {
            case acces = "access"
        }
    }
}

/// Relevé de l'abonnement Kilo Pass par la procédure tRPC `kiloPass.getState`.
///
/// Une seule fenêtre : la dépense de la période en cours contre sa dotation (base + bonus),
/// jusqu'à `nextBillingAt`. ⛔ Les blocs de crédits (`user.getCreditBlocks`) ne sont pas
/// lus : un solde acheté n'a ni plafond périodique ni échéance, et le modèle refuse un
/// solde nu. `user.getAutoTopUpPaymentMethod` non plus : c'est une route de facturation,
/// écartée comme la recharge automatique d'ailleurs.
enum QuotaKilo {
    static let hote = "app.kilo.ai"
    /// L'app s'annonce sous son propre nom, jamais sous celui du client officiel.
    static let agent = "Quotum"
    /// La période de Kilo Pass n'a pas de durée publiée : son échéance se lit sur la ligne,
    /// jamais dans son nom.
    static let libellePeriode = "Fenêtre en cours"

    enum ReponseAPI: Sendable, Equatable {
        case donnees(Data)
        case jetonRefuse
        case echec
    }

    // MARK: - Appel

    static func relever(fichier: URL, session: URLSession, delai: TimeInterval) async -> ReleveKilo {
        switch await IdentifiantsKilo.jeton(fichier: fichier) {
        case .jeton(let jeton): await relever(jeton: jeton, session: session, delai: delai)
        case .absent: .aucun
        case .empechee: .indetermine
        }
    }

    static func relever(jeton: JetonKilo, session: URLSession, delai: TimeInterval) async -> ReleveKilo {
        let reponse = await charger(jeton: jeton, session: session, delai: delai)
        return conclure(reponse, mesureA: Date())
    }

    static func conclure(_ reponse: ReponseAPI, mesureA: Date) -> ReleveKilo {
        switch reponse {
        case .jetonRefuse: .reconnexionNecessaire
        case .echec: .indetermine
        case .donnees(let donnees): analyser(donnees, mesureA: mesureA)
        }
    }

    /// L'appel par lot de tRPC, réduit à une procédure, sans entrée :
    /// `/api/trpc/kiloPass.getState?batch=1&input={"0":{"json":null}}`.
    ///
    /// ⛔ **`GET`, et c'est une garantie, pas une convention** : tRPC ne sert en `GET` que
    /// les *queries* et refuse d'y exécuter une *mutation*. Une procédure qui deviendrait
    /// une écriture répondrait par une erreur, jamais par un effet.
    static func adresse() -> URL? {
        // Écrite en toutes lettres : la page « Ce que Quotum lit » invite à chercher les
        // adresses du code avec `grep 'https\?://' Sources/`.
        guard var composants = URLComponents(string: "https://app.kilo.ai/api/trpc/kiloPass.getState"),
              composants.host == hote else { return nil }
        composants.queryItems = [URLQueryItem(name: "batch", value: "1"),
                                 URLQueryItem(name: "input", value: #"{"0":{"json":null}}"#)]
        return composants.url
    }

    /// ⚠️ L'`Authorization` se pose **sur la requête**, jamais dans la configuration de
    /// session : CFNetwork rejoue celle-ci sur la cible d'une redirection, autre hôte compris.
    static func requete(jeton: JetonKilo, delai: TimeInterval) -> URLRequest? {
        guard let url = adresse() else { return nil }
        var requete = URLRequest(url: url)
        requete.httpMethod = "GET"
        requete.timeoutInterval = delai
        requete.setValue("Bearer \(jeton.valeur)", forHTTPHeaderField: "Authorization")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue(agent, forHTTPHeaderField: "User-Agent")
        return requete
    }

    private static func charger(jeton: JetonKilo, session: URLSession, delai: TimeInterval) async -> ReponseAPI {
        guard let requete = requete(jeton: jeton, delai: delai) else { return .echec }
        do {
            let (donnees, reponse) = try await session.data(for: requete,
                                                            delegate: RedirectionMemeHoteSeulement(hote: hote))
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            if code != 200 { Journal.donnees.notice("Quota Kilo : statut HTTP \(code)") }
            return interpreter(code: code, donnees: donnees)
        } catch {
            Journal.donnees.debug("Quota Kilo : app.kilo.ai injoignable")
            return .echec
        }
    }

    /// 401 et 403 : le jeton est refusé, `kilo auth login` le renouvelle. Tout le reste —
    /// 404, 429, 5xx, une redirection refusée — n'établit rien.
    static func interpreter(code: Int, donnees: Data) -> ReponseAPI {
        switch code {
        case 200: .donnees(donnees)
        case 401, 403: .jetonRefuse
        default: .echec
        }
    }

    // MARK: - Analyses pures

    /// Un montant ou une date, que la réponse le rende en nombre ou en chaîne. `valeur` vaut
    /// `nil` quand le champ est présent mais n'est pas un nombre fini : présent-et-illisible
    /// n'est ni zéro, ni absence.
    private struct Nombre: Decodable {
        let valeur: Double?

        init(from decodeur: Decoder) throws {
            let brut = try decodeur.singleValueContainer()
            let lu: Double?
            if let nombre = try? brut.decode(Double.self) {
                lu = nombre
            } else if let texte = try? brut.decode(String.self) {
                lu = Double(texte.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                lu = nil
            }
            valeur = lu.flatMap { $0.isFinite ? $0 : nil }
        }
    }

    private struct Abonnement: Decodable {
        var consomme: Nombre?
        var base: Nombre?
        var bonus: Nombre?
        var echeance: Horodatage?
        var palier: String?

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            consomme = Self.lire(c, .consomme)
            base = Self.lire(c, .base)
            bonus = Self.lire(c, .bonus)
            echeance = try? c.decodeIfPresent(Horodatage.self, forKey: .echeance)
            palier = try? c.decodeIfPresent(String.self, forKey: .palier)
        }

        /// `null` et absent se valent ; présent sous une autre forme, le champ reste là,
        /// illisible.
        private static func lire(_ c: KeyedDecodingContainer<CodingKeys>, _ cle: CodingKeys) -> Nombre? {
            guard c.contains(cle), (try? c.decodeNil(forKey: cle)) != true else { return nil }
            return try? c.decode(Nombre.self, forKey: cle)
        }

        enum CodingKeys: String, CodingKey {
            case consomme = "currentPeriodUsageUsd"
            case base = "currentPeriodBaseCreditsUsd"
            case bonus = "currentPeriodBonusCreditsUsd"
            case echeance = "nextBillingAt"
            case palier = "tier"
        }
    }

    /// L'état de Kilo Pass. `subscription` doit être **présente** : à `null`, le compte n'a
    /// pas d'abonnement ; absente, la réponse a changé de forme et ne dit plus rien.
    private struct Etat: Decodable {
        enum Abonne {
            case oui(Abonnement)
            case non
        }
        let abonne: Abonne

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            if try c.decodeNil(forKey: .abonnement) {
                abonne = .non
            } else {
                abonne = .oui(try c.decode(Abonnement.self, forKey: .abonnement))
            }
        }

        enum CodingKeys: String, CodingKey { case abonnement = "subscription" }
    }

    /// `result.data` porte la charge utile sous `json` quand le serveur sérialise en
    /// superjson, directement sinon. Les deux écritures se rencontrent.
    private struct Donnees: Decodable {
        let etat: Etat

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CleJSON.self)
            if c.contains(.json) {
                etat = try c.decode(Etat.self, forKey: .json)
            } else {
                etat = try Etat(from: decodeur)
            }
        }

        enum CleJSON: String, CodingKey { case json }
    }

    private struct Erreur: Decodable {
        var code: String?
        var statut: Int?

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: Cles.self)
            // `error.json.data` en superjson, `error.data` sinon.
            let porteur = (try? c.nestedContainer(keyedBy: Cles.self, forKey: .json)) ?? c
            let details = try? porteur.nestedContainer(keyedBy: Cles.self, forKey: .data)
            code = try? details?.decodeIfPresent(String.self, forKey: .code)
            statut = try? details?.decodeIfPresent(Int.self, forKey: .httpStatus)
        }

        enum Cles: String, CodingKey { case json, data, code, httpStatus }

        var refuseLeJeton: Bool {
            code == "UNAUTHORIZED" || code == "FORBIDDEN" || statut == 401 || statut == 403
        }
    }

    private struct Entree: Decodable {
        var resultat: Resultat?
        var erreur: Erreur?

        struct Resultat: Decodable { var data: Donnees }

        enum CodingKeys: String, CodingKey {
            case resultat = "result"
            case erreur = "error"
        }
    }

    /// Le lot ne porte qu'une procédure : son entrée est la première, et la seule lue.
    static func analyser(_ donnees: Data, mesureA: Date) -> ReleveKilo {
        guard let lot = try? JSONDecoder().decode([Souple<Entree>].self, from: donnees),
              let entree = lot.first?.valeur else {
            Journal.donnees.notice("Quota Kilo : réponse illisible")
            return .indetermine
        }
        if let erreur = entree.erreur {
            if erreur.refuseLeJeton { return .reconnexionNecessaire }
            Journal.donnees.notice("Quota Kilo : erreur tRPC « \(erreur.code ?? "sans code") »")
            return .indetermine
        }
        guard let etat = entree.resultat?.data.etat else { return .indetermine }
        switch etat.abonne {
        case .non:
            return .sansAbonnement
        case .oui(let abonnement):
            let palier = abonnement.palier?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fenetre = fenetre(abonnement)
            return .releve(MesureKilo(quota: Quota(fenetre.map { [$0] } ?? []),
                                      mesureA: mesureA,
                                      palier: palier?.isEmpty == false ? palier : nil))
        }
    }

    /// Le pourcentage **consommé** est `dépense / (base + bonus)`, en dollars des deux côtés.
    ///
    /// ⛔ Une dotation nulle, absente ou illisible ne donne pas de fenêtre : la division
    /// rendrait un infini ou un `NaN`, et zéro afficherait un compte vide comme plein. Un
    /// bonus absent compte pour zéro ; présent mais illisible, il ne se devine pas. Une
    /// dépense négative contredit la réponse : aucune fenêtre non plus. Une dépense au-delà
    /// de la dotation est une mesure, que `Fenetre` borne à 100.
    private static func fenetre(_ abonnement: Abonnement) -> Fenetre? {
        guard let consomme = abonnement.consomme?.valeur, consomme >= 0,
              let base = abonnement.base?.valeur, base >= 0 else { return nil }
        var bonus = 0.0
        if let lu = abonnement.bonus {
            guard let valeur = lu.valeur, valeur >= 0 else { return nil }
            bonus = valeur
        }
        let dotation = base + bonus
        guard dotation.isFinite, dotation > 0 else { return nil }
        return Fenetre(libelle: libellePeriode,
                       sorte: .cycle,
                       utilisation: consomme / dotation * 100,
                       seRechargeA: abonnement.echeance?.date)
    }
}
