import Foundation
import SQLite3

/// Le jeton de session que l'éditeur Cursor dépose dans sa base locale. C'est un JWT :
/// il porte lui-même l'identité de son détenteur, ce qui évite un second appel pour
/// savoir sur quelle ligne poser la mesure. Il sert à un appel et n'est ni copié sur
/// disque, ni journalisé.
struct JetonCursor: Sendable, Equatable {
    /// Le JWT brut, tel qu'il part dans le cookie.
    let valeur: String
    /// Dernier segment du `sub` — la revendication vaut `auth0|user_XXX`, et c'est
    /// `user_XXX` seul que le cookie attend. Non optionnel : sans lui il n'y a pas de
    /// cookie possible, donc pas de jeton exploitable à construire.
    let utilisateurIdentifiant: String
    let courriel: String?
    let expireA: Date?
}

/// Les revendications qu'on lit dans la charge utile du JWT. ⛔ La signature n'est pas
/// vérifiée, et n'a pas à l'être : on n'authentifie personne, on relit un jeton que
/// l'éditeur a écrit pour lui-même afin d'en extraire de quoi le renvoyer.
struct RevendicationsCursor: Sendable, Equatable {
    var sujet: String?
    var courriel: String?
    var expireA: Date?
}

/// Ce qu'une lecture de la base de Cursor a établi — même partition que
/// `LectureCodex`, pour la même raison : une machine sans Cursor et une base illisible
/// se ressemblaient, et une seule des deux dit quelque chose du compte.
enum LectureCursor: Sendable, Equatable {
    case jeton(JetonCursor)
    /// Aucune base, ou une base sans jeton de session — un poste jamais connecté en
    /// est là. Il n'y a rien à relever, et rien à reconnecter.
    case absent
    /// Lecture empêchée — base verrouillée, droits refusés, jeton présent mais
    /// inexploitable. Rien n'est établi : la session peut être là, intacte.
    case empechee
}

/// Les identifiants que l'éditeur Cursor dépose sur le disque, dans la base SQLite de
/// son stockage global. Pendant d'`IdentifiantsCodex`, à ceci près que la source est
/// une base et non un fichier JSON : la lecture reste hors du fil principal, le
/// panneau doit se dessiner pendant que le disque répond.
enum IdentifiantsCursor {
    static let cleJeton = "cursorAuth/accessToken"
    /// Le courriel que l'éditeur met en cache à côté du jeton. Il ne sert que de
    /// secours : la revendication `email` du JWT prime quand elle est là.
    static let cleCourriel = "cursorAuth/cachedEmail"
    static let table = "ItemTable"

    /// Cursor se lance avec `--user-data-dir`, comme les deux applications déjà
    /// gérées : c'est ce qui lui donne un parc, et la base suit le dossier de données.
    static func fichier(dossierDonnees: URL) -> URL {
        dossierDonnees.appendingPathComponent("User/globalStorage/state.vscdb")
    }

    static func dossierParDefaut(accueil: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        accueil.appendingPathComponent("Library/Application Support/Cursor", isDirectory: true)
    }

    static func fichier(accueil: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        fichier(dossierDonnees: dossierParDefaut(accueil: accueil))
    }

    static func jeton(fichier url: URL? = nil) async -> LectureCursor {
        let cible = url ?? fichier()
        return await HorsFil.executer { lire(cible) }
    }

    static func lire(_ url: URL) -> LectureCursor {
        guard FileManager.default.fileExists(atPath: url.path) else {
            Journal.donnees.debug("Cursor : aucune base de session sur cette machine")
            return .absent
        }
        guard let base = ouvrir(url) else {
            Journal.donnees.notice("Cursor : base présente mais illisible")
            return .empechee
        }
        defer { sqlite3_close(base) }

        switch entrees(base: base) {
        case .echec:
            Journal.donnees.notice("Cursor : base présente mais inexploitable")
            return .empechee
        case .lues(let jeton, let courriel):
            guard let jeton else {
                Journal.donnees.debug("Cursor : base présente, aucune session ouverte")
                return .absent
            }
            return classer(jeton, courrielSecours: courriel)
        }
    }

    // MARK: - Base SQLite, en lecture seule

