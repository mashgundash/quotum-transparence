import Foundation

/// Le jeton de connexion que `muse login` dépose (code d'appareil, préfixe `dca:`). Il sert
/// à un appel et n'est ni copié sur disque, ni journalisé, ni conservé au-delà du relevé.
struct JetonMuse: Sendable, Equatable {
    let valeur: String
}

/// Même partition que `LectureWarp` : une lecture empêchée et une absence de session se
/// ressemblent, et une seule des deux conclut.
enum LectureMuse: Sendable, Equatable {
    case jeton(JetonMuse)
    /// Ni fichier porteur de jeton, ni élément au Trousseau : pas de session Muse ici.
    case absent
    /// Lecture empêchée, ou jeton d'une autre nature qu'une connexion par code d'appareil.
    case empechee
}

/// Ce dont le lecteur a besoin pour toucher au poste. ⛔ Aucune valeur par défaut : le seul
/// jeu qui rebranche le réel est `systeme`, qu'un appelant doit nommer.
struct DependancesMuse: Sendable {
    var accueil: URL
    var environnement: [String: String]
    var lireFichier: @Sendable (URL) -> Result<Data, LectureFichier.Echec>
    var lanceurTrousseau: LanceurProcessus
    var session: URLSession
    var horloge: @Sendable () -> Date
    var delai: TimeInterval

    static var systeme: DependancesMuse {
        DependancesMuse(accueil: FileManager.default.homeDirectoryForCurrentUser,
                        environnement: ProcessInfo.processInfo.environment,
                        lireFichier: { url in Result { () throws(LectureFichier.Echec) -> Data in
                            try LectureFichier.lire(url)
                        } },
                        lanceurTrousseau: Trousseau.lanceurSysteme,
                        session: Reseau.session,
                        horloge: { Date() },
                        delai: 8)
    }
}

/// ⛔ **Lecture seule.** Rien n'est écrit dans le fichier ni dans l'élément du Trousseau de
/// l'outil, et aucun jeton n'est renouvelé.
enum IdentifiantsMuse {
    static let serviceTrousseau = "ai.meta.dev.credentials"
    static let compteTrousseau = "meta"
    static let cheminRelatif = ".config/muse/auth.json"
    static let variableChemin = "MUSE_AUTH_PATH"
    /// Seule une connexion par code d'appareil lit ce quota : les clés `LLM_` du tableau de
    /// bord et les clés d'inférence `LLM|` y sont refusées en 401. Un autre jeton ne part pas.
    static let prefixe = "dca:"

    /// Une variable relative désignerait un fichier selon le dossier courant de l'app, que
    /// rien ne fixe : elle est ignorée.
    static func fichier(accueil: URL, environnement: [String: String]) -> URL {
        if let surcharge = environnement[variableChemin]?.trimmingCharacters(in: .whitespacesAndNewlines),
           surcharge.hasPrefix("/") {
            return URL(fileURLWithPath: surcharge)
        }
        return accueil.appendingPathComponent(cheminRelatif)
    }

    enum ContenuFichier: Equatable {
        case jeton(JetonMuse)
        /// Le fichier porte un jeton qui n'est pas une connexion par code d'appareil.
        case jetonInadapte
        /// Aucun jeton en ligne : la connexion, s'il y en a une, est au Trousseau.
        case sansJeton
        case illisible
    }

    /// Le jeton en ligne du fichier l'emporte sur le Trousseau : c'est lui qui désigne le
    /// compte quand il est là, et le prendre en premier évite toute lecture du Trousseau.
    /// Un fichier présent mais illisible n'empêche pas le Trousseau de répondre ; il retire
    /// seulement à son silence le droit de conclure à l'absence.
    static func jeton(_ dependances: DependancesMuse) async -> LectureMuse {
        let url = fichier(accueil: dependances.accueil, environnement: dependances.environnement)
        let lire = dependances.lireFichier
        let lu = await HorsFil.executer { lire(url) }

        var fichierDouteux = false
        switch lu {
        case .failure(.absent):
            break
        case .failure:
            Journal.donnees.notice("Muse : fichier de connexion illisible")
            fichierDouteux = true
        case .success(let donnees):
            switch classerFichier(donnees) {
            case .jeton(let jeton): return .jeton(jeton)
            case .jetonInadapte:
                Journal.donnees.notice("Muse : le fichier porte un jeton qui n'est pas une connexion par code d'appareil")
                return .empechee
            case .sansJeton: break
            case .illisible:
                Journal.donnees.notice("Muse : fichier de connexion lu mais inexploitable")
                fichierDouteux = true
            }
        }

        let brute = await Trousseau.executerLecture(service: serviceTrousseau,
                                                    comptes: [compteTrousseau],
                                                    sujet: "Muse",
                                                    lanceur: dependances.lanceurTrousseau)
        let trousseau = conclure(brute)
        if trousseau == .absent, fichierDouteux { return .empechee }
        return trousseau
    }

