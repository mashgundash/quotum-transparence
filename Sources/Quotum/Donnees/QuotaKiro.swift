import Foundation

/// Ce qu'un relevé direct de Kiro établit. La réponse ne nomme personne et le fichier de
/// jeton ne porte aucun courriel : la ligne garde un nom de repli.
struct MesureKiro: Sendable, Equatable {
    var quota: Quota
    var mesureA: Date = .now
    /// Le `profileArn` du fichier de jeton qui a produit la mesure, jamais celui de la base de
    /// `kiro-cli`. ⛔ Il désigne un profil partagé, pas un membre : aucune dépense n'est gardée
    /// d'un relevé à l'autre sur sa foi.
    var profil: String?
    /// `subscriptionInfo.subscriptionTitle`, tel que publié.
    var formule: String?
    /// Le dépassement facturé, tenu hors de la grille — voir `QuotaKiro.decoderDepassement`.
    var depassement: UsagePayant?
    /// Un dépassement publié qu'on ne sait pas lire : ni zéro, ni absence.
    var argentIllisible: Set<UsagePayant.Nature> = []
}

/// Ce que la lecture du jeton puis l'appel à `GetUsageLimits` ont pu établir.
enum ReleveKiro: Sendable, Equatable {
    case releve(MesureKiro)
    /// Jeton présent mais refusé : il se renouvelle en rouvrant Kiro, ou par `kiro-cli login`.
    case reconnexionNecessaire
    /// HTTP 400 sans `profileArn` : un compte d'organisation (IAM Identity Center) exige le
    /// vrai profil, et le fichier de jeton ne le porte pas. Une reconnexion n'y change rien.
    case profilManquant
    /// L'appel n'a rien établi — réseau coupé, statut inattendu, corps illisible, région
    /// hors de la liste connue.
    case indetermine
    /// Aucun jeton Kiro sur cette machine : rien à relever.
    case aucun
}

/// Le jeton que Kiro dépose sur le disque. Il sert à un appel et n'est ni copié, ni
/// journalisé, ni conservé au-delà du relevé.
struct JetonKiro: Sendable, Equatable {
    let valeur: String
    /// Absent chez un compte individuel ; exigé par la route chez un compte d'organisation.
    let profileArn: String?
    let region: String
}

enum LectureKiro: Sendable, Equatable {
    case jeton(JetonKiro)
    /// Aucun fichier, ou un fichier lisible sans jeton.
    case absent
    /// Lecture empêchée — droits refusés, contenu inexploitable, fichier tronqué, profil ou
    /// région qui ne se laissent pas valider.
    case empechee
}

/// ⛔ **Lecture seule.** Le jeton de rafraîchissement voisin n'est jamais lu : le renouveler
/// ici invaliderait celui de l'éditeur.
enum IdentifiantsKiro {
    static let cheminRelatif = ".aws/sso/cache/kiro-auth-token.json"

    /// La région de la route quand rien ne la désigne : la seule où toutes les réponses
    /// publiées ont été obtenues.
    static let regionParDefaut = "us-east-1"

    /// ⛔ Liste fermée : la région fait partie du nom d'hôte qui reçoit le jeton. Une valeur
    /// du fichier hors de cette liste n'envoie rien, plutôt que de composer un hôte.
    static let regionsConnues: Set<String> = ["us-east-1", "eu-central-1"]

    static func fichier(accueil: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        accueil.appendingPathComponent(cheminRelatif)
    }

    static func jeton(fichier url: URL? = nil) async -> LectureKiro {
        let cible = url ?? fichier()
        return await HorsFil.executer { lire(cible) }
    }

    static func lire(_ url: URL) -> LectureKiro {
        let donnees: Data
        do {
            donnees = try Data(contentsOf: url)
        } catch {
            let brute = error as NSError
            if brute.domain == NSCocoaErrorDomain,
               brute.code == NSFileReadNoSuchFileError || brute.code == NSFileNoSuchFileError {
                return .absent
            }
            Journal.donnees.notice("Kiro : fichier de jeton illisible (\(error))")
            return .empechee
        }
        return classer(donnees)
    }

    private struct Contenu: Decodable {
        var accessToken: String?
        var profileArn: String?
        var region: String?

        init(from decodeur: Decoder) throws {
            let conteneur = try decodeur.container(keyedBy: CodingKeys.self)
            accessToken = try? conteneur.decode(String.self, forKey: .accessToken)
            profileArn = try? conteneur.decode(String.self, forKey: .profileArn)
            region = try? conteneur.decode(String.self, forKey: .region)
        }

