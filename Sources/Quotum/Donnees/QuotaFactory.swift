import CryptoKit
import Foundation

/// La connexion que le CLI de Factory (`droid`) range, chiffrée, dans son dossier. Elle sert
/// à un appel et n'est ni copiée, ni journalisée, ni conservée au-delà du relevé.
struct JetonFactory: Sendable, Equatable {
    let valeur: String
    /// `active_organization_id` — l'organisation que `droid` a choisie, posée en en-tête pour
    /// que la réponse décrive la même. Absente chez un compte sans organisation active.
    let organisation: String?
    let region: RegionFactory
}

/// La région de résidence que le fichier déclare. ⛔ Liste fermée : elle désigne l'hôte qui
/// reçoit le jeton, et une valeur inconnue n'envoie rien plutôt que de composer un hôte.
enum RegionFactory: String, Sendable, Equatable {
    case mondiale = "global"
    case europe = "eu"
}

enum LectureFactory: Sendable, Equatable {
    case jeton(JetonFactory)
    /// Aucun fichier de connexion, ou un fichier dont la clé n'existe plus — ce que `droid`
    /// lui-même ne relirait pas : il redemanderait une connexion.
    case absent
    /// Lecture empêchée — Trousseau refusé ou verrouillé, fichier illisible, déchiffrement
    /// en échec, contenu inattendu, région inconnue, déploiement privé. Rien n'est établi.
    case empechee
}

/// Ce que la lecture de la clé au Trousseau a établi. La clé est un secret : elle ne sert
/// qu'au déchiffrement, et n'est ni journalisée ni conservée.
enum LectureCleFactory: Sendable, Equatable {
    case cle(Data)
    /// Code 44 : l'élément n'existe pas.
    case absente
    case empechee
}

/// Lecture de la clé de chiffrement au Trousseau. Injectée sans valeur par défaut : un test
/// qui oublierait de la fournir ne compile pas, au lieu d'interroger le vrai Trousseau.
typealias LecteurCleFactory = @Sendable () async -> LectureCleFactory

/// Le contenu d'un fichier du dossier de Factory, tel que la lecture l'a trouvé.
enum FichierFactory: Sendable, Equatable {
    case contenu(Data)
    case absent
    case illisible
}

/// ⛔ **Lecture seule.** Le `refresh_token` voisin n'est jamais lu : le renouveler ici
/// invaliderait celui de `droid`. Aucun fichier n'est écrit, aucune clé n'est créée.
///
/// Format établi par lecture du CLI publié (`@factory/cli-darwin-arm64` 0.233.0, paquet npm
/// public, binaire Bun lu sans être exécuté) — aucune documentation officielle :
/// - le dossier est `~/.factory` ;
/// - `auth.v2.loginkeychain` : la connexion, chiffrée par une clé que `droid` range au
///   Trousseau **par `/usr/bin/security add-generic-password`**, service « Factory CLI »,
///   compte « auth-encryption-key-security-cli ». C'est le stockage par défaut de cette
///   version sur macOS ;
/// - `auth.v2.file` : la même connexion, chiffrée par une clé posée en clair à côté, dans
///   `auth.v2.key` (`FACTORY_DISABLE_KEYRING=1`) ;
/// - `auth.v2.keyring` : stockage d'une version antérieure, clé rangée par le module natif
///   `keytar` sous le compte « auth-encryption-key ». ⛔ **Jamais lu** : l'élément a été
///   créé par le processus de `droid`, son ACL ne fait pas confiance à `security`, et le
///   lire ouvrirait une demande d'autorisation que l'utilisateur n'attend pas ;
/// - chiffrement : AES-256-GCM, clé de 32 octets en base64, texte
///   `base64(nonce de 16 octets):base64(étiquette de 16 octets):base64(chiffré)`. ⚠️ Le
///   nonce fait **16** octets, pas les 12 usuels ;
/// - texte clair : `{access_token, refresh_token, active_organization_id?, whoami?: {region?,
///   isOnPrem?…}, region?}`, l'ancienne forme portant `region` à la racine.
enum IdentifiantsFactory {
    static let dossierRelatif = ".factory"
    static let fichierTrousseau = "auth.v2.loginkeychain"
    static let fichierAvecCle = "auth.v2.file"
    static let fichierCle = "auth.v2.key"
    static let fichierKeytar = "auth.v2.keyring"