    /// Deux adresses, essayées dans cet ordre, et jamais une ouverture en écriture :
    /// la base appartient à une autre application, qui peut l'avoir ouverte.
    ///
    /// `mode=ro` donne l'état courant, journal WAL compris — c'est ce qu'on veut quand
    /// l'éditeur tourne. Il échoue quand le `-shm` manque ou n'est pas créable ;
    /// `immutable=1` prend alors le relais en lisant le fichier principal seul, sans
    /// verrou ni sidecar. La donnée peut y être d'un cran plus ancienne, ce qui est
    /// sans conséquence pour un jeton de session.
    static func adresses(_ url: URL) -> [String] {
        let base = url.absoluteString
        return ["\(base)?mode=ro", "\(base)?immutable=1"]
    }

    private static func ouvrir(_ url: URL) -> OpaquePointer? {
        for adresse in adresses(url) {
            var base: OpaquePointer?
            if sqlite3_open_v2(adresse, &base, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
               let base {
                // Sans lui, une écriture concurrente de l'éditeur fait échouer la
                // lecture sur-le-champ — la ligne disparaît du panneau jusqu'au tour
                // suivant, silencieusement.
                sqlite3_busy_timeout(base, 250)
                return base
            }
            if let base { sqlite3_close(base) }
        }
        return nil
    }

    /// ⚠️ Une requête sans résultat et une requête qui n'a pas pu s'exécuter ne disent
    /// pas la même chose, et les confondre ferait passer un fichier corrompu pour un
    /// poste sans session. SQLite ouvre **paresseusement** : `sqlite3_open_v2` réussit
    /// sur un fichier qui n'est pas une base, et c'est la préparation qui échoue.
    private enum LectureEntrees {
        /// La requête a abouti. Une valeur nulle dit que la clé n'était pas là — pas
        /// qu'on n'a pas su la lire.
        case lues(jeton: String?, courriel: String?)
        case echec
    }

    /// Les deux clés en **une** requête, donc en une seule lecture cohérente. Deux
    /// `SELECT` successifs ouvrent chacun leur transaction implicite et voient chacun
    /// leur instantané de la base : une reconnexion de l'éditeur entre les deux
    /// appariait le jeton d'un compte au courriel d'un autre, et la mesure partait sur
    /// la mauvaise ligne.
    ///
    /// La colonne `value` est déclarée BLOB : la lire en octets plutôt qu'en texte évite
    /// de dépendre de la conversion implicite de SQLite. `key` se lit de même, sans quoi
    /// il faudrait deux chemins de décodage pour la même requête.
    private static func entrees(base: OpaquePointer) -> LectureEntrees {
        var requete: OpaquePointer?
        guard sqlite3_prepare_v2(base, "SELECT key, value FROM \(table) WHERE key IN (?, ?)",
                                 -1, &requete, nil) == SQLITE_OK else { return .echec }
        defer { sqlite3_finalize(requete) }

        // Les pointeurs de `withCString` vivent jusqu'à la fin des fermetures, donc
        // au-delà des `step` : c'est ce qui autorise `SQLITE_STATIC` (destructeur nul).
        return cleJeton.withCString { pointeurJeton in
            cleCourriel.withCString { pointeurCourriel -> LectureEntrees in
                guard sqlite3_bind_text(requete, 1, pointeurJeton, -1, nil) == SQLITE_OK,
                      sqlite3_bind_text(requete, 2, pointeurCourriel, -1, nil) == SQLITE_OK
                else { return .echec }

                var jeton: String?
                var courriel: String?
                var etape = sqlite3_step(requete)
                while etape == SQLITE_ROW {
                    switch octets(requete, 0) {
                    case cleJeton: jeton = octets(requete, 1)
                    case cleCourriel: courriel = octets(requete, 1)
                    default: break
                    }
                    etape = sqlite3_step(requete)
                }
                guard etape == SQLITE_DONE else { return .echec }
                return .lues(jeton: jeton, courriel: courriel)
            }
        }
    }

    private static func octets(_ requete: OpaquePointer?, _ colonne: Int32) -> String? {
        guard let debut = sqlite3_column_blob(requete, colonne) else { return nil }
        let taille = Int(sqlite3_column_bytes(requete, colonne))
        guard taille > 0 else { return nil }
        return texte(Data(bytes: debut, count: taille))
    }

    /// L'éditeur peut écrire la valeur en UTF-16LE plutôt qu'en UTF-8. Lu en UTF-8, un
    /// jeton ASCII s'y retrouve entrelacé d'octets nuls, que rien ne retire : le JWT ne
    /// se découpe plus, et la ligne resterait « indéterminée » pour toujours.
    ///
    /// L'UTF-16LE n'est retenu que sur une preuve qu'un texte UTF-8 ne peut pas donner :
    /// la marque d'ordre `FF FE`, ou une suite de paires « octet ASCII non nul, octet
    /// nul » — un texte UTF-8 ne porte pas de nul. Tout le reste se lit en UTF-8 comme
    /// avant, octets invalides remplacés : une valeur présente mais illisible doit rester
    /// présente, pour se classer « empêchée » et non « absente ».
    static func texte(_ donnees: Data) -> String {
        let octets = [UInt8](donnees)
        if octets.count >= 2, octets[0] == 0xFF, octets[1] == 0xFE,
           let lu = String(bytes: octets.dropFirst(2), encoding: .utf16LittleEndian) {
            return lu
        }
        if !octets.isEmpty, octets.count.isMultiple(of: 2),
           stride(from: 0, to: octets.count, by: 2).allSatisfy({ (1...0x7F).contains(octets[$0]) && octets[$0 + 1] == 0 }),
           let lu = String(bytes: octets, encoding: .utf16LittleEndian) {
            return lu
        }
        return String(decoding: octets, as: UTF8.self)
    }

    // MARK: - Analyses pures

    /// Un jeton absent conclut — ce poste n'a pas de session Cursor ; un jeton présent
    /// mais indéchiffrable ne conclut rien, et le prendre pour une absence ferait
    /// disparaître en silence la seule mesure de ce fournisseur.
    static func classer(_ brut: String?, courrielSecours: String? = nil) -> LectureCursor {
        guard let valeur = brut?.trimmingCharacters(in: .whitespacesAndNewlines), !valeur.isEmpty else {
            return .absent
        }
        guard let revendications = revendications(valeur),
              let identifiant = identifiantUtilisateur(revendications.sujet) else {
            Journal.donnees.notice("Cursor : jeton de session présent mais inexploitable")
            return .empechee
        }
        return .jeton(JetonCursor(valeur: valeur,
                                  utilisateurIdentifiant: identifiant,
                                  courriel: revendications.courriel ?? nonVide(courrielSecours),
                                  expireA: revendications.expireA))
    }

    private struct ChargeJWT: Decodable {
        var sujet: String?
        var courriel: String?
        var expiration: Double?

        enum CodingKeys: String, CodingKey {
            case sujet = "sub"
            case courriel = "email"
            case expiration = "exp"
        }
    }

    static func revendications(_ jeton: String) -> RevendicationsCursor? {
        let segments = jeton.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let charge = base64url(String(segments[1])),
              let brut = try? JSONDecoder().decode(ChargeJWT.self, from: charge) else { return nil }
        return RevendicationsCursor(sujet: nonVide(brut.sujet),
                                    courriel: nonVide(brut.courriel),
                                    expireA: brut.expiration.flatMap(Horodatage.analyser(epoch:)))
    }

    /// Le `sub` vaut `auth0|user_XXX` et c'est `user_XXX` seul que le cookie attend.
    /// Les sous-chaînes vides sont conservées au découpage : sans cela un `sub` se
    /// terminant par une barre rendrait le préfixe, qui n'identifie personne.
    static func identifiantUtilisateur(_ sujet: String?) -> String? {
        guard let sujet else { return nil }
        let dernier = sujet.split(separator: "|", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        return nonVide(dernier)
    }

    /// Base64url, remplissage compris : un JWT s'écrit sans `=` final, et le nombre de
    /// caractères restants dit combien en rajouter. Un reste de 1 n'existe pas.
    static func base64url(_ texte: String) -> Data? {
        var normalise = texte
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let reste = normalise.count % 4
        guard reste != 1 else { return nil }
        if reste > 0 { normalise += String(repeating: "=", count: 4 - reste) }
        return Data(base64Encoded: normalise)
    }

    private static func nonVide(_ valeur: String?) -> String? {
        guard let coupe = valeur?.trimmingCharacters(in: .whitespacesAndNewlines), !coupe.isEmpty else {
            return nil
        }
        return coupe
    }
}

/// Ce qu'un relevé direct de Cursor établit. Pendant de `ReleveChatGPT`, et sous la
/// même réserve : il ne vaut que pour le compte dont la base détient le jeton.
struct ReleveCursor: Sendable, Equatable {
    var quota: Quota
    var mesureA: Date = .now
    var courriel: String?
    /// Identifiant tiré du `sub` du JWT. Clé d'appariement au même titre que
    /// l'identifiant d'organisation côté Anthropic.
    var utilisateurIdentifiant: String?
    var jetonExpireA: Date?
    /// La dépense à la demande du membre, puis celle de son équipe — voir `ArgentCursor`.
    var usagesPayants: [UsagePayant] = []
    var argentIllisible: Set<UsagePayant.Nature> = []
}

/// Ce que la lecture de la base puis l'appel à l'API ont pu établir. Même partition
/// que `ReleveCodex`.
enum ResultatCursor: Sendable, Equatable {
    case releve(ReleveCursor)
    /// Jeton présent mais refusé ou périmé. Ne dit rien du quota : le compte peut être
    /// plein, c'est l'accès qui manque, et il se retrouve par une reconnexion dans
    /// l'éditeur.
    case reconnexionNecessaire
    /// L'appel n'a rien établi — réseau coupé, statut inattendu, corps illisible.
    case indetermine
    /// Aucune session Cursor sur cette machine : rien à relever.
    case aucun
}

/// Relevé direct du quota Cursor. L'identité vient du jeton lui-même, qui est un JWT
/// et porte son propre `sub` et son `email` : contrairement à ChatGPT, aucun appel
/// supplémentaire n'est nécessaire pour savoir de quel compte la mesure parle.
enum QuotaCursor {
    static let hote = "https://cursor.com"
    static let chemin = "/api/usage-summary"

    /// L'app s'annonce sous son propre nom. Se faire passer pour l'éditeur officiel
    /// est une infraction d'une autre nature que de lire un jeton qu'on a le droit de lire.
    static let agent = "Quotum"

    static let nomDuCookie = "WorkosCursorSessionToken"
    /// `::` déjà encodé : le séparateur fait partie de la valeur du cookie, ce n'est
    /// pas un échappement que la couche HTTP appliquerait.
    static let separateurDuCookie = "%3A%3A"

    /// Ce qu'un appel a rapporté. Le refus de jeton se distingue de l'échec ordinaire
    /// parce qu'il se règle par une reconnexion, là où l'autre ne demande rien.
    enum ReponseAPI: Sendable, Equatable {
        case donnees(Data)
        case jetonRefuse
        case echec
    }

    static func relever(session: URLSession = Reseau.session,
                        delai: TimeInterval = 8,
                        maintenant: Date = .now) async -> ResultatCursor {
        switch await IdentifiantsCursor.jeton() {
        case .jeton(let jeton):
            return await relever(jeton: jeton, session: session, delai: delai, maintenant: maintenant)
        case .absent:
            return .aucun
        // Une lecture empêchée n'établit pas l'absence de session : la prendre pour
        // telle effacerait une mesure que rien n'a infirmée.
        case .empechee:
            return .indetermine
        }
    }

    static func relever(jeton: JetonCursor,
                        session: URLSession = Reseau.session,
                        delai: TimeInterval = 8,
                        maintenant: Date = .now) async -> ResultatCursor {
        // ⛔ Un `exp` dépassé se constate sans appel — et il ne se répare pas ici. Le
        // `cursorAuth/refreshToken` voisin permettrait l'échange, mais un jeton de
        // rafraîchissement tourne : le consommer invaliderait celui de l'éditeur, qui
        // déconnecterait son utilisateur. L'expiration est un état à afficher.
        if let expireA = jeton.expireA, expireA <= maintenant { return .reconnexionNecessaire }

        let reponse = await charger(jeton: jeton, session: session, delai: delai)
        let mesureA = Date()

        switch reponse {
        case .jetonRefuse:
            return .reconnexionNecessaire
        case .echec:
            return .indetermine
        case .donnees(let donnees):
            // Le forfait et l'argent se lisent l'un sans l'autre : un plan muet n'efface pas
            // une dépense établie. Sans forfait, le relevé n'a aucune fenêtre — jamais une
            // fenêtre inventée pour accompagner l'argent.
            let quota = decoderUsage(donnees)
            let argent = decoderArgent(donnees, mesureA: mesureA)
            guard quota != nil || !argent.usages.isEmpty else { return .indetermine }
            return .releve(ReleveCursor(quota: quota ?? Quota([]),
                                        mesureA: mesureA,
                                        courriel: jeton.courriel,
                                        utilisateurIdentifiant: jeton.utilisateurIdentifiant,
                                        jetonExpireA: jeton.expireA,
                                        usagesPayants: argent.usages,
                                        argentIllisible: argent.illisible))
        }
    }

    static func requete(jeton: JetonCursor, delai: TimeInterval) -> URLRequest? {
        guard let url = URL(string: hote + chemin),
              let cookie = valeurDuCookie(jeton: jeton) else { return nil }
        var requete = URLRequest(url: url)
        requete.httpMethod = "GET"
        requete.timeoutInterval = delai
        // Le secret voyage ici dans un cookie. Il se pose sur la requête, jamais sur la
        // configuration de session — que CFNetwork rejoue vers l'hôte cible d'une
        // redirection — et le magasin de cookies est écarté pour qu'il ne soit ni
        // conservé, ni substitué, ni rejoué par le système.
        requete.httpShouldHandleCookies = false
        requete.setValue(cookie, forHTTPHeaderField: "Cookie")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue(agent, forHTTPHeaderField: "User-Agent")
        return requete
    }

    /// `nil` dès qu'une des deux moitiés ne peut pas voyager telle quelle : un jeton
    /// porteur d'un retour à la ligne ou d'un point-virgule injecterait un second
    /// en-tête. On préfère ne pas appeler plutôt que d'assainir un secret.
    static func valeurDuCookie(jeton: JetonCursor) -> String? {
        guard transportable(jeton.utilisateurIdentifiant), transportable(jeton.valeur) else { return nil }
        return "\(nomDuCookie)=\(jeton.utilisateurIdentifiant)\(separateurDuCookie)\(jeton.valeur)"
    }

    private static let caracteresInterdits = CharacterSet(charactersIn: ";,\"\\")
        .union(.whitespacesAndNewlines)
        .union(.controlCharacters)

    static func transportable(_ valeur: String) -> Bool {
        !valeur.isEmpty && valeur.unicodeScalars.allSatisfy { $0.isASCII && !caracteresInterdits.contains($0) }
    }

    private static func charger(jeton: JetonCursor,
                                session: URLSession,
                                delai: TimeInterval) async -> ReponseAPI {
        guard let requete = requete(jeton: jeton, delai: delai) else { return .echec }

        do {
            let (donnees, reponse) = try await session.data(for: requete,
                                                              delegate: RedirectionCursorSeulement())
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            journaliser(code: code)
            return interpreter(code: code, donnees: donnees)
        } catch {
            Journal.donnees.debug("Quota Cursor : cursor.com injoignable")
            return .echec
        }
    }

    /// Le jeton se renouvelle par une reconnexion dans l'éditeur, jamais en
    /// réessayant. Cette route refuse une session invalide en 401 **ou** en 403 : un
    /// client tiers en service les traite tous deux en « non connecté », et réserve le
    /// 403 « permission » à la route de coût, que Quotum n'appelle pas.
    /// ⚠️ `/api/auth/me` rend un 204 quand la session manque, mais rien ne l'a été
    /// observé sur cette route-ci : en tirer un refus affirmerait plus que ce qu'on sait,
    /// et « rien établi » reste la réponse honnête.
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
            Journal.donnees.notice("Quota Cursor : jeton refusé (\(code)), reconnexion à faire dans l'éditeur")
        default:
            Journal.donnees.notice("Quota Cursor : statut HTTP \(code)")
        }
    }