        enum CodingKeys: String, CodingKey {
            case accessToken, profileArn, region
        }
    }

    static func classer(_ donnees: Data) -> LectureKiro {
        guard let contenu = try? JSONDecoder().decode(Contenu.self, from: donnees) else {
            Journal.donnees.notice("Kiro : fichier de jeton lu mais inexploitable")
            return .empechee
        }
        guard let valeur = nonVide(contenu.accessToken) else { return .absent }

        // Un profil présent mais mal formé n'envoie pas le jeton : la route le refuserait,
        // et sa région désignerait un hôte que rien ne garantit.
        let profil = nonVide(contenu.profileArn)
        var regionDuProfil: String?
        if let profil {
            guard let lue = region(deProfil: profil) else {
                Journal.donnees.notice("Kiro : profil mal formé, relevé abandonné")
                return .empechee
            }
            regionDuProfil = lue
        }
        let region = regionDuProfil ?? nonVide(contenu.region) ?? regionParDefaut
        guard regionsConnues.contains(region) else {
            Journal.donnees.notice("Kiro : région « \(region) » hors de la liste connue, relevé abandonné")
            return .empechee
        }
        return .jeton(JetonKiro(valeur: valeur, profileArn: profil, region: region))
    }

    /// `arn:aws:codewhisperer:<région>:<compte>:profile/<identifiant>` — rien d'autre.
    static func region(deProfil profil: String) -> String? {
        let parties = profil.split(separator: ":", omittingEmptySubsequences: false)
        guard parties.count == 6,
              parties[0] == "arn", parties[1] == "aws", parties[2] == "codewhisperer",
              parties[4].count == 12, parties[4].allSatisfy(\.isASCII), parties[4].allSatisfy(\.isNumber),
              parties[5].hasPrefix("profile/"), parties[5].count > "profile/".count,
              parties[5].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "/" || $0 == "-" || $0 == "_") })
        else { return nil }
        return String(parties[3])
    }

    private static func nonVide(_ valeur: String?) -> String? {
        guard let coupe = valeur?.trimmingCharacters(in: .whitespacesAndNewlines), !coupe.isEmpty else {
            return nil
        }
        return coupe
    }
}

/// Relevé direct du quota de Kiro par `GetUsageLimits`.
///
/// ⛔ `usageBreakdownList` porte des **ressources**, pas des fenêtres : seule `CREDIT` décrit
/// le forfait du compte. Une autre ressource n'entre jamais dans la grille.
enum QuotaKiro {
    static let agent = "Quotum"
    static let ressourceCredit = "CREDIT"

    static func adresse(region: String) -> String { "https://q.\(region).amazonaws.com/getUsageLimits" }

    enum ReponseAPI: Sendable, Equatable {
        case donnees(Data)
        case jetonRefuse
        case profilExige
        case echec
    }

    static func relever(session: URLSession = Reseau.session,
                        delai: TimeInterval = 8) async -> ReleveKiro {
        await relever(accueil: FileManager.default.homeDirectoryForCurrentUser,
                      encoreConsenti: { await MagasinReglages.shared.valeur.consentementMesure[.kiro] },
                      session: session,
                      delai: delai)
    }

    /// Les deux sources sous `accueil` : le fichier de jeton, et la base de `kiro-cli`.
    static func relever(accueil: URL,
                        encoreConsenti: @escaping @Sendable () async -> Bool,
                        session: URLSession,
                        delai: TimeInterval) async -> ReleveKiro {
        await relever(lecture: await IdentifiantsKiro.jeton(fichier: IdentifiantsKiro.fichier(accueil: accueil)),
                      profilDeLaBase: { await ProfilKiro.profil(fichier: ProfilKiro.fichier(accueil: accueil)) },
                      encoreConsenti: encoreConsenti,
                      session: session,
                      delai: delai)
    }

    static func relever(lecture: LectureKiro,
                        profilDeLaBase: () async -> LectureProfilKiro,
                        encoreConsenti: () async -> Bool,
                        session: URLSession,
                        delai: TimeInterval) async -> ReleveKiro {
        switch lecture {
        case .jeton(let jeton):
            return await relever(jeton: jeton, profilDeLaBase: profilDeLaBase, encoreConsenti: encoreConsenti,
                                 session: session, delai: delai)
        case .absent:
            return .aucun
        case .empechee:
            return .indetermine
        }
    }