    static let serviceTrousseau = "Factory CLI"
    static let compteTrousseau = "auth-encryption-key-security-cli"

    static let longueurCle = 32
    static let longueurNonce = 16
    static let longueurEtiquette = 16
    /// Une connexion tient en quelques kilo-octets ; au-delà, ce n'est pas ce fichier.
    static let tailleMaximale = 64 * 1024

    static func dossier(accueil: URL) -> URL {
        accueil.appendingPathComponent(dossierRelatif, isDirectory: true)
    }

    /// La lecture réelle de la clé, à passer explicitement par le branchement de production.
    ///
    /// ⚠️ Un seul compte candidat, jamais de seconde tentative sans `-a` : sous le même
    /// service vit l'élément `keytar` d'une version antérieure, et le lire ouvrirait la
    /// demande d'autorisation que cette lecture évite.
    static let cleParTrousseau: LecteurCleFactory = {
        classerCle(await Trousseau.executerLecture(service: serviceTrousseau,
                                                   comptes: [compteTrousseau],
                                                   sujet: "Factory"))
    }

    /// Le code 44 est le seul qui conclue — l'élément n'existe pas. Une sortie qui n'est pas
    /// une clé de 32 octets ne conclut rien non plus : l'élément est là, son contenu échappe.
    static func classerCle(_ brute: LectureBrute) -> LectureCleFactory {
        guard !brute.interrompue, let resultat = brute.resultats.first else { return .empechee }
        guard resultat.reussi else {
            if resultat.code == Trousseau.codeAbsent { return .absente }
            // Le code, jamais la sortie : c'est elle qui porte le secret.
            Journal.donnees.notice("Factory : lecture de la clé refusée (code \(resultat.code))")
            return .empechee
        }
        guard let cle = decoderCle(resultat.sortie) else {
            Journal.donnees.notice("Factory : clé du Trousseau lue mais inexploitable")
            return .empechee
        }
        return .cle(cle)
    }

    static func decoderCle(_ texte: String) -> Data? {
        let coupe = texte.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cle = Data(base64Encoded: coupe), cle.count == longueurCle else { return nil }
        return cle
    }

    /// Lit le dossier de Factory. Les fichiers se lisent hors du fil principal ; la clé du
    /// Trousseau n'est demandée **que** si le fichier qu'elle chiffre existe.
    static func jeton(dossier: URL, cleTrousseau: LecteurCleFactory) async -> LectureFactory {
        let fichiers = await HorsFil.executer {
            (trousseau: lire(dossier.appendingPathComponent(fichierTrousseau)),
             avecCle: lire(dossier.appendingPathComponent(fichierAvecCle)),
             cle: lire(dossier.appendingPathComponent(fichierCle)),
             keytar: lire(dossier.appendingPathComponent(fichierKeytar)))
        }
        var cle: LectureCleFactory = .absente
        if case .contenu = fichiers.trousseau { cle = await cleTrousseau() }
        return conclure(chiffreTrousseau: fichiers.trousseau,
                        cleTrousseau: cle,
                        chiffreFichier: fichiers.avecCle,
                        cleFichier: fichiers.cle,
                        keytar: fichiers.keytar)
    }

    static func lire(_ url: URL) -> FichierFactory {
        do {
            return .contenu(try LectureFichier.lire(url, tailleMaximale: tailleMaximale))
        } catch .absent {
            return .absent
        } catch {
            Journal.donnees.notice("Factory : \(url.lastPathComponent) illisible (\(error))")
            return .illisible
        }
    }