    // MARK: - Analyses pures

    /// Un pourcentage tel que la réponse l'écrit. Présent mais illisible n'est ni zéro ni
    /// absence : il ne fait pas de fenêtre, et ne laisse pas le total parler à sa place.
    private enum Pourcentage: Equatable {
        case absent
        case valeur(Double)
        case illisible

        static func lire<Cle: CodingKey>(_ conteneur: KeyedDecodingContainer<Cle>?, _ cle: Cle) -> Pourcentage {
            guard let conteneur, conteneur.contains(cle), (try? conteneur.decodeNil(forKey: cle)) != true else {
                return .absent
            }
            guard let nombre = try? conteneur.decode(Double.self, forKey: cle), nombre.isFinite else {
                return .illisible
            }
            return .valeur(nombre)
        }
    }

    /// Les pourcentages, en unités de pour cent même sous 1,0. `auto` est la réserve
    /// « Cursor Models », `api` la réserve « Other Models » ; `total` en est une moyenne
    /// pondérée, jamais le maximum. Lus champ par champ : un total illisible ne fait pas
    /// tomber deux réserves valides.
    private struct Reserves {
        var total: Pourcentage
        var auto: Pourcentage
        var api: Pourcentage

        enum Cles: String, CodingKey {
            case total = "totalPercentUsed"
            case auto = "autoPercentUsed"
            case api = "apiPercentUsed"
        }

