import Foundation

/// Ce qu'un relevé de GitHub Copilot établit : la dotation mensuelle de requêtes premium,
/// et ce qui a été consommé au-delà quand le dépassement payant est ouvert.
struct MesureCopilot: Sendable, Equatable {
    var quota: Quota
    var mesureA: Date = .now
    /// Le `login` que la réponse nomme, à défaut celui que `gh` déclare actif. L'identité
    /// qui revient l'emporte : c'est elle qui dit de quel compte parle la mesure.
    var login: String?
    /// Les crédits consommés au-delà de la dotation. ⛔ Jamais une `Fenetre` : un compte qui
    /// paie son dépassement n'est pas un compte qui s'épuise.
    var depassement: UsagePayant?
    var argentIllisible: Set<UsagePayant.Nature> = []
}

/// Même partition que `ReleveGrok` : un jeton refusé ne dit rien du quota, et une réponse
/// inattendue encore moins.
enum ReleveCopilot: Sendable, Equatable {
    case releve(MesureCopilot)
    /// HTTP 401 : la connexion de `gh` ne vaut plus, elle se refait par `gh auth login`.
    case reconnexionNecessaire
    /// Réseau coupé, statut inattendu — dont le 404 d'une route non documentée qui peut
    /// disparaître comme d'un compte sans Copilot, sans qu'on sache lequel —, corps illisible.
    case indetermine
    /// `gh` n'est connecté à github.com sur aucun compte de ce Mac.
    case aucun
}

/// Le jeton OAuth que `gh auth login` a obtenu. Il sert à un appel et n'est ni copié sur
/// disque, ni journalisé, ni conservé au-delà du relevé.
struct JetonCopilot: Sendable, Equatable {
    let valeur: String
    /// Le compte que `hosts.yml` déclare actif, quand il le déclare.
    let utilisateur: String?
}

enum LectureCopilot: Sendable, Equatable {
    case jeton(JetonCopilot)
    /// Aucune connexion de `gh` à github.com : ni hôte déclaré, ni élément au Trousseau.
    case absent
    /// Lecture empêchée — droits refusés, Trousseau verrouillé, contenu inexploitable.
    case empechee
}

/// La connexion de la CLI `gh`, lue là où `gh` la range, sans jamais exécuter `gh`.
///
/// ⛔ **Lecture seule.** Un jeton de `gh` n'expire pas et ne se rafraîchit pas : Quotum
/// n'écrit rien, ne renouvelle rien, et ne demande jamais de connexion.
///
/// Deux rangements, dans l'ordre où `gh` les consulte pour github.com hors variables
/// d'environnement : le jeton écrit en clair dans `hosts.yml` (connexion faite avec
/// `--insecure-storage`), sinon l'élément « gh:github.com » du Trousseau, au compte vide —
/// celui que `gh` réécrit à chaque `gh auth switch`, donc toujours le compte actif.
///
/// ⚠️ `GH_TOKEN` et `GITHUB_TOKEN` ne sont pas lus : une app lancée par le Finder ne les
/// hérite pas d'un profil de shell, et un jeton personnel n'ouvre pas forcément cette route.
enum IdentifiantsCopilot {
    static let hote = "github.com"
    /// `gh` le compose en « gh:<hôte> » ; l'élément ne porte que le jeton.
    static let serviceTrousseau = "gh:github.com"
    /// Le compte vide, celui du compte actif. Les éléments nommés d'après chaque
    /// utilisateur ne sont pas lus : `gh` lui-même ne s'en sert pas pour s'authentifier.
    static let compteActif = ""

    static let variableDossier = "GH_CONFIG_DIR"
    static let variableXDG = "XDG_CONFIG_HOME"