    /// L'ordre de `droid` : le stockage du Trousseau d'abord, puis le fichier à clé posée à
    /// côté. Une connexion obtenue l'emporte ; sans elle, le moindre échec retire sa
    /// conclusion à l'ensemble — la connexion est peut-être derrière lui.
    static func conclure(chiffreTrousseau: FichierFactory,
                         cleTrousseau: LectureCleFactory,
                         chiffreFichier: FichierFactory,
                         cleFichier: FichierFactory,
                         keytar: FichierFactory) -> LectureFactory {
        var empechee = false

        switch chiffreTrousseau {
        case .contenu(let chiffre):
            switch cleTrousseau {
            case .cle(let cle):
                switch ouvrir(chiffre, cle: cle) {
                case .jeton(let jeton): return .jeton(jeton)
                case .absent: break
                case .empechee: empechee = true
                }
            // Un fichier dont la clé n'existe plus : `droid` ne le relirait pas non plus.
            case .absente: break
            case .empechee: empechee = true
            }
        case .illisible: empechee = true
        case .absent: break
        }

        switch (chiffreFichier, cleFichier) {
        case (.contenu(let chiffre), .contenu(let brute)):
            if let cle = decoderCle(String(decoding: brute, as: UTF8.self)) {
                switch ouvrir(chiffre, cle: cle) {
                case .jeton(let jeton): return .jeton(jeton)
                case .absent: break
                case .empechee: empechee = true
                }
            } else {
                Journal.donnees.notice("Factory : \(fichierCle) inexploitable")
                empechee = true
            }
        case (.contenu, .absent):
            break
        case (.illisible, _), (.contenu, .illisible):
            empechee = true
        case (.absent, _):
            break
        }

        if case .absent = keytar {} else {
            Journal.donnees.notice("Factory : connexion rangée par une version antérieure de droid, non lue")
            empechee = true
        }
        return empechee ? .empechee : .absent
    }

    private static func ouvrir(_ chiffre: Data, cle: Data) -> LectureFactory {
        guard let clair = dechiffrer(String(decoding: chiffre, as: UTF8.self), cle: cle) else {
            Journal.donnees.notice("Factory : déchiffrement en échec")
            return .empechee
        }
        return classer(clair)
    }

    /// `nil` pour un texte qui n'a pas la forme attendue, une clé de mauvaise longueur, ou un
    /// chiffré que l'étiquette refuse — mauvaise clé comme fichier tronqué.
    static func dechiffrer(_ texte: String, cle: Data) -> Data? {
        guard cle.count == longueurCle else { return nil }
        let parties = texte.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parties.count == 3,
              let nonce = Data(base64Encoded: String(parties[0])), nonce.count == longueurNonce,
              let etiquette = Data(base64Encoded: String(parties[1])), etiquette.count == longueurEtiquette,
              let chiffre = Data(base64Encoded: String(parties[2])) else { return nil }
        do {
            let boite = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                              ciphertext: chiffre,
                                              tag: etiquette)
            return try AES.GCM.open(boite, using: SymmetricKey(data: cle))
        } catch {
            return nil
        }
    }

    private struct Contenu: Decodable {
        struct Identite: Decodable {
            var region: String?
            var surSite: Bool?

            init(from decodeur: Decoder) throws {
                let c = try decodeur.container(keyedBy: CodingKeys.self)
                region = try? c.decode(String.self, forKey: .region)
                surSite = try? c.decode(Bool.self, forKey: .surSite)
            }

            enum CodingKeys: String, CodingKey {
                case region
                case surSite = "isOnPrem"
            }
        }

        var jeton: String?
        var organisation: String?
        var identite: Identite?
        var region: String?

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            jeton = try? c.decode(String.self, forKey: .jeton)
            organisation = try? c.decode(String.self, forKey: .organisation)
            identite = try? c.decode(Identite.self, forKey: .identite)
            region = try? c.decode(String.self, forKey: .region)
        }

        enum CodingKeys: String, CodingKey {
            case jeton = "access_token"
            case organisation = "active_organization_id"
            case identite = "whoami"
            case region
        }
    }

    /// Le texte clair déchiffré. ⛔ Un déploiement privé (`isOnPrem`) ne part pas vers les
    /// hôtes de Factory, et une région inconnue n'en compose aucun.
    static func classer(_ clair: Data) -> LectureFactory {
        guard let contenu = try? JSONDecoder().decode(Contenu.self, from: clair) else {
            Journal.donnees.notice("Factory : connexion déchiffrée mais inexploitable")
            return .empechee
        }
        guard let valeur = nonVide(contenu.jeton), sansControle(valeur) else {
            Journal.donnees.notice("Factory : connexion sans jeton exploitable")
            return .empechee
        }
        if contenu.identite?.surSite == true {
            Journal.donnees.notice("Factory : déploiement privé, relevé abandonné")
            return .empechee
        }
        let lue = nonVide(contenu.identite?.region) ?? nonVide(contenu.region)
        let region: RegionFactory
        if let lue {
            guard let connue = RegionFactory(rawValue: lue) else {
                Journal.donnees.notice("Factory : région « \(lue) » inconnue, relevé abandonné")
                return .empechee
            }
            region = connue
        } else {
            region = .mondiale
        }
        let organisation = nonVide(contenu.organisation)
        if let organisation, !sansControle(organisation) {
            Journal.donnees.notice("Factory : organisation mal formée, relevé abandonné")
            return .empechee
        }
        return .jeton(JetonFactory(valeur: valeur, organisation: organisation, region: region))
    }

    /// Une valeur qui part en en-tête : ASCII imprimable, sans espace. Un retour à la ligne y
    /// glisserait un second en-tête.
    private static func sansControle(_ valeur: String) -> Bool {
        valeur.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
    }

    private static func nonVide(_ valeur: String?) -> String? {
        guard let coupe = valeur?.trimmingCharacters(in: .whitespacesAndNewlines), !coupe.isEmpty else {
            return nil
        }
        return coupe
    }
}