        init(_ conteneur: KeyedDecodingContainer<Cles>?) {
            total = Pourcentage.lire(conteneur, .total)
            auto = Pourcentage.lire(conteneur, .auto)
            api = Pourcentage.lire(conteneur, .api)
        }

        var publieQuelqueChose: Bool { [total, auto, api].contains { $0 != .absent } }
    }

    static var libelleModelesCursor: String { Mots.dit("Modèles Cursor") }
    static var libelleAutresModeles: String { Mots.dit("Autres modèles") }

    private struct ReponseUsage: Decodable {
        var reserves: Reserves
        var finDeCycle: Date?

        private enum Cles: String, CodingKey {
            case individualUsage
            case plan
            case finDeCycle = "billingCycleEnd"
        }

        init(from decodeur: Decoder) throws {
            let conteneur = try decodeur.container(keyedBy: Cles.self)
            finDeCycle = (try? conteneur.decode(Horodatage.self, forKey: .finDeCycle))?.date
            let individuel = try? conteneur.nestedContainer(keyedBy: Cles.self, forKey: .individualUsage)
            let plan = Reserves(try? individuel?.nestedContainer(keyedBy: Reserves.Cles.self, forKey: .plan))
            reserves = plan.publieQuelqueChose
                ? plan
                : Reserves(try? decodeur.container(keyedBy: Reserves.Cles.self))
        }
    }