    /// Le même ordre que `gh` : `GH_CONFIG_DIR`, puis `XDG_CONFIG_HOME/gh`, puis `~/.config/gh`.
    static func fichierHotes(environnement: [String: String], accueil: URL) -> URL {
        if let dossier = nonVide(environnement[variableDossier]) {
            return URL(fileURLWithPath: (dossier as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("hosts.yml")
        }
        if let xdg = nonVide(environnement[variableXDG]) {
            return URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("gh/hosts.yml")
        }
        return accueil.appendingPathComponent(".config/gh/hosts.yml")
    }

    /// ⛔ Aucun paramètre n'a de valeur par défaut : un test qui en oublierait un ne doit
    /// pas compiler, plutôt que lire le vrai `hosts.yml` ou le vrai Trousseau.
    static func jeton(fichier: URL,
                      lireFichier: @escaping @Sendable (URL) throws(LectureFichier.Echec) -> Data,
                      lanceur: @escaping LanceurProcessus) async -> LectureCopilot {
        let lecture = await HorsFil.executer { () -> Result<Data, LectureFichier.Echec> in
            do throws(LectureFichier.Echec) { return .success(try lireFichier(fichier)) } catch { return .failure(error) }
        }
        let donnees: Data
        switch lecture {
        case .success(let lues):
            donnees = lues
        case .failure(.absent):
            // Sans hosts.yml, `gh` se dit déconnecté : le Trousseau n'est même pas interrogé.
            return .absent
        case .failure(let echec):
            Journal.donnees.notice("GitHub Copilot : hosts.yml illisible (\(String(describing: echec)))")
            return .empechee
        }
        guard let texte = String(data: donnees, encoding: .utf8) else { return .empechee }
        guard let entree = analyserHotes(texte) else { return .absent }
        if let enClair = entree.jetonEnClair {
            return .jeton(JetonCopilot(valeur: enClair, utilisateur: entree.utilisateur))
        }
        let brute = await Trousseau.executerLecture(service: serviceTrousseau,
                                                    comptes: [compteActif],
                                                    sujet: "GitHub Copilot",
                                                    lanceur: lanceur)
        return conclure(brute, utilisateur: entree.utilisateur)
    }

    /// Une tentative interrompue ne conclut rien ; le code 44 seul établit l'absence.
    static func conclure(_ brute: LectureBrute, utilisateur: String?) -> LectureCopilot {
        guard !brute.interrompue, let resultat = brute.resultats.first else { return .empechee }
        guard resultat.reussi else {
            if resultat.code == Trousseau.codeAbsent { return .absent }
            // Le code, jamais la sortie : c'est elle qui porte le secret.
            Journal.donnees.notice("GitHub Copilot : lecture du Trousseau refusée (code \(resultat.code))")
            return .empechee
        }
        guard let valeur = decoderTrousseau(resultat.sortie) else {
            Journal.donnees.notice("GitHub Copilot : élément du Trousseau lu mais inexploitable")
            return .empechee
        }
        return .jeton(JetonCopilot(valeur: valeur, utilisateur: utilisateur))
    }

    /// `gh` range son jeton par la bibliothèque go-keyring, qui préfixe une valeur encodée :
    /// « go-keyring-base64: » suivi du base64, ou « go-keyring-encoded: » suivi de
    /// l'hexadécimal dans ses versions plus anciennes. Une valeur sans préfixe est le jeton nu.
    static func decoderTrousseau(_ sortie: String) -> String? {
        let brut = sortie.trimmingCharacters(in: .whitespacesAndNewlines)
        let decode: String?
        if brut.hasPrefix(prefixeBase64) {
            decode = Data(base64Encoded: String(brut.dropFirst(prefixeBase64.count)))
                .flatMap { String(data: $0, encoding: .utf8) }
        } else if brut.hasPrefix(prefixeHexadecimal) {
            decode = hexadecimal(String(brut.dropFirst(prefixeHexadecimal.count)))
                .flatMap { String(data: $0, encoding: .utf8) }
        } else {
            decode = brut
        }
        return jetonValable(decode)
    }

    static let prefixeBase64 = "go-keyring-base64:"
    static let prefixeHexadecimal = "go-keyring-encoded:"

    private static func hexadecimal(_ texte: String) -> Data? {
        let octets = Array(texte.utf8)
        guard !octets.isEmpty, octets.count.isMultiple(of: 2) else { return nil }
        var donnees = Data(capacity: octets.count / 2)
        var index = 0
        while index < octets.count {
            guard let haut = chiffreHexa(octets[index]), let bas = chiffreHexa(octets[index + 1]) else { return nil }
            donnees.append(haut << 4 | bas)
            index += 2
        }
        return donnees
    }

    private static func chiffreHexa(_ octet: UInt8) -> UInt8? {
        switch octet {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): octet - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): octet - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): octet - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    /// Un jeton part dans un en-tête : un blanc ou un caractère de contrôle y casserait la
    /// requête, ou y glisserait une ligne de plus.
    private static func jetonValable(_ valeur: String?) -> String? {
        guard let valeur = nonVide(valeur),
              valeur.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else { return nil }
        return valeur
    }

    // MARK: - hosts.yml

    struct EntreeHote: Sendable, Equatable {
        var utilisateur: String?
        var jetonEnClair: String?
    }

    /// Le sous-ensemble de YAML que `gh` écrit pour ses hôtes : des clés par indentation,
    /// des valeurs scalaires sur la même ligne. Seul le bloc `github.com:` est lu, et dans
    /// lui `user`, `oauth_token`, et `users.<compte actif>.oauth_token` — l'emplacement du
    /// jeton en clair depuis le multi-comptes. `nil` : github.com n'est pas déclaré.
    static func analyserHotes(_ texte: String) -> EntreeHote? {
        let lignes = texte.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .compactMap(LigneYAML.init)
        guard let debut = lignes.firstIndex(where: { $0.retrait == 0 && $0.cle == hote }) else { return nil }
        let bloc = lignes[(debut + 1)...].prefix { $0.retrait > 0 }
        guard let retraitEnfant = bloc.first?.retrait else { return EntreeHote() }

        var entree = EntreeHote()
        var jetonsParUtilisateur: [String: String] = [:]
        var dansUsers = false
        var utilisateurCourant: String?
        var retraitUtilisateur: Int?
        for ligne in bloc {
            if ligne.retrait == retraitEnfant {
                dansUsers = ligne.cle == "users"
                utilisateurCourant = nil
                retraitUtilisateur = nil
                switch ligne.cle {
                case "user": entree.utilisateur = nonVide(ligne.valeur)
                case "oauth_token": entree.jetonEnClair = jetonValable(ligne.valeur)
                default: break
                }
            } else if dansUsers, ligne.retrait > retraitEnfant {
                if retraitUtilisateur == nil { retraitUtilisateur = ligne.retrait }
                if ligne.retrait == retraitUtilisateur {
                    utilisateurCourant = ligne.cle
                } else if let utilisateur = utilisateurCourant, ligne.cle == "oauth_token",
                          let jeton = jetonValable(ligne.valeur) {
                    jetonsParUtilisateur[utilisateur] = jeton
                }
            }
        }
        if entree.jetonEnClair == nil, let actif = entree.utilisateur {
            entree.jetonEnClair = jetonsParUtilisateur[actif]
        }
        return entree
    }

    private struct LigneYAML {
        let retrait: Int
        let cle: String
        let valeur: String?

        init?(_ brute: Substring) {
            let retrait = brute.prefix { $0 == " " }.count
            var contenu = brute.dropFirst(retrait)
            if contenu.hasPrefix("#") || contenu.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            // Un dièse précédé d'un blanc ouvre un commentaire ; un jeton n'en contient pas.
            if let commentaire = contenu.range(of: " #") { contenu = contenu[..<commentaire.lowerBound] }
            guard let deuxPoints = contenu.firstIndex(of: ":") else { return nil }
            let cle = LigneYAML.sansGuillemets(contenu[..<deuxPoints].trimmingCharacters(in: .whitespaces))
            let reste = contenu[contenu.index(after: deuxPoints)...].trimmingCharacters(in: .whitespaces)
            guard !cle.isEmpty else { return nil }
            self.retrait = retrait
            self.cle = cle
            self.valeur = reste.isEmpty ? nil : LigneYAML.sansGuillemets(reste)
        }

        private static func sansGuillemets(_ texte: String) -> String {
            for guillemet in ["\"", "'"] where texte.count >= 2 && texte.hasPrefix(guillemet) && texte.hasSuffix(guillemet) {
                return String(texte.dropFirst().dropLast())
            }
            return texte
        }
    }

    private static func nonVide(_ valeur: String?) -> String? {
        guard let coupe = valeur?.trimmingCharacters(in: .whitespacesAndNewlines), !coupe.isEmpty else {
            return nil
        }
        return coupe
    }
}

/// Relevé de la dotation de requêtes premium de GitHub Copilot.
///
/// ⚠️ La route n'est **pas documentée** par GitHub : sa forme est celle de réponses
/// rapportées par des tiers, et elle peut changer ou disparaître sans préavis.
enum QuotaCopilot {
    static let adresse = "https://api.github.com/copilot_internal/user"