struct MesureFactory: Sendable, Equatable {
    var quota: Quota
    var mesureA: Date
}

/// Ce que la lecture de la connexion puis l'appel ont pu établir.
enum ReleveFactory: Sendable, Equatable {
    case releve(MesureFactory)
    /// Jeton présent mais refusé. ⚠️ Cas ordinaire : le jeton d'accès vit peu, `droid` le
    /// renouvelle à chaque usage et Quotum jamais. Il revient en relançant `droid`.
    case reconnexionNecessaire
    /// L'appel n'a rien établi — réseau coupé, statut inattendu, corps illisible, ou
    /// connexion qu'on n'a pas pu lire.
    case indetermine
    /// Aucune connexion Factory sur cette machine : rien à relever.
    case aucun
}

/// Relevé du quota de Factory par `GET /api/billing/limits` — la route que `droid` appelle
/// lui-même (lu dans le CLI 0.233.0, et chez CodexBar). ⚠️ Absente du contrat OpenAPI public.
///
/// Deux familles, chacune en trois fenêtres (`fiveHour`, `weekly`, `monthly`) : jusqu'à six.
/// La durée n'est portée par **aucun champ**, c'est le nom de la clé qui la donne.
enum QuotaFactory {
    static let agent = "Quotum"
    static let chemin = "/api/billing/limits"
    static let enteteOrganisation = "X-Factory-Org-Id"

    /// Les noms que `droid` donne lui-même aux deux familles (« Standard Usage », « Droid
    /// Core ») : ceux que l'utilisateur a déjà lus. Noms de produit, ils ne se traduisent pas.
    static let reserveStandard = "Standard"
    static let reserveCore = "Droid Core"

    enum ReponseAPI: Sendable, Equatable {
        case donnees(Data)
        case jetonRefuse
        case echec
    }

    /// Les adresses entières, en littéral : une recherche d'adresses dans les sources doit
    /// les rendre telles qu'elles partent.
    static func adresse(region: RegionFactory) -> URL? {
        switch region {
        case .mondiale: URL(string: "https://api.factory.ai/api/billing/limits")
        case .europe: URL(string: "https://api.eu.factory.ai/api/billing/limits")
        }
    }

    static func relever(dossier: URL,
                        cleTrousseau: LecteurCleFactory,
                        session: URLSession,
                        delai: TimeInterval = 8) async -> ReleveFactory {
        switch await IdentifiantsFactory.jeton(dossier: dossier, cleTrousseau: cleTrousseau) {
        case .jeton(let jeton):
            return await relever(jeton: jeton, session: session, delai: delai)
        case .absent:
            return .aucun
        case .empechee:
            return .indetermine
        }
    }

    static func relever(jeton: JetonFactory,
                        session: URLSession,
                        delai: TimeInterval = 8) async -> ReleveFactory {
        let reponse = await charger(jeton: jeton, session: session, delai: delai)
        return conclure(reponse, maintenant: Date())
    }

    static func conclure(_ reponse: ReponseAPI, maintenant: Date) -> ReleveFactory {
        switch reponse {
        case .jetonRefuse: return .reconnexionNecessaire
        case .echec: return .indetermine
        case .donnees(let donnees):
            guard let quota = decoder(donnees, maintenant: maintenant) else { return .indetermine }
            return .releve(MesureFactory(quota: quota, mesureA: maintenant))
        }
    }