    /// Les réponses observées rangent les pourcentages sous `individualUsage.plan`, la
    /// racine ne portant que les bornes du cycle — sources : ClaudeBar #303 (compte Pro+,
    /// 21/09/2026) et le gist dmwyatt, deux relevés publics qui concordent.
    /// La racine n'est lue que si le plan ne publie rien : les deux ne se
    /// mélangent jamais.
    ///
    /// ⚠️ Deux réserves mensuelles, Cursor Models et Other Models, s'épuisent séparément
    /// à la même échéance (documentation de Cursor, même section) : une ligne chacune,
    /// sans quoi Other Models à sec ferait lire Cursor à sec alors qu'Auto sert encore.
    /// Le total pondéré n'est qu'un repli quand aucune réserve n'est publiée — il peut
    /// dire 45 % quand Other Models est à 97 %. Une réserve absente ou non finie ne fait
    /// aucune fenêtre, et rien n'est déduit du total.
    ///
    /// ⚠️ Aucune durée n'est publiée, seulement les bornes du cycle. `duree` reste donc
    /// nulle : la déduire de `billingCycleEnd − billingCycleStart` fabriquerait une
    /// mesure que le fournisseur n'a pas rendue.
    static func decoderUsage(_ donnees: Data) -> Quota? {
        guard let reponse = try? JSONDecoder().decode(ReponseUsage.self, from: donnees) else { return nil }
        let reserves = reponse.reserves
        let mois = { (lu: Pourcentage, reserve: String?) -> Fenetre? in
            guard case .valeur(let utilisation) = lu else { return nil }
            return Fenetre(libelle: Fenetre.libelleMois,
                           sorte: .mois,
                           utilisation: utilisation,
                           seRechargeA: reponse.finDeCycle,
                           duree: nil,
                           reserve: reserve)
        }

        let fenetres: [Fenetre]
        if reserves.auto != .absent || reserves.api != .absent {
            // Une réserve publiée mais illisible : la moitié du forfait est inconnue, et
            // montrer l'autre seule laisserait lire le compte entier à travers elle.
            guard reserves.auto != .illisible, reserves.api != .illisible else { return nil }
            fenetres = [mois(reserves.auto, libelleModelesCursor),
                        mois(reserves.api, libelleAutresModeles)].compactMap { $0 }
        } else {
            fenetres = [mois(reserves.total, nil)].compactMap { $0 }
        }
        return fenetres.isEmpty ? nil : Quota(fenetres)
    }