    /// L'app s'annonce sous son propre nom, jamais sous celui d'un éditeur ou d'un client
    /// officiel de Copilot.
    static let agent = "Quotum"

    enum ReponseAPI: Sendable, Equatable {
        case donnees(Data)
        case jetonRefuse
        case echec
    }

    static func relever() async -> ReleveCopilot {
        let fichier = IdentifiantsCopilot.fichierHotes(environnement: ProcessInfo.processInfo.environment,
                                                       accueil: FileManager.default.homeDirectoryForCurrentUser)
        let lecture = await IdentifiantsCopilot.jeton(fichier: fichier,
                                                      lireFichier: { url throws(LectureFichier.Echec) in
                                                          try LectureFichier.lire(url)
                                                      },
                                                      lanceur: Trousseau.lanceurSysteme)
        return await relever(lecture: lecture, session: Reseau.session, delai: 8)
    }

    static func relever(lecture: LectureCopilot,
                        session: URLSession,
                        delai: TimeInterval) async -> ReleveCopilot {
        switch lecture {
        case .jeton(let jeton):
            return await relever(jeton: jeton, session: session, delai: delai)
        case .absent:
            return .aucun
        // Une lecture empêchée n'établit pas l'absence de connexion.
        case .empechee:
            return .indetermine
        }
    }