    static func classerFichier(_ donnees: Data) -> ContenuFichier {
        guard let contenu = try? JSONDecoder().decode(FichierConnexion.self, from: donnees) else {
            return .illisible
        }
        guard let brut = nonVide(contenu.fournisseurs?.meta?.jeton?.valeur) else { return .sansJeton }
        guard let jeton = valider(brut) else { return .jetonInadapte }
        return .jeton(jeton)
    }

    /// Le code 44 est le seul qui conclue à l'absence. Le code, jamais la sortie, se
    /// journalise : c'est elle qui porte le secret.
    static func conclure(_ brute: LectureBrute) -> LectureMuse {
        var empechee = brute.interrompue
        for resultat in brute.resultats {
            switch classer(resultat) {
            case .jeton(let jeton): return .jeton(jeton)
            case .empechee:
                Journal.donnees.notice("Muse : lecture du Trousseau sans jeton exploitable (code \(resultat.code))")
                empechee = true
            case .absent: continue
            }
        }
        return empechee ? .empechee : .absent
    }

    static func classer(_ resultat: ResultatProcessus) -> LectureMuse {
        guard resultat.reussi else {
            return resultat.code == Trousseau.codeAbsent ? .absent : .empechee
        }
        guard let element = try? JSONDecoder().decode(ElementTrousseau.self, from: Data(resultat.sortie.utf8)),
              let brut = nonVide(element.jeton?.valeur),
              let jeton = valider(brut) else { return .empechee }
        return .jeton(jeton)
    }

    private static func valider(_ brut: String) -> JetonMuse? {
        guard brut.hasPrefix(prefixe), brut.count > prefixe.count,
              !brut.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return JetonMuse(valeur: brut)
    }

    private static func nonVide(_ valeur: String?) -> String? {
        guard let coupe = valeur?.trimmingCharacters(in: .whitespacesAndNewlines), !coupe.isEmpty else {
            return nil
        }
        return coupe
    }

    private struct FichierConnexion: Decodable {
        struct Meta: Decodable {
            var jeton: Souple<String>?
            enum CodingKeys: String, CodingKey { case jeton = "access_token" }
        }
        struct Fournisseurs: Decodable {
            var meta: Meta?
        }
        var fournisseurs: Fournisseurs?
        enum CodingKeys: String, CodingKey { case fournisseurs = "providers" }
    }

    private struct ElementTrousseau: Decodable {
        var jeton: Souple<String>?
        enum CodingKeys: String, CodingKey { case jeton = "access_token" }
    }
}

/// La porte qui espace les envois. Partagée par tous les appels d'une même app : c'est elle,
/// et non l'appelant, qui décide qu'un rafraîchissement du panneau n'envoie rien.
///
/// ⚠️ Un envoi se compte **avant** de partir, réponse ou non : une requête dont on n'a pas
/// lu la réponse a pu créer sa clé chez Meta.
actor CadenceMuse {
    /// ⛔ Chaque envoi crée une clé d'inférence chez Meta (décision produit du 2026-10-03,
    /// prise en connaissance de cause). Quinze minutes bornent cette création à 96 clés par
    /// jour au pire, trois fois moins que la cadence ordinaire des lecteurs (5 min), et
    /// laissent vingt mesures dans une fenêtre de 5 h — assez pour la lire.
    static let intervalleMinimal: TimeInterval = 15 * 60

    private var dernierEnvoi: Date?
    private let memoriser: @Sendable (Date) -> Void

    /// `dernierEnvoi` et `memoriser` permettent à l'appelant de faire survivre la porte à un
    /// redémarrage : sans eux, chaque relance de l'app enverrait une requête de plus.
    init(dernierEnvoi: Date?, memoriser: @escaping @Sendable (Date) -> Void) {
        self.dernierEnvoi = dernierEnvoi
        self.memoriser = memoriser
    }

    /// `nil` quand un envoi est permis maintenant ; sinon, l'instant à partir duquel il le sera.
    func prochainEnvoi(maintenant: Date) -> Date? {
        guard var dernier = dernierEnvoi else { return nil }
        // Un dernier envoi dans le futur — horloge reculée, valeur gardée corrompue — se
        // ramène à maintenant : il coûte un intervalle d'attente, jamais un blocage durable.
        if dernier > maintenant {
            dernier = maintenant
            dernierEnvoi = maintenant
            memoriser(maintenant)
        }
        let suivant = dernier.addingTimeInterval(Self.intervalleMinimal)
        return suivant > maintenant ? suivant : nil
    }

    /// Réserve l'envoi s'il est permis. Atomique : deux appels simultanés n'envoient pas deux
    /// requêtes. Rend `nil` quand la réservation est faite.
    func reserver(maintenant: Date) -> Date? {
        if let suivant = prochainEnvoi(maintenant: maintenant) { return suivant }
        dernierEnvoi = maintenant
        memoriser(maintenant)
        return nil
    }
}