    /// ⚠️ L'`Authorization` se pose **sur la requête**, jamais dans la configuration de
    /// session. Ni `Origin`, ni `Referer`, ni `X-Factory-Client` : l'app ne se présente ni
    /// comme le client web ni comme `droid`.
    static func requete(jeton: JetonFactory, delai: TimeInterval) -> URLRequest? {
        guard let url = adresse(region: jeton.region) else { return nil }
        var requete = URLRequest(url: url)
        requete.httpMethod = "GET"
        requete.timeoutInterval = delai
        requete.setValue("Bearer \(jeton.valeur)", forHTTPHeaderField: "Authorization")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue(agent, forHTTPHeaderField: "User-Agent")
        if let organisation = jeton.organisation {
            requete.setValue(organisation, forHTTPHeaderField: enteteOrganisation)
        }
        return requete
    }

    private static func charger(jeton: JetonFactory,
                                session: URLSession,
                                delai: TimeInterval) async -> ReponseAPI {
        guard let requete = requete(jeton: jeton, delai: delai),
              let hote = requete.url?.host(percentEncoded: true) else { return .echec }
        do {
            let (donnees, reponse) = try await session.data(for: requete,
                                                            delegate: RedirectionMemeHoteSeulement(hote: hote))
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            if code != 200 { Journal.donnees.notice("Quota Factory : statut HTTP \(code)") }
            return interpreter(code: code, donnees: donnees)
        } catch {
            Journal.donnees.debug("Quota Factory : \(hote) injoignable")
            return .echec
        }
    }

    /// Le 401 est le seul statut dont l'utilisateur ait quelque chose à faire : relancer
    /// `droid`. Un 429 ou un 5xx ne dit rien du compte.
    static func interpreter(code: Int, donnees: Data) -> ReponseAPI {
        switch code {
        case 200: .donnees(donnees)
        case 401: .jetonRefuse
        default: .echec
        }
    }

    // MARK: - Analyse pure

    private enum Lu<Valeur> {
        case absent
        case illisible
        case valeur(Valeur)
    }

    /// Une fenêtre telle que publiée. Chaque champ se lit seul : un champ illisible ne fait
    /// pas tomber ses voisins, mais il ne devient jamais zéro.
    private struct FenetreAPI: Decodable {
        var utilisation: Lu<Double> = .absent
        var fin: Lu<Date> = .absent

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            if c.contains(.utilisation), (try? c.decodeNil(forKey: .utilisation)) != true {
                if let nombre = try? c.decode(Double.self, forKey: .utilisation), nombre.isFinite {
                    utilisation = .valeur(nombre)
                } else {
                    utilisation = .illisible
                }
            }
            if c.contains(.fin), (try? c.decodeNil(forKey: .fin)) != true {
                fin = QuotaFactory.echeance(c, .fin).map(Lu.valeur) ?? .illisible
            }
        }