    static func relever(jeton: JetonCopilot,
                        session: URLSession,
                        delai: TimeInterval) async -> ReleveCopilot {
        let reponse = await charger(jeton: jeton, session: session, delai: delai)
        switch reponse {
        case .jetonRefuse:
            return .reconnexionNecessaire
        case .echec:
            return .indetermine
        case .donnees(let donnees):
            guard var mesure = decoder(donnees, mesureA: Date()) else { return .indetermine }
            if mesure.login == nil { mesure.login = jeton.utilisateur }
            return .releve(mesure)
        }
    }

    /// ⚠️ L'`Authorization` se pose **sur la requête**, jamais dans la configuration de
    /// session : CFNetwork rejoue celle-ci sur la cible d'une redirection, autre hôte compris.
    static func requete(jeton: JetonCopilot, delai: TimeInterval) -> URLRequest? {
        guard let url = URL(string: adresse) else { return nil }
        var requete = URLRequest(url: url)
        requete.httpMethod = "GET"
        requete.timeoutInterval = delai
        requete.setValue("token \(jeton.valeur)", forHTTPHeaderField: "Authorization")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue(agent, forHTTPHeaderField: "User-Agent")
        return requete
    }

    private static func charger(jeton: JetonCopilot, session: URLSession, delai: TimeInterval) async -> ReponseAPI {
        guard let requete = requete(jeton: jeton, delai: delai) else { return .echec }
        do {
            let (donnees, reponse) = try await session.data(for: requete,
                                                            delegate: RedirectionMemeHoteSeulement(hote: "api.github.com"))
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            switch code {
            case 200: break
            case 401: Journal.donnees.notice("Quota GitHub Copilot : jeton refusé (401), reconnexion à refaire")
            case 404: Journal.donnees.notice("Quota GitHub Copilot : route introuvable ou compte sans Copilot (404)")
            default: Journal.donnees.notice("Quota GitHub Copilot : statut HTTP \(code)")
            }
            return interpreter(code: code, donnees: donnees)
        } catch {
            Journal.donnees.debug("Quota GitHub Copilot : api.github.com injoignable")
            return .echec
        }
    }

    /// Seul le 401 dit quelque chose qu'on puisse faire. ⛔ Le 404 reste un échec ordinaire :
    /// sur une route non documentée, il ne distingue pas un compte sans Copilot d'une route
    /// retirée, et annoncer l'un ou l'autre affirmerait ce qu'on n'a pas constaté.
    static func interpreter(code: Int, donnees: Data) -> ReponseAPI {
        switch code {
        case 200: .donnees(donnees)
        case 401: .jetonRefuse
        default: .echec
        }
    }

    // MARK: - Analyses pures

    /// Un nombre JSON lu deux fois : en flottant pour la jauge, en décimal pour les crédits,
    /// qui ne passent jamais par un flottant. Une chaîne, un booléen, `null` ne font rien.
    struct Nombre: Decodable, Sendable, Equatable {
        let flottant: Double?
        let decimal: Decimal?

        init(from decodeur: Decoder) throws {
            let conteneur = try decodeur.singleValueContainer()
            let flottant = try? conteneur.decode(Double.self)
            self.flottant = flottant.flatMap { $0.isFinite ? $0 : nil }
            self.decimal = self.flottant == nil ? nil : (try? conteneur.decode(Decimal.self))
        }
    }

    private struct Reponse: Decodable {
        var login: String?
        var echeance: String?
        var echeanceUTC: String?
        var instantanes: Instantanes?