/// Ce qu'un relevé de Muse Code établit. Un compte par machine : celui de `muse login`.
struct MesureMuse: Sendable, Equatable {
    var quota: Quota
    var mesureA: Date
    /// `user_email`, tel que publié.
    var courriel: String?
    /// `subs_tier_name`, tel que publié.
    var formule: String?
}

enum ReleveMuse: Sendable, Equatable {
    /// ⚠️ Un abonnement actif peut ne publier **aucune** fenêtre : Meta omet `subs_usage`
    /// tant que la 5 h est inactive, même si la semaine est entamée. Le quota est alors
    /// vide — ni 5 h à zéro, ni semaine inventée.
    case releve(MesureMuse)
    /// La connexion est refusée (401, 403) : elle se refait par `muse login`.
    case reconnexionNecessaire
    /// Aucun abonnement actif sur cette connexion : rien à jauger, et pas de barre à zéro.
    case sansAbonnement
    /// L'abonnement attend un moyen de paiement.
    case paiementRequis
    /// ⛔ Rien n'est parti : la porte de `CadenceMuse` est fermée jusqu'à cette date. La
    /// mesure précédente reste la meilleure connue — l'effacer serait conclure sans avoir
    /// regardé.
    case differe(jusqua: Date)
    /// L'appel n'a rien établi — réseau, statut inattendu (429 et 5xx compris), corps illisible.
    case indetermine
    /// Aucune connexion Muse sur cette machine.
    case aucun
}

/// Relevé du quota de Muse Code (Meta) par `POST /muse-code/key`.
///
/// ⛔ **Cette route crée une clé d'inférence chez Meta à chaque appel** : c'est la réponse de
/// création qui porte le quota. Admise par décision produit du 2026-10-03, sous trois
/// conditions tenues ici : un envoi au plus par `CadenceMuse.intervalleMinimal` ; la clé
/// créée n'est jamais décodée, ni gardée, ni journalisée, et le corps qui la porte est
/// effacé dès la mesure lue ; aucune autre requête vers Meta, ni pour la révoquer, ni
/// pour la réutiliser.
enum QuotaMuse {
    static let hote = "api.meta.ai"
    static let adresse = "https://api.meta.ai/muse-code/key"
    static let agent = "Quotum"
    static let versionAPI = "1.0.0"

    /// La phrase de tête du suivi de cet outil, à poser au catalogue par l'intégration.
    static let phraseRisque = "Au plus toutes les 15 minutes, chaque mesure crée sur votre compte Meta une clé que Quotum n'utilise pas et ne garde pas."

    static func relever(cadence: CadenceMuse, dependances: DependancesMuse) async -> ReleveMuse {
        // La porte d'abord : fermée, ni le fichier ni le Trousseau ne sont ouverts.
        if let suivant = await cadence.prochainEnvoi(maintenant: dependances.horloge()) {
            return .differe(jusqua: suivant)
        }
        let jeton: JetonMuse
        switch await IdentifiantsMuse.jeton(dependances) {
        case .jeton(let lu): jeton = lu
        case .absent: return .aucun
        case .empechee: return .indetermine
        }
        if let suivant = await cadence.reserver(maintenant: dependances.horloge()) {
            return .differe(jusqua: suivant)
        }
        let reponse = await charger(jeton: jeton, session: dependances.session, delai: dependances.delai,
                                    mesureA: dependances.horloge())
        return conclure(reponse)
    }