        enum CodingKeys: String, CodingKey {
            case utilisation = "usedPercent"
            case fin = "windowEnd"
        }
    }

    private struct Famille: Decodable {
        var fenetres: [Fenetre.Sorte: Lu<FenetreAPI>] = [:]

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            for cle in CodingKeys.allCases where c.contains(cle) {
                guard (try? c.decodeNil(forKey: cle)) != true else { continue }
                fenetres[cle.sorte] = (try? c.decode(FenetreAPI.self, forKey: cle)).map(Lu.valeur) ?? .illisible
            }
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case cinqHeures = "fiveHour"
            case semaine = "weekly"
            case mois = "monthly"

            var sorte: Fenetre.Sorte {
                switch self {
                case .cinqHeures: .cinqHeures
                case .semaine: .septJours
                case .mois: .mois
                }
            }
        }
    }

    private struct Limites: Decodable {
        var standard: Lu<Famille> = .absent
        var core: Lu<Famille> = .absent

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            standard = Self.lire(c, .standard)
            core = Self.lire(c, .core)
        }

        private static func lire(_ c: KeyedDecodingContainer<CodingKeys>, _ cle: CodingKeys) -> Lu<Famille> {
            guard c.contains(cle), (try? c.decodeNil(forKey: cle)) != true else { return .absent }
            return (try? c.decode(Famille.self, forKey: cle)).map(Lu.valeur) ?? .illisible
        }

        enum CodingKeys: String, CodingKey { case standard, core }
    }

    private struct Reponse: Decodable {
        var limites: Lu<Limites> = .absent

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            if c.contains(.limites), (try? c.decodeNil(forKey: .limites)) != true {
                limites = (try? c.decode(Limites.self, forKey: .limites)).map(Lu.valeur) ?? .illisible
            }
        }

        enum CodingKeys: String, CodingKey { case limites = "limits" }
    }

    /// `windowEnd` passe chez `droid` par `new Date(…)` : une chaîne ISO 8601, ou un nombre
    /// en **millisecondes**. Rien d'autre n'est deviné — une chaîne de chiffres, que `droid`
    /// rendrait invalide, est illisible ici aussi.
    private static func echeance<Cles: CodingKey>(_ c: KeyedDecodingContainer<Cles>, _ cle: Cles) -> Date? {
        if let texte = try? c.decode(String.self, forKey: cle) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: texte) { return date }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: texte)
        }
        guard let millisecondes = try? c.decode(Double.self, forKey: cle), millisecondes.isFinite else {
            return nil
        }
        return Date(timeIntervalSince1970: millisecondes / 1000)
    }

    /// Les durées que le nom de clé désigne. Le mois n'en a pas de fixe.
    private static func duree(_ sorte: Fenetre.Sorte) -> TimeInterval? {
        switch sorte {
        case .cinqHeures: 5 * 3600
        case .septJours: 7 * 86_400
        default: nil
        }
    }

    private static func libelle(_ sorte: Fenetre.Sorte) -> String {
        switch sorte {
        case .cinqHeures: Fenetre.libelleCinqHeures
        case .septJours: Fenetre.libelleSeptJours
        default: Fenetre.libelleMois
        }
    }

    /// Les fenêtres, de la plus courte à la plus longue, Standard avant Droid Core à durée
    /// égale : c'est la 5 h de Standard qui devient la ligne principale.
    ///
    /// ⛔ Une fenêtre dont l'échéance est passée, ou absente, n'est **pas** zéro : l'API
    /// continue de rendre la dernière fenêtre consommée, et `droid` lui-même la tient pour
    /// inactive. Elle n'est pas posée.
    ///
    /// ⛔ Une fenêtre publiée mais illisible rend tout le relevé indéterminé : montrer ses
    /// voisines seules laisserait lire le compte à travers ce qui reste — une semaine à sec
    /// cachée derrière une 5 h à 10 %.
    ///
    /// Seules `standard` et `core` sont lues, les deux familles que `droid` connaît : une
    /// autre clé de `limits` n'aurait ni nom ni sens établis.
    ///
    /// `nil` pour un corps qui n'est pas l'objet attendu ; un objet sans aucune fenêtre
    /// active donne un `Quota` vide, que le modèle sait représenter.
    static func decoder(_ donnees: Data, maintenant: Date) -> Quota? {
        guard let reponse = try? JSONDecoder().decode(Reponse.self, from: donnees) else { return nil }
        let limites: Limites
        switch reponse.limites {
        case .absent: return Quota([])
        case .illisible: return nil
        case .valeur(let lues): limites = lues
        }

        var familles: [(nom: String, famille: Famille)] = []
        for (nom, lue) in [(reserveStandard, limites.standard), (reserveCore, limites.core)] {
            switch lue {
            case .absent: continue
            case .illisible: return nil
            case .valeur(let famille): familles.append((nom, famille))
            }
        }

        var fenetres: [Fenetre] = []
        for sorte in [Fenetre.Sorte.cinqHeures, .septJours, .mois] {
            for (nom, famille) in familles {
                guard let lue = famille.fenetres[sorte] else { continue }
                guard case .valeur(let api) = lue else { return nil }
                let utilisation: Double
                switch api.utilisation {
                case .absent: continue
                case .illisible: return nil
                case .valeur(let valeur): utilisation = valeur
                }
                let fin: Date
                switch api.fin {
                case .absent: continue
                case .illisible: return nil
                case .valeur(let date): fin = date
                }
                guard fin > maintenant else { continue }
                guard let fenetre = Fenetre(libelle: libelle(sorte),
                                            sorte: sorte,
                                            utilisation: utilisation,
                                            seRechargeA: fin,
                                            duree: duree(sorte),
                                            reserve: nom) else { return nil }
                fenetres.append(fenetre)
            }
        }
        return Quota(fenetres)
    }
}