    // MARK: - Dépense à la demande

    /// Le cent de dollar US : la réponse ne nomme pas son unité, Cursor facture en dollars et
    /// publie ses montants en entiers de cents (`used: 91272` pour 912,72 $).
    static let devise = Montant.Unite.devise("USD")
    static let exposant = 2

    /// Ce qu'une réponse dit de l'argent, hors des fenêtres.
    struct ArgentCursor: Sendable, Equatable {
        var usages: [UsagePayant] = []
        /// Un mécanisme publié qu'on ne sait pas lire : ni zéro, ni absence — la mesure gardée
        /// de cette nature reste, voir `UsagesConserves`.
        var illisible: Set<UsagePayant.Nature> = []
    }

    /// Un montant tel que la réponse l'écrit. ⚠️ `null` n'est pas zéro ni « illimité » :
    /// c'est un plafond **non publié**, et un montant d'une autre forme n'est pas une absence.
    private enum Cents: Equatable {
        case absent
        case nul
        case valeur(Int64)
        case illisible

        static func lire<Cle: CodingKey>(_ conteneur: KeyedDecodingContainer<Cle>, _ cle: Cle) -> Cents {
            guard conteneur.contains(cle) else { return .absent }
            if (try? conteneur.decodeNil(forKey: cle)) == true { return .nul }
            // Un entier écrit `91272.0` reste un entier ; un demi-cent, non. ⛔ Ni `Double` ni
            // `Int64` d'abord : au-delà de 2⁵³, le décodeur entier passe lui aussi par un
            // flottant (mesuré), et `9007199254740992.5` y devenait un entier de cents.
            if let nombre = try? conteneur.decode(Decimal.self, forKey: cle), let entier = entierExact(nombre) {
                return .valeur(entier)
            }
            return .illisible
        }