    /// Ce qu'un envoi a rapporté. La mesure y est déjà décodée : le corps brut, qui porte la
    /// clé créée, ne sort jamais de `charger`.
    enum ReponseAPI: Sendable, Equatable {
        case lue(Lecture)
        case jetonRefuse
        case echec
    }

    enum Lecture: Sendable, Equatable {
        case mesure(MesureMuse)
        case sansAbonnement
        case paiementRequis
        case illisible
    }

    static func conclure(_ reponse: ReponseAPI) -> ReleveMuse {
        switch reponse {
        case .jetonRefuse: .reconnexionNecessaire
        case .echec: .indetermine
        case .lue(.mesure(let mesure)): .releve(mesure)
        case .lue(.sansAbonnement): .sansAbonnement
        case .lue(.paiementRequis): .paiementRequis
        case .lue(.illisible): .indetermine
        }
    }

    /// ⚠️ L'`Authorization` se pose **sur la requête**, jamais dans la configuration de
    /// session : CFNetwork rejoue celle-ci sur la cible d'une redirection, autre hôte compris.
    static func requete(jeton: JetonMuse, delai: TimeInterval) -> URLRequest? {
        guard let url = URL(string: adresse) else { return nil }
        var requete = URLRequest(url: url)
        requete.httpMethod = "POST"
        requete.timeoutInterval = delai
        requete.httpBody = Data("{}".utf8)
        requete.setValue("Bearer \(jeton.valeur)", forHTTPHeaderField: "Authorization")
        requete.setValue("application/json", forHTTPHeaderField: "Content-Type")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue(versionAPI, forHTTPHeaderField: "x-api-version")
        requete.setValue(agent, forHTTPHeaderField: "User-Agent")
        return requete
    }

    private static func charger(jeton: JetonMuse,
                                session: URLSession,
                                delai: TimeInterval,
                                mesureA: Date) async -> ReponseAPI {
        guard let requete = requete(jeton: jeton, delai: delai) else { return .echec }
        do {
            // Le corps porte la clé créée : il est remis à zéro dès la mesure lue, et ne
            // quitte pas cette fonction. Aucune copie n'en est faite avant, sans quoi la
            // remise à zéro porterait sur la copie et laisserait l'original intact.
            var donnees: Data
            let reponse: URLResponse
            (donnees, reponse) = try await session.data(for: requete,
                                                        delegate: RedirectionMemeHoteSeulement(hote: hote))
            defer { donnees.resetBytes(in: 0..<donnees.count) }
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            if code != 200 { Journal.donnees.notice("Quota Muse : statut HTTP \(code)") }
            switch code {
            case 200: return .lue(decoder(donnees, mesureA: mesureA))
            case 401, 403: return .jetonRefuse
            default: return .echec
            }
        } catch {
            Journal.donnees.debug("Quota Muse : api.meta.ai injoignable")
            return .echec
        }
    }

    // MARK: - Analyses pures

    /// ⛔ `api_key` (la clé créée) et `payment_method` ne sont **pas déclarés** : le décodeur
    /// ne les lit pas, et aucune chaîne n'en naît de notre côté.
    private struct Reponse: Decodable {
        var paiementRequis: Drapeau
        var abonnementActif: Drapeau
        var formule: Souple<String>?
        var courriel: Souple<String>?
        var usage: Usage?
        var usagePresent = false
        var usageNul = false

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            paiementRequis = Drapeau.lire(c, .paiementRequis)
            abonnementActif = Drapeau.lire(c, .abonnementActif)
            formule = try? c.decodeIfPresent(Souple<String>.self, forKey: .formule)
            courriel = try? c.decodeIfPresent(Souple<String>.self, forKey: .courriel)
            usagePresent = c.contains(.usage)
            usageNul = (try? c.decodeNil(forKey: .usage)) == true
            usage = try? c.decode(Usage.self, forKey: .usage)
        }