    /// La base de `kiro-cli` n'est lue qu'au refus d'un jeton sans profil, pour un seul nouvel
    /// essai : un compte individuel n'en a pas besoin, et le profil du jeton, quand il en porte
    /// un, n'est jamais remplacé. Le second résultat est final.
    ///
    /// ⛔ Le consentement est relu après chaque attente : avant le premier envoi, le jeton lu,
    /// puis avant la lecture de la base et avant le second envoi. Un suivi retiré entre-temps
    /// n'ouvre plus rien.
    ///
    /// ⛔ La mesure obtenue par le profil de la base ne porte aucun profil : ce profil est celui
    /// du CLI, partagé par toute une organisation, et ne dit pas quelle connexion a mesuré.
    /// Aucune dépense n'est donc reprise d'un relevé à l'autre sur sa foi.
    static func relever(jeton: JetonKiro,
                        profilDeLaBase: () async -> LectureProfilKiro,
                        encoreConsenti: () async -> Bool,
                        session: URLSession,
                        delai: TimeInterval) async -> ReleveKiro {
        guard await encoreConsenti() else { return .indetermine }
        let reponse = await charger(jeton: jeton, session: session, delai: delai)
        guard reponse == .profilExige, jeton.profileArn == nil else {
            return conclure(reponse, mesureA: Date(), profil: jeton.profileArn)
        }
        guard await encoreConsenti() else { return .indetermine }
        let avecProfil: JetonKiro
        switch await profilDeLaBase() {
        case .profil(let arn, let region):
            guard let compose = Self.jeton(jeton, profilDeLaBase: arn, region: region) else { return .indetermine }
            avecProfil = compose
        case .absent:
            return .profilManquant
        case .empeche:
            return .indetermine
        }
        guard await encoreConsenti() else { return .indetermine }
        guard let recu = await envoyer(jeton: avecProfil, session: session, delai: delai) else {
            return .indetermine
        }
        return conclure(interpreterSecondEssai(code: recu.code, donnees: recu.donnees), mesureA: Date(), profil: nil)
    }

    /// Le jeton, doté du profil lu dans la base et de la région que ce profil désigne. `nil`
    /// quand le jeton porte déjà un profil — il prime — ou que la région sort de la liste.
    static func jeton(_ jeton: JetonKiro, profilDeLaBase arn: String, region: String) -> JetonKiro? {
        guard jeton.profileArn == nil,
              IdentifiantsKiro.region(deProfil: arn) == region,
              IdentifiantsKiro.regionsConnues.contains(region) else { return nil }
        return JetonKiro(valeur: jeton.valeur, profileArn: arn, region: region)
    }

    /// Un 400 désigne le profil de la base, qu'une reconnexion ne changerait pas. Un 401 ou un
    /// 403 reste le refus du jeton, comme au premier essai : il a pu expirer entre les deux.
    static func interpreterSecondEssai(code: Int, donnees: Data) -> ReponseAPI {
        switch code {
        case 200: .donnees(donnees)
        case 401, 403: .jetonRefuse
        case 400: .profilExige
        default: .echec
        }
    }

    static func conclure(_ reponse: ReponseAPI, mesureA: Date, profil: String?) -> ReleveKiro {
        switch reponse {
        case .jetonRefuse: return .reconnexionNecessaire
        case .profilExige: return .profilManquant
        case .echec: return .indetermine
        case .donnees(let donnees):
            guard var mesure = decoder(donnees, mesureA: mesureA) else { return .indetermine }
            mesure.profil = profil
            return .releve(mesure)
        }
    }

    /// ⚠️ L'`Authorization` se pose **sur la requête**, jamais dans la configuration de
    /// session : CFNetwork rejoue celle-ci sur la cible d'une redirection, autre hôte compris.
    static func requete(jeton: JetonKiro, delai: TimeInterval) -> URLRequest? {
        guard IdentifiantsKiro.regionsConnues.contains(jeton.region),
              var composants = URLComponents(string: adresse(region: jeton.region)) else { return nil }
        var parametres = [URLQueryItem(name: "origin", value: "AI_EDITOR"),
                          URLQueryItem(name: "resourceType", value: "AGENTIC_REQUEST")]
        if let profil = jeton.profileArn {
            parametres.append(URLQueryItem(name: "profileArn", value: profil))
        }
        composants.queryItems = parametres
        guard let url = composants.url else { return nil }
        var requete = URLRequest(url: url)
        requete.httpMethod = "GET"
        requete.timeoutInterval = delai
        requete.setValue("Bearer \(jeton.valeur)", forHTTPHeaderField: "Authorization")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue(agent, forHTTPHeaderField: "User-Agent")
        return requete
    }