        init(from decodeur: Decoder) throws {
            let conteneur = try decodeur.container(keyedBy: Cles.self)
            login = try? conteneur.decode(String.self, forKey: .login)
            echeance = try? conteneur.decode(String.self, forKey: .echeance)
            echeanceUTC = try? conteneur.decode(String.self, forKey: .echeanceUTC)
            instantanes = try? conteneur.decode(Instantanes.self, forKey: .instantanes)
        }

        enum Cles: String, CodingKey {
            case login
            case echeance = "quota_reset_date"
            case echeanceUTC = "quota_reset_date_utc"
            case instantanes = "quota_snapshots"
        }
    }

    /// ⛔ Seule la réserve `premium_interactions` est lue. `chat` et `completions` sont
    /// illimitées sur les formules payantes, et les afficher ferait trois jauges dont deux
    /// ne disent rien.
    private struct Instantanes: Decodable {
        var premium: Instantane?

        enum CodingKeys: String, CodingKey {
            case premium = "premium_interactions"
        }

        init(from decodeur: Decoder) throws {
            let conteneur = try decodeur.container(keyedBy: CodingKeys.self)
            premium = try? conteneur.decode(Instantane.self, forKey: .premium)
        }
    }

    /// Chaque champ est lu à part : un champ d'un autre type ne fait pas tomber les autres.
    ///
    /// ⚠️ Le restant est publié sous deux noms selon les tiers qui ont décrit la route :
    /// `remaining` (CodexBar, sur toutes ses captures) et `quota_remaining` (opencode-quota,
    /// Jarvis). Aucun n'est observé ici ; le premier lisible des deux, dans cet ordre, fait foi.
    private struct Instantane: Decodable {
        var dotation: Nombre?
        var creditsUtilises: Nombre?
        var restant: Nombre?
        var restantPublie = false
        var pourcentageRestant: Nombre?
        var depassements: Nombre?
        var depassementPermis: Bool?
        var illimite: Bool?

        init(from decodeur: Decoder) throws {
            let conteneur = try decodeur.container(keyedBy: Cles.self)
            dotation = Self.nombre(conteneur, .dotation)
            creditsUtilises = Self.nombre(conteneur, .creditsUtilises)
            restant = Self.nombre(conteneur, .restant) ?? Self.nombre(conteneur, .restantAncien)
            restantPublie = Self.publie(conteneur, .restant) || Self.publie(conteneur, .restantAncien)
            pourcentageRestant = Self.nombre(conteneur, .pourcentageRestant)
            depassements = Self.nombre(conteneur, .depassements)
            depassementPermis = try? conteneur.decode(Bool.self, forKey: .depassementPermis)
            illimite = try? conteneur.decode(Bool.self, forKey: .illimite)
        }

        private static func nombre(_ conteneur: KeyedDecodingContainer<Cles>, _ cle: Cles) -> Nombre? {
            guard let lu = try? conteneur.decode(Nombre.self, forKey: cle), lu.flottant != nil else { return nil }
            return lu
        }

        private static func publie(_ conteneur: KeyedDecodingContainer<Cles>, _ cle: Cles) -> Bool {
            conteneur.contains(cle) && !((try? conteneur.decodeNil(forKey: cle)) ?? false)
        }

        enum Cles: String, CodingKey {
            case dotation = "entitlement"
            case creditsUtilises = "credits_used"
            case restant = "remaining"
            case restantAncien = "quota_remaining"
            case pourcentageRestant = "percent_remaining"
            case depassements = "overage_count"
            case depassementPermis = "overage_permitted"
            case illimite = "unlimited"
        }
    }

    /// `nil` seulement quand le corps n'est pas un objet JSON : une page d'erreur servie en
    /// 200, un corps tronqué. Une réponse sans réserve premium est une mesure qui ne chiffre
    /// rien — un quota vide, aucune jauge.
    static func decoder(_ donnees: Data, mesureA: Date) -> MesureCopilot? {
        guard let reponse = try? JSONDecoder().decode(Reponse.self, from: donnees) else { return nil }
        var mesure = MesureCopilot(quota: Quota([]), mesureA: mesureA, login: nonVide(reponse.login))
        guard let premium = reponse.instantanes?.premium else { return mesure }

        // Illimité : ni jauge, ni dépassement — rien ne se consomme contre une dotation.
        guard premium.illimite != true else { return mesure }

        let echeance = echeance(utc: reponse.echeanceUTC, jour: reponse.echeance)
        if let utilisation = utilisation(premium),
           let fenetre = Fenetre(libelle: Fenetre.libelleMois, sorte: .mois,
                                 utilisation: utilisation, seRechargeA: echeance) {
            mesure.quota = Quota(fenetre)
        }

        if premium.restantPublie, premium.restant == nil {
            mesure.argentIllisible.insert(.depense)
        } else {
            mesure.depassement = depassement(premium, mesureA: mesureA)
        }
        return mesure
    }