        enum CodingKeys: String, CodingKey {
            case paiementRequis = "require_payment"
            case abonnementActif = "is_subs_active"
            case formule = "subs_tier_name"
            case courriel = "user_email"
            case usage = "subs_usage"
        }
    }

    /// Un drapeau absent ou nul ne dit rien ; présent mais d'un autre type, il rend la
    /// réponse illisible.
    private enum Drapeau {
        case absent
        case valeur(Bool)
        case illisible

        static func lire(_ c: KeyedDecodingContainer<Reponse.CodingKeys>, _ cle: Reponse.CodingKeys) -> Drapeau {
            guard c.contains(cle), (try? c.decodeNil(forKey: cle)) != true else { return .absent }
            guard let valeur = try? c.decode(Bool.self, forKey: cle) else { return .illisible }
            return .valeur(valeur)
        }
    }

    private struct Usage: Decodable {
        var courte: Souple<FenetreLue>?
        var semaine: Souple<FenetreLue>?
        enum CodingKeys: String, CodingKey {
            case courte = "window"
            case semaine = "weekly"
        }
    }

    /// Chaque champ se lit seul : un champ illisible ne fait pas tomber ses voisins.
    private struct FenetreLue: Decodable {
        var utilisation: Double?
        var minutes: Double?
        var recharge: Double?

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            utilisation = Self.fini(c, .utilisation)
            minutes = Self.fini(c, .minutes)
            recharge = Self.fini(c, .recharge)
        }

        private static func fini(_ c: KeyedDecodingContainer<CodingKeys>, _ cle: CodingKeys) -> Double? {
            guard let nombre = try? c.decode(Double.self, forKey: cle), nombre.isFinite else { return nil }
            return nombre
        }

        enum CodingKeys: String, CodingKey {
            case utilisation = "used_percent"
            case minutes = "window_duration_mins"
            case recharge = "resets_at"
        }
    }

    static func decoder(_ donnees: Data, mesureA: Date) -> Lecture {
        guard let reponse = try? JSONDecoder().decode(Reponse.self, from: donnees) else { return .illisible }
        // Un drapeau présent mais d'un autre type ne dit rien : la réponse n'est plus celle
        // qu'on sait lire.
        if case .illisible = reponse.paiementRequis { return .illisible }
        if case .illisible = reponse.abonnementActif { return .illisible }
        if case .valeur(true) = reponse.paiementRequis { return .paiementRequis }
        guard case .valeur(true) = reponse.abonnementActif else { return .sansAbonnement }

        var mesure = MesureMuse(quota: Quota([]),
                                mesureA: mesureA,
                                courriel: nonVide(reponse.courriel?.valeur),
                                formule: nonVide(reponse.formule?.valeur))
        guard reponse.usagePresent, !reponse.usageNul else { return .mesure(mesure) }
        // Présent, ni nul ni objet : la réponse se contredit, rien n'est établi.
        guard let usage = reponse.usage else { return .illisible }

        var fenetres: [Fenetre] = []
        if let lue = usage.courte?.valeur, let fenetre = fenetreCourte(lue) { fenetres.append(fenetre) }
        if let lue = usage.semaine?.valeur, let utilisation = lue.utilisation,
           let fenetre = Fenetre.septJours(utilisation: utilisation,
                                           seRechargeA: lue.recharge.flatMap(Horodatage.analyser(epoch:)),
                                           duree: 604_800) {
            fenetres.append(fenetre)
        }
        mesure.quota = Quota(fenetres)
        return .mesure(mesure)
    }

    /// La durée se lit dans `window_duration_mins`. 300 est la 5 h, 1 440 la 24 h ; une autre
    /// valeur garde sa durée sous une sorte inconnue plutôt que d'être rangée à tort.
    private static func fenetreCourte(_ lue: FenetreLue) -> Fenetre? {
        guard let utilisation = lue.utilisation else { return nil }
        let recharge = lue.recharge.flatMap(Horodatage.analyser(epoch:))
        guard let minutes = lue.minutes, minutes > 0 else {
            return Fenetre.cinqHeures(utilisation: utilisation, seRechargeA: recharge)
        }
        let duree = minutes * 60
        switch minutes {
        case 300: return Fenetre.cinqHeures(utilisation: utilisation, seRechargeA: recharge, duree: duree)
        case 1_440:
            return Fenetre(libelle: Fenetre.libelleVingtQuatreHeures, sorte: .vingtQuatreHeures,
                           utilisation: utilisation, seRechargeA: recharge, duree: duree)
        default:
            return Fenetre(libelle: "window", sorte: .inconnue,
                           utilisation: utilisation, seRechargeA: recharge, duree: duree)
        }
    }

    private static func nonVide(_ valeur: String?) -> String? {
        guard let coupe = valeur?.trimmingCharacters(in: .whitespacesAndNewlines), !coupe.isEmpty else {
            return nil
        }
        return coupe
    }
}