    private static func charger(jeton: JetonKiro,
                                session: URLSession,
                                delai: TimeInterval) async -> ReponseAPI {
        guard let recu = await envoyer(jeton: jeton, session: session, delai: delai) else { return .echec }
        return interpreter(code: recu.code, donnees: recu.donnees, avecProfil: jeton.profileArn != nil)
    }

    private static func envoyer(jeton: JetonKiro,
                                session: URLSession,
                                delai: TimeInterval) async -> (code: Int, donnees: Data)? {
        guard let requete = requete(jeton: jeton, delai: delai),
              let hote = requete.url?.host(percentEncoded: true) else { return nil }
        do {
            let (donnees, reponse) = try await session.data(for: requete,
                                                            delegate: RedirectionMemeHoteSeulement(hote: hote))
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            if code != 200 { Journal.donnees.notice("Quota Kiro : statut HTTP \(code)") }
            return (code, donnees)
        } catch {
            Journal.donnees.debug("Quota Kiro : amazonaws.com injoignable")
            return nil
        }
    }

    /// ⚠️ Le 403 est le refus d'un jeton expiré chez AWS, pas seulement un droit manquant :
    /// le lire en échec ordinaire laisserait la ligne attendre une mesure qui ne viendra pas.
    /// Le 400 ne désigne le profil que s'il n'a pas été envoyé ; avec lui, c'est un échec.
    static func interpreter(code: Int, donnees: Data, avecProfil: Bool) -> ReponseAPI {
        switch code {
        case 200: .donnees(donnees)
        case 401, 403: .jetonRefuse
        case 400 where !avecProfil: .profilExige
        default: .echec
        }
    }

    // MARK: - Analyses pures

    private struct Reponse: Decodable {
        var ressources: [Ressource]?
        var prochaineRecharge: Nombre?
        var configurationDepassement: ConfigurationDepassement?
        var abonnement: Abonnement?

        enum CodingKeys: String, CodingKey {
            case ressources = "usageBreakdownList"
            case prochaineRecharge = "nextDateReset"
            case configurationDepassement = "overageConfiguration"
            case abonnement = "subscriptionInfo"
        }
    }

    private struct ConfigurationDepassement: Decodable {
        var statut: String?
        init(from decodeur: Decoder) throws {
            let conteneur = try decodeur.container(keyedBy: CodingKeys.self)
            statut = try? conteneur.decode(String.self, forKey: .statut)
        }
        enum CodingKeys: String, CodingKey { case statut = "overageStatus" }
    }

    private struct Abonnement: Decodable {
        var titre: String?
        init(from decodeur: Decoder) throws {
            let conteneur = try decodeur.container(keyedBy: CodingKeys.self)
            titre = try? conteneur.decode(String.self, forKey: .titre)
        }
        enum CodingKeys: String, CodingKey { case titre = "subscriptionTitle" }
    }

    /// Chaque champ se lit seul : un champ illisible ne fait pas tomber ses voisins, et un
    /// champ `null` reste une absence.
    private struct Ressource: Decodable {
        var type: String?
        var consomme: Nombre?
        var consommePrecis: Nombre?
        var limite: Nombre?
        var limitePrecise: Nombre?
        var depassement: Nombre?
        var depassementPrecis: Nombre?
        var plafondDepassement: Nombre?
        var plafondDepassementPrecis: Nombre?
        var tarifDepassement: Nombre?
        var prochaineRecharge: Nombre?
        /// Vrai quand `bonuses` est publié et n'est pas une liste vide — liste non vide, ou
        /// forme inattendue dont on ne sait pas si elle est vide.
        var bonusPublies = false

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            type = try? c.decode(String.self, forKey: .type)
            consomme = Self.lire(c, .consomme)
            consommePrecis = Self.lire(c, .consommePrecis)
            limite = Self.lire(c, .limite)
            limitePrecise = Self.lire(c, .limitePrecise)
            depassement = Self.lire(c, .depassement)
            depassementPrecis = Self.lire(c, .depassementPrecis)
            plafondDepassement = Self.lire(c, .plafondDepassement)
            plafondDepassementPrecis = Self.lire(c, .plafondDepassementPrecis)
            tarifDepassement = Self.lire(c, .tarifDepassement)
            prochaineRecharge = Self.lire(c, .prochaineRecharge)
            if c.contains(.bonus), (try? c.decodeNil(forKey: .bonus)) != true {
                bonusPublies = (try? c.decode([ElementQuelconque].self, forKey: .bonus))?.isEmpty != true
            }
        }