        /// L'entier positif que le décimal écrit exactement, ou rien.
        static func entierExact(_ nombre: Decimal) -> Int64? {
            guard nombre.isFinite, nombre >= 0, nombre <= Decimal(Int64.max) else { return nil }
            var source = nombre
            var arrondi = Decimal()
            NSDecimalRound(&arrondi, &source, 0, .plain)
            guard arrondi == nombre else { return nil }
            return Int64(NSDecimalNumber(decimal: arrondi).stringValue)
        }

        var montant: Montant? {
            guard case .valeur(let cents) = self else { return nil }
            return Montant(unitesMineures: cents, unite: QuotaCursor.devise, exposant: QuotaCursor.exposant)
        }
    }

    /// `{enabled, used, limit, remaining}`, lu champ par champ : un champ d'une forme inattendue
    /// ne fait pas tomber les autres. `remaining` n'est pas lu — il se déduit des deux autres,
    /// et le croire contre eux ne trancherait rien.
    private struct ALaDemande: Decodable, Equatable {
        var actif: Bool?
        var consomme: Cents
        var plafond: Cents

        private enum Cles: String, CodingKey {
            case actif = "enabled"
            case consomme = "used"
            case plafond = "limit"
        }

        init(from decodeur: Decoder) throws {
            let conteneur = try decodeur.container(keyedBy: Cles.self)
            actif = try? conteneur.decode(Bool.self, forKey: .actif)
            consomme = Cents.lire(conteneur, .consomme)
            plafond = Cents.lire(conteneur, .plafond)
        }
    }

    /// `individualUsage` ou `teamUsage` : seul `onDemand` y est lu ici.
    private struct Porteur: Decodable {
        enum Lu: Equatable {
            case absent
            case lu(ALaDemande)
            case illisible
        }

        var aLaDemande: Lu

        private enum Cles: String, CodingKey { case onDemand }

        init(aLaDemande: Lu) { self.aLaDemande = aLaDemande }

        init(from decodeur: Decoder) throws {
            // Un porteur qui n'est pas un objet a été publié sous une forme qu'on ne sait pas
            // lire : sa dépense est inconnue, pas absente.
            guard let conteneur = try? decodeur.container(keyedBy: Cles.self) else {
                aLaDemande = .illisible
                return
            }
            guard conteneur.contains(.onDemand), (try? conteneur.decodeNil(forKey: .onDemand)) != true else {
                aLaDemande = .absent
                return
            }
            guard let lu = try? conteneur.decode(ALaDemande.self, forKey: .onDemand) else {
                aLaDemande = .illisible
                return
            }
            aLaDemande = .lu(lu)
        }
    }