    /// La part consommée de la dotation : le pourcentage restant publié, inversé ; sinon le
    /// restant rapporté à la dotation ; sinon, en dernier, `credits_used`.
    ///
    /// ⛔ `credits_used` ne passe jamais devant : d'après CodexBar (non observé ici), il compte
    /// des crédits IA, une autre unité, et vaut 0 sur un siège dont la dotation est entamée —
    /// pris en premier, il peignait une grille pleine sur un compte à moitié vide.
    ///
    /// ⛔ Une dotation absente, nulle ou négative n'a pas de dénominateur : aucune jauge — ni
    /// pleine, ni vide, ni à sec —, même avec un pourcentage restant. Un siège facturé au jeton
    /// publie `percent_remaining` à 100 sur une dotation nulle, ce qui n'est pas un forfait intact.
    private static func utilisation(_ premium: Instantane) -> Double? {
        guard let dotation = premium.dotation?.flottant, dotation > 0 else { return nil }
        if let pourcentage = premium.pourcentageRestant?.flottant {
            return 100 - pourcentage
        }
        if let restant = premium.restant?.flottant {
            return (dotation - restant) / dotation * 100
        }
        if let utilises = premium.creditsUtilises?.flottant {
            return utilises / dotation * 100
        }
        return nil
    }

    /// Les crédits consommés au-delà de la dotation : un restant négatif en est la mesure
    /// directe, `overage_count` le relais. Sans l'un ni l'autre, un dépassement permis se dit
    /// à zéro — il paiera le travail quand la dotation sera épuisée.
    ///
    /// ⛔ Aucun plafond : le budget qu'un administrateur fixe n'est pas dans la réponse. Aucun
    /// montant en dollars : la réponse compte en crédits, et c'est en crédits qu'il se dit.
    private static func depassement(_ premium: Instantane, mesureA: Date) -> UsagePayant? {
        let consomme: Decimal?
        if let restant = premium.restant?.decimal, restant < 0 {
            consomme = -restant
        } else if let compte = premium.depassements?.decimal, compte > 0 {
            consomme = compte
        } else if premium.depassementPermis == true {
            consomme = 0
        } else {
            consomme = nil
        }
        guard let consomme else { return nil }
        return UsagePayant(nature: .depense,
                           unite: .credits,
                           consomme: Montant(texteDecimal: "\(consomme)", unite: .credits),
                           plafond: nil,
                           solde: nil,
                           utilisation: nil,
                           illimite: nil,
                           actif: premium.depassementPermis,
                           bloque: false,
                           motif: nil,
                           echeance: nil,
                           mesureA: mesureA)
    }

    /// `quota_reset_date_utc` porte l'instant ; `quota_reset_date` ne porte qu'un jour,
    /// lu à minuit UTC — la remise à zéro de Copilot se fait le 1er du mois en UTC.
    static func echeance(utc: String?, jour: String?) -> Date? {
        if let utc, let date = Horodatage.analyser(utc) { return date }
        guard let jour = jour?.trimmingCharacters(in: .whitespaces), !jour.isEmpty else { return nil }
        if let date = Horodatage.analyser(jour) { return date }
        var calendrier = Calendar(identifier: .gregorian)
        calendrier.timeZone = TimeZone(identifier: "UTC")!
        let parties = jour.split(separator: "-", omittingEmptySubsequences: false)
        guard parties.count == 3, parties.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let annee = Int(parties[0]), let mois = Int(parties[1]), let jourDuMois = Int(parties[2]) else { return nil }
        let composantes = DateComponents(year: annee, month: mois, day: jourDuMois)
        guard composantes.isValidDate(in: calendrier) else { return nil }
        return calendrier.date(from: composantes)
    }

    private static func nonVide(_ valeur: String?) -> String? {
        guard let coupe = valeur?.trimmingCharacters(in: .whitespacesAndNewlines), !coupe.isEmpty else { return nil }
        return coupe
    }
}