        /// Un élément de `bonuses`, quelle que soit sa forme : seul leur nombre compte.
        private struct ElementQuelconque: Decodable {
            init(from decodeur: Decoder) throws {}
        }

        private static func lire(_ c: KeyedDecodingContainer<CodingKeys>, _ cle: CodingKeys) -> Nombre? {
            guard c.contains(cle), (try? c.decodeNil(forKey: cle)) != true else { return nil }
            return (try? c.decode(Nombre.self, forKey: cle)) ?? Nombre(valeur: nil)
        }

        enum CodingKeys: String, CodingKey {
            case type = "resourceType"
            case consomme = "currentUsage"
            case consommePrecis = "currentUsageWithPrecision"
            case limite = "usageLimit"
            case limitePrecise = "usageLimitWithPrecision"
            case depassement = "currentOverages"
            case depassementPrecis = "currentOveragesWithPrecision"
            case plafondDepassement = "overageCap"
            case plafondDepassementPrecis = "overageCapWithPrecision"
            case tarifDepassement = "overageRate"
            case prochaineRecharge = "nextDateReset"
            case bonus = "bonuses"
        }

        /// La valeur précise quand elle est lisible, l'arrondie sinon.
        static func meilleur(_ precis: Nombre?, _ arrondi: Nombre?) -> Nombre? {
            if let precis, precis.valeur != nil { return precis }
            return arrondi ?? precis
        }
    }

    /// Un nombre publié. `valeur` vaut `nil` quand le champ est présent mais n'est pas un
    /// nombre fini : présent-et-illisible n'est ni zéro, ni absence.
    private struct Nombre: Decodable {
        let valeur: Double?

        init(valeur: Double?) { self.valeur = valeur }

        init(from decodeur: Decoder) throws {
            let conteneur = try decodeur.singleValueContainer()
            if let nombre = try? conteneur.decode(Double.self), nombre.isFinite {
                valeur = nombre
            } else {
                valeur = nil
            }
        }
    }

    /// `nil` seulement pour un corps qui n'est pas l'objet attendu : une page d'erreur
    /// servie en 200, un corps tronqué.
    static func decoder(_ donnees: Data, mesureA: Date) -> MesureKiro? {
        guard let reponse = try? JSONDecoder().decode(Reponse.self, from: donnees) else { return nil }
        let credit = reponse.ressources?.first { $0.type == ressourceCredit }
        let titre = reponse.abonnement?.titre?.trimmingCharacters(in: .whitespacesAndNewlines)
        var mesure = MesureKiro(quota: Quota([]),
                                mesureA: mesureA,
                                formule: titre?.isEmpty == false ? titre : nil)
        guard let credit else { return mesure }

        let recharge = date(credit.prochaineRecharge) ?? date(reponse.prochaineRecharge)
        if let fenetre = fenetre(credit, recharge: recharge) {
            mesure.quota = Quota(fenetre)
        }
        switch decoderDepassement(credit,
                                  statut: reponse.configurationDepassement?.statut,
                                  mesureA: mesureA) {
        case .lu(let usage): mesure.depassement = usage
        case .illisible: mesure.argentIllisible = [.depense]
        case .aucun: break
        }
        return mesure
    }

    /// ⛔ `currentUsage` **inclut déjà le dépassement** : la part du forfait est
    /// `currentUsage − currentOverages`. Un dépassement absent compte pour zéro sans rien
    /// inventer : il ne commence qu'une fois le forfait entier consommé, et la fenêtre se
    /// borne à 100 de toute façon.
    ///
    /// ⛔ Des crédits bonus publiés (`bonuses` non vide) : aucune fenêtre. Leur dépense est
    /// comptée dans `currentUsage` sans être chiffrée à part — rapporté par CodexBar, non
    /// observé ici —, et la soustraire supposerait une forme de `bonuses` que personne n'a
    /// publiée. La part du forfait en serait surestimée, jusqu'à « épuisé » par le bornage.
    private static func fenetre(_ credit: Ressource, recharge: Date?) -> Fenetre? {
        guard !credit.bonusPublies else { return nil }
        guard let consomme = Ressource.meilleur(credit.consommePrecis, credit.consomme)?.valeur,
              let limite = Ressource.meilleur(credit.limitePrecise, credit.limite)?.valeur,
              limite > 0 else { return nil }
        let depassementLu = Ressource.meilleur(credit.depassementPrecis, credit.depassement)
        // Présent mais illisible : la part du forfait ne se calcule plus sans risquer de
        // compter le dépassement deux fois.
        if let depassementLu, depassementLu.valeur == nil { return nil }
        let depassement = depassementLu?.valeur ?? 0
        // Négatif, ou plus grand que la consommation qui l'inclut : la réponse se contredit,
        // et la soustraction afficherait un forfait intact.
        guard depassement >= 0, depassement <= consomme else { return nil }
        return Fenetre(libelle: Fenetre.libelleMois,
                       sorte: .mois,
                       utilisation: (consomme - depassement) / limite * 100,
                       seRechargeA: recharge)
    }

    enum LectureDepassement: Equatable {
        case lu(UsagePayant)
        case illisible
        case aucun
    }

    /// Dépassement actif seulement : `overageStatus` à `ENABLED` **et** un dépassement
    /// positif. Désactivé, ou rien dépensé, il n'y a rien à dire.
    ///
    /// ⚠️ En dollars **seulement** quand `overageRate` est publié (dollars par crédit) : les
    /// montants sont alors `crédits × tarif`, arrondis au cent. Sans tarif, ils restent en
    /// crédits — aucun tarif n'est supposé.
    private static func decoderDepassement(_ credit: Ressource,
                                           statut: String?,
                                           mesureA: Date) -> LectureDepassement {
        guard statut == "ENABLED" else { return .aucun }
        let lu = Ressource.meilleur(credit.depassementPrecis, credit.depassement)
        guard let lu else { return .aucun }
        guard let credits = lu.valeur, credits >= 0 else { return .illisible }
        guard credits > 0 else { return .aucun }

        let plafondLu = Ressource.meilleur(credit.plafondDepassementPrecis, credit.plafondDepassement)
        if let plafondLu, plafondLu.valeur.map({ $0 >= 0 }) != true { return .illisible }
        let plafondCredits = plafondLu?.valeur

        let tarif = credit.tarifDepassement?.valeur.flatMap { $0 > 0 ? $0 : nil }
        let unite: Montant.Unite = tarif == nil ? .credits : .devise("USD")
        guard let consomme = montant(credits, tarif: tarif, unite: unite) else { return .illisible }
        var plafond: Montant?
        if let plafondCredits {
            guard let converti = montant(plafondCredits, tarif: tarif, unite: unite) else { return .illisible }
            plafond = converti
        }
        let atteint = plafondCredits.map { $0 > 0 && credits >= $0 } ?? false
        guard let usage = UsagePayant(nature: .depense,
                                      unite: unite,
                                      consomme: consomme,
                                      plafond: plafond,
                                      solde: nil,
                                      utilisation: nil,
                                      illimite: nil,
                                      actif: true,
                                      bloque: atteint,
                                      motif: nil,
                                      echeance: nil,
                                      mesureA: mesureA) else { return .illisible }
        return .lu(usage)
    }

    /// Au centième, en `Decimal` : ni le crédit ni le dollar ne passent par un entier
    /// approché. Le tarif est relu dans son écriture la plus courte (`0.04`), pas dans son
    /// développement binaire.
    private static func montant(_ credits: Double, tarif: Double?, unite: Montant.Unite) -> Montant? {
        guard var valeur = Decimal(string: String(credits)) else { return nil }
        if let tarif {
            guard let parCredit = Decimal(string: String(tarif)) else { return nil }
            valeur *= parCredit
        }
        var centiemes = valeur * 100
        var arrondi = Decimal()
        NSDecimalRound(&arrondi, &centiemes, 0, .plain)
        let nombre = NSDecimalNumber(decimal: arrondi)
        guard nombre.compare(NSDecimalNumber(value: Int64.max)) == .orderedAscending,
              nombre.compare(NSDecimalNumber(value: Int64.min)) == .orderedDescending else { return nil }
        return Montant(unitesMineures: nombre.int64Value, unite: unite, exposant: 2)
    }

    /// Un epoch en **secondes**, publié en flottant (`1790812800.0`).
    private static func date(_ lu: Nombre?) -> Date? {
        guard let secondes = lu?.valeur, secondes > 0 else { return nil }
        return Date(timeIntervalSince1970: secondes)
    }
}