    private struct ReponseArgent: Decodable {
        var individuel: Porteur?
        var equipe: Porteur?
        var finDeCycle: Date?

        private enum Cles: String, CodingKey {
            case individuel = "individualUsage"
            case equipe = "teamUsage"
            case finDeCycle = "billingCycleEnd"
        }

        init(from decodeur: Decoder) throws {
            let conteneur = try decodeur.container(keyedBy: Cles.self)
            individuel = Self.porteur(conteneur, .individuel)
            equipe = Self.porteur(conteneur, .equipe)
            finDeCycle = (try? conteneur.decode(Horodatage.self, forKey: .finDeCycle))?.date
        }

        /// Absent ou `null` : rien de publié. Présent sous une autre forme : illisible.
        private static func porteur(_ conteneur: KeyedDecodingContainer<Cles>, _ cle: Cles) -> Porteur? {
            guard conteneur.contains(cle), (try? conteneur.decodeNil(forKey: cle)) != true else { return nil }
            return (try? conteneur.decode(Porteur.self, forKey: cle)) ?? Porteur(aLaDemande: .illisible)
        }
    }

    /// La dépense à la demande du membre (`individualUsage.onDemand` → `.depense`) et celle de
    /// son équipe (`teamUsage.onDemand` → `.depenseEquipe`), en cents, jusqu'à la fin du cycle.
    ///
    /// ⛔ Les deux ne se confondent jamais : le plafond d'équipe coupe tout le monde, mais sa
    /// dépense est celle de tous les membres — la prendre pour celle du membre lui prêterait
    /// l'argent des autres. Et rien d'autre de l'équipe n'est lu : ni la dépense par membre,
    /// ni une autre route.
    ///
    /// ⛔ `limit: null` ne se lit pas « illimité » : c'est un plafond que la réponse ne publie
    /// pas — « No Limit » chez Cursor, ou un mécanisme éteint (`enabled: false`), ou un plafond
    /// tenu ailleurs. `illimite` reste donc `nil`, et `enabled: false` se dit éteint.
    static func decoderArgent(_ donnees: Data, mesureA: Date) -> ArgentCursor {
        guard let reponse = try? JSONDecoder().decode(ReponseArgent.self, from: donnees) else { return ArgentCursor() }
        var argent = ArgentCursor()
        let porteurs: [(Porteur?, UsagePayant.Nature)] = [(reponse.individuel, .depense),
                                                          (reponse.equipe, .depenseEquipe)]
        for (porteur, nature) in porteurs {
            switch porteur?.aLaDemande ?? .absent {
            case .absent:
                continue
            case .illisible:
                argent.illisible.insert(nature)
            case .lu(let lu):
                // Un consommé perdu devant un plafond se lirait « rien dépensé » ; un plafond
                // perdu laisserait lire la dépense comme sans limite.
                guard lu.consomme != .illisible, lu.plafond != .illisible else {
                    argent.illisible.insert(nature)
                    continue
                }
                if let usage = UsagePayant(nature: nature,
                                           unite: devise,
                                           consomme: lu.consomme.montant,
                                           plafond: lu.plafond.montant,
                                           solde: nil,
                                           utilisation: nil,
                                           illimite: nil,
                                           actif: lu.actif,
                                           bloque: false,
                                           motif: nil,
                                           echeance: reponse.finDeCycle,
                                           mesureA: mesureA) {
                    argent.usages.append(usage)
                }
            }
        }
        return argent
    }
}

/// ⛔ Le secret de Cursor voyage dans un **cookie**, pas dans `Authorization`. La mesure
/// du 2026-09-17 sur CFNetwork ne couvre que l'en-tête d'autorisation : rien ne dit
/// qu'un cookie posé par requête ne serait pas rejoué vers la cible d'une redirection.
/// Faute de l'avoir mesuré, on ne suit aucune redirection qui quitte l'hôte du produit.
final class RedirectionCursorSeulement: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              url.user(percentEncoded: true) == nil,
              url.password(percentEncoded: true) == nil,
              url.host(percentEncoded: true)?.lowercased() == "cursor.com"
        else { return nil }
        return request
    }
}
