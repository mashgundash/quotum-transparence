import Foundation

/// Ce que la garde de saisie Azure refuse, avant tout appel.
enum RefusSaisieAzure: Error, Sendable, Equatable {
    case tenantInvalide
    case clientInvalide
    case secretVide
    case secretInvalide
    case abonnementInvalide
    case budgetInvalide
}

/// Le secret d'un principal de service. ⛔ Sa description ne montre jamais la valeur.
struct SecretAzure: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let valeur: String

    fileprivate init(valeur: String) { self.valeur = valeur }

    var description: String { "secret Azure…" }
    var debugDescription: String { description }

    /// ⛔ Relu au Trousseau, il repasse par la garde de saisie.
    static func decoder(_ donnees: Data) -> SecretAzure? {
        guard let texte = String(data: donnees, encoding: .utf8),
              case .success(let secret) = DepenseAzure.valider(secret: texte) else { return nil }
        return secret
    }
}

/// Un jeton d'accès d'Entra ID, gardé en mémoire le temps d'un relevé. ⛔ Jamais écrit, jamais
/// journalisé.
struct JetonAzure: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let valeur: String

    var description: String { "jeton Azure…" }
    var debugDescription: String { description }
}

/// Ce qui accompagne le secret au Trousseau, sans être secret.
struct EnregistrementAzure: Codable, Sendable, Equatable {
    static let versionCourante = 1

    let version: Int
    let tenant: String
    let client: String
    let abonnement: String
    let budget: String

    init(tenant: String, client: String, abonnement: String, budget: String) {
        version = Self.versionCourante
        self.tenant = tenant
        self.client = client
        self.abonnement = abonnement
        self.budget = budget
    }

    func encoder() -> Data? {
        let encodeur = JSONEncoder()
        encodeur.outputFormatting = .sortedKeys
        return try? encodeur.encode(self)
    }

    /// ⛔ Un attribut retouché ne fait pas d'enregistrement : chacun de ces champs finit dans
    /// une adresse.
    static func decoder(_ donnees: Data) -> EnregistrementAzure? {
        guard let lu = try? JSONDecoder().decode(EnregistrementAzure.self, from: donnees),
              lu.version == versionCourante,
              DepenseAzure.estGUID(lu.tenant), DepenseAzure.estGUID(lu.client), DepenseAzure.estGUID(lu.abonnement),
              DepenseAzure.estNomDeBudget(lu.budget)
        else { return nil }
        return lu
    }
}

/// La dépense d'un budget de consommation Azure, lue par un principal de service.
///
/// Trois appels : un jeton client-credentials pour `management.azure.com`, puis **la liste de
/// ses propres permissions sur l'abonnement** — toute action ou action de données qui n'est
/// pas une lecture fait refuser le principal, sans autre requête —, puis les budgets. Le
/// contrôle a lieu à l'ajout **et à chaque relevé** : un principal qui gagne un rôle
/// d'écriture cesse d'être lu.
enum DepenseAzure {
    static let racineJeton = "https://login.microsoftonline.com"
    static let racineGestion = "https://management.azure.com"
    /// L'hôte de `racineGestion`, auquel une page suivante doit appartenir.
    static let hoteGestion = "management.azure.com"
    static let portee = "https://management.azure.com/.default"
    static let versionPermissions = "2022-04-01"
    static let versionBudgets = "2023-05-01"
    static let pagesMaximales = 10
    static let longueurSecretMaximale = 256
    static let longueurSecretMinimale = 16

    // MARK: - Garde de saisie

    static func estGUID(_ texte: String) -> Bool {
        guard texte.utf8.count == 36 else { return false }
        for (rang, scalaire) in texte.unicodeScalars.enumerated() {
            if [8, 13, 18, 23].contains(rang) {
                guard scalaire == "-" else { return false }
            } else {
                guard ("0"..."9").contains(scalaire) || ("a"..."f").contains(scalaire) || ("A"..."F").contains(scalaire)
                else { return false }
            }
        }
        return true
    }

    static func valider(secret brut: String) -> Result<SecretAzure, RefusSaisieAzure> {
        let secret = brut.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return .failure(.secretVide) }
        // Les secrets d'Entra ID sont en ASCII imprimable, sans espace.
        guard (longueurSecretMinimale...longueurSecretMaximale).contains(secret.utf8.count),
              secret.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F })
        else { return .failure(.secretInvalide) }
        return .success(SecretAzure(valeur: secret))
    }

    struct Saisie: Sendable, Equatable {
        let tenant: String
        let client: String
        let secret: SecretAzure
        let abonnement: String
        let budget: String?
    }

    static func valider(tenant: String, client: String, secret: String, abonnement: String,
                        budget: String) -> Result<Saisie, RefusSaisieAzure> {
        let nettoyer = { (texte: String) in texte.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let (tenant, client, abonnement) = (nettoyer(tenant), nettoyer(client), nettoyer(abonnement))
        guard estGUID(tenant) else { return .failure(.tenantInvalide) }
        guard estGUID(client) else { return .failure(.clientInvalide) }
        let lu: SecretAzure
        switch valider(secret: secret) {
        case .success(let valide): lu = valide
        case .failure(let refus): return .failure(refus)
        }
        guard estGUID(abonnement) else { return .failure(.abonnementInvalide) }
        let nom = budget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nom.isEmpty || estNomDeBudget(nom) else { return .failure(.budgetInvalide) }
        return .success(Saisie(tenant: tenant, client: client, secret: lu, abonnement: abonnement,
                               budget: nom.isEmpty ? nil : nom))
    }

    /// Azure : lettres, chiffres, `-` et `_`, soixante-trois au plus.
    static func estNomDeBudget(_ texte: String) -> Bool {
        (1...63).contains(texte.utf8.count) && texte.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
        }
    }

    // MARK: - Requêtes

    static func requeteJeton(tenant: String, client: String, secret: SecretAzure, delai: TimeInterval) -> URLRequest? {
        guard estGUID(tenant), estGUID(client),
              let url = URL(string: "\(racineJeton)/\(tenant)/oauth2/v2.0/token") else { return nil }
        let champs = [("client_id", client), ("client_secret", secret.valeur),
                      ("grant_type", "client_credentials"), ("scope", portee)]
        var requete = URLRequest(url: url)
        requete.httpMethod = "POST"
        requete.httpBody = Data(champs.map { "\(SignatureAWS.encoder($0.0))=\(SignatureAWS.encoder($0.1))" }
            .joined(separator: "&").utf8)
        requete.timeoutInterval = delai
        requete.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue("Quotum", forHTTPHeaderField: "User-Agent")
        return requete
    }

    static func adressePermissions(abonnement: String) -> URL? {
        guard estGUID(abonnement) else { return nil }
        return URL(string: "\(racineGestion)/subscriptions/\(abonnement)/providers/"
                   + "Microsoft.Authorization/permissions?api-version=\(versionPermissions)")
    }

    static func adresseBudgets(abonnement: String) -> URL? {
        guard estGUID(abonnement) else { return nil }
        return URL(string: "\(racineGestion)/subscriptions/\(abonnement)/providers/"
                   + "Microsoft.Consumption/budgets?api-version=\(versionBudgets)")
    }

    static func requeteGestion(_ url: URL, jeton: JetonAzure, delai: TimeInterval) -> URLRequest {
        var requete = URLRequest(url: url)
        requete.httpMethod = "GET"
        requete.timeoutInterval = delai
        requete.setValue("Bearer \(jeton.valeur)", forHTTPHeaderField: "Authorization")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue("Quotum", forHTTPHeaderField: "User-Agent")
        return requete
    }

    /// ⛔ Une page suivante n'est suivie que sur le même hôte, en HTTPS, sous la même route du
    /// même abonnement : le jeton ne part pas où le serveur le dirait.
    static func pageSuivanteAdmise(_ texte: String, route: URL) -> URL? {
        guard texte.utf8.count <= 4_096, let url = URL(string: texte),
              url.scheme == "https", url.host() == hoteGestion, url.port == nil, url.user == nil,
              url.path(percentEncoded: true).lowercased() == route.path(percentEncoded: true).lowercased()
        else { return nil }
        return url
    }

    // MARK: - Réponses

    enum ReponseJeton: Sendable, Equatable {
        case jeton(JetonAzure)
        case echec(EchecBudget)
    }

    static func interpreterJeton(code: Int, donnees: Data) -> ReponseJeton {
        switch code {
        case 200:
            guard let objet = try? JSONSerialization.jsonObject(with: donnees) as? [String: Any],
                  (objet["token_type"] as? String)?.lowercased() == "bearer",
                  let valeur = objet["access_token"] as? String, estJeton(valeur)
            else { return .echec(.indetermine) }
            return .jeton(JetonAzure(valeur: valeur))
        // Entra ID rend 400 (`invalid_client`, `unauthorized_client`, tenant inconnu) ou 401
        // pour des identifiants qu'il refuse.
        case 400, 401: return .echec(.identiteRefusee)
        default: return .echec(.indetermine)
        }
    }

    /// Un JWT : trois segments en base64url, borné. Il part dans un en-tête : aucun caractère
    /// qui puisse en ouvrir un autre.
    static func estJeton(_ texte: String) -> Bool {
        !texte.isEmpty && texte.utf8.count <= 16_384 && texte.split(separator: ".").count == 3
            && texte.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                    || $0 == "-" || $0 == "_" || $0 == "."
            }
    }

    struct PagePermissions: Sendable, Equatable {
        /// Toutes les actions et actions de données de la page, telles que publiées.
        let actions: [String]
        let suivante: String?
    }

    enum ReponsePermissions: Sendable, Equatable {
        case page(PagePermissions)
        case echec(EchecBudget)
    }

    static func interpreterPermissions(code: Int, donnees: Data) -> ReponsePermissions {
        switch code {
        case 200:
            guard let objet = try? JSONSerialization.jsonObject(with: donnees) as? [String: Any],
                  let valeurs = objet["value"] as? [Any]
            else { return .echec(.indetermine) }
            var actions: [String] = []
            for valeur in valeurs {
                // ⛔ Une entrée d'une forme inattendue ne se saute pas : on ne conclut pas à la
                // lecture seule sur ce qu'on n'a pas su lire.
                guard let entree = valeur as? [String: Any] else { return .echec(.indetermine) }
                for cle in ["actions", "dataActions"] {
                    guard let liste = entree[cle] else { continue }
                    guard let textes = liste as? [String] else { return .echec(.indetermine) }
                    actions += textes
                }
            }
            let suivante = objet["nextLink"] as? String
            if objet["nextLink"] != nil, !(objet["nextLink"] is NSNull), suivante == nil { return .echec(.indetermine) }
            return .page(PagePermissions(actions: actions, suivante: suivante))
        case 401: return .echec(.identiteRefusee)
        // 403 : aucun rôle sur l'abonnement ; 404 : abonnement inconnu de ce principal.
        case 403, 404: return .echec(.lectureRefusee)
        default: return .echec(.indetermine)
        }
    }

    /// ⛔ Fermé par défaut : seule une action qui finit par `/read` est une lecture. `*`,
    /// `Microsoft.Support/*` — que porte le rôle « Cost Management Reader » —, toute écriture,
    /// suppression ou action `…/action`, et toute action de données qui n'est pas une
    /// lecture (l'inférence d'Azure OpenAI en est une) font refuser le principal. Les
    /// `notActions` ne retirent rien de ce jugement : on ne les lit pas.
    static func lectureSeule(_ actions: [String]) -> Bool {
        actions.allSatisfy { action in
            action.lowercased().hasSuffix("/read")
                && !action.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0) })
        }
    }

    struct Budget: Sendable, Equatable {
        let nom: String
        let usage: UsagePayant?
        let deCout: Bool
    }

    struct PageBudgets: Sendable, Equatable {
        let budgets: [Budget]
        let suivante: String?
    }

    enum ReponseBudgets: Sendable, Equatable {
        case page(PageBudgets)
        case echec(EchecBudget)
    }

    static func interpreterBudgets(code: Int, donnees: Data, mesureA: Date) -> ReponseBudgets {
        switch code {
        case 200: decoderBudgets(donnees, mesureA: mesureA).map(ReponseBudgets.page) ?? .echec(.indetermine)
        case 401: .echec(.identiteRefusee)
        case 403, 404: .echec(.lectureRefusee)
        default: .echec(.indetermine)
        }
    }

    private struct ReponseBrute: Decodable {
        let valeurs: [Tolerant]
        let suivante: String?

        enum CodingKeys: String, CodingKey {
            case valeurs = "value"
            case suivante = "nextLink"
        }
    }

    private struct Tolerant: Decodable {
        let budget: BudgetBrut?
        init(from decodeur: Decoder) throws { budget = try? BudgetBrut(from: decodeur) }
    }

    private struct BudgetBrut: Decodable {
        struct Proprietes: Decodable {
            struct Somme: Decodable {
                let montant: Decimal?
                let unite: String?
                enum CodingKeys: String, CodingKey {
                    case montant = "amount"
                    case unite = "unit"
                }
            }

            struct Periode: Decodable {
                let debut: Horodatage?
                let fin: Horodatage?
                enum CodingKeys: String, CodingKey {
                    case debut = "startDate"
                    case fin = "endDate"
                }
            }

            let categorie: String?
            let plafond: Decimal?
            let grain: String?
            let periode: Periode?
            let depense: Somme?
            let filtre: ValeurJSON?

            enum CodingKeys: String, CodingKey {
                case categorie = "category"
                case plafond = "amount"
                case grain = "timeGrain"
                case periode = "timePeriod"
                case depense = "currentSpend"
                case filtre = "filter"
            }
        }

        let nom: String
        let proprietes: Proprietes?

        enum CodingKeys: String, CodingKey {
            case nom = "name"
            case proprietes = "properties"
        }
    }

    static func decoderBudgets(_ donnees: Data, mesureA: Date) -> PageBudgets? {
        guard let brute = try? JSONDecoder().decode(ReponseBrute.self, from: donnees) else { return nil }
        let budgets = brute.valeurs.compactMap(\.budget).compactMap { budget -> Budget? in
            guard estNomDeBudget(budget.nom) else { return nil }
            let deCout = budget.proprietes?.categorie?.lowercased() == "cost"
            return Budget(nom: budget.nom,
                          usage: deCout ? budget.proprietes.flatMap { usage($0, mesureA: mesureA) } : nil,
                          deCout: deCout)
        }
        return PageBudgets(budgets: budgets, suivante: brute.suivante)
    }

    private static func usage(_ proprietes: BudgetBrut.Proprietes, mesureA: Date) -> UsagePayant? {
        // La devise n'est publiée que sur la dépense : sans elle, aucun montant ne se dit.
        guard let depense = proprietes.depense, let code = depense.unite?.uppercased(),
              let brut = depense.montant, let consomme = LectureBudget.montant(brut, code: code)
        else { return nil }
        var plafond: Montant?
        if let publie = proprietes.plafond {
            guard let lu = LectureBudget.montant(publie, code: code), lu.unitesMineures >= 0 else { return nil }
            plafond = lu
        }
        let debut = proprietes.periode?.debut?.date
        let (periode, echeance): (PeriodeDepense, Date?) = switch proprietes.grain?.lowercased() {
        case "monthly": (.mois, LectureBudget.prochaineRemise(debut: debut, mois: 1, apres: mesureA)
                                 ?? LectureBudget.moisSuivant(apres: mesureA))
        case "quarterly": (.trimestre, LectureBudget.prochaineRemise(debut: debut, mois: 3, apres: mesureA))
        case "annually": (.annee, LectureBudget.prochaineRemise(debut: debut, mois: 12, apres: mesureA))
        // Les grains « de facturation » suivent le cycle de facture, dont la date n'est pas
        // publiée ici : la période se dit, l'échéance non.
        case "billingmonth": (.mois, nil)
        case "billingquarter": (.trimestre, nil)
        case "billingannual": (.annee, nil)
        default: (.personnalisee, nil)
        }
        return LectureBudget.usage(consomme: consomme, plafond: plafond, code: code, periode: periode,
                                   echeance: echeance, mesureA: mesureA,
                                   perimetre: perimetre(proprietes.filtre))
    }

    // MARK: - Périmètre

    /// Azure OpenAI n'a pas de service à lui dans les coûts : il se range sous Cognitive
    /// Services, et seule sa sous-catégorie de compteur le désigne — « Azure OpenAI »,
    /// « Azure OpenAI Reservation », écrite aussi « Azure Open AI ».
    static func estSousCategorieOpenAI(_ texte: String) -> Bool {
        texte.lowercased().filter { !$0.isWhitespace }.hasPrefix("azureopenai")
    }

    /// ⛔ Fermé par défaut : sans filtre, le budget couvre l'abonnement entier ; d'une forme
    /// inconnue, il n'est prouvé ni limité à Azure OpenAI, ni plus large.
    static func perimetre(_ filtre: ValeurJSON?) -> PerimetreDepense {
        guard !ValeurJSON.vide(filtre), let filtre else { return PreuvePerimetre.perimetre([]) }
        return PreuvePerimetre.perimetre([preuveFiltre(filtre)])
    }

    /// Un seul terme, ou un « et » de termes : limité dès qu'un terme l'est.
    static func preuveFiltre(_ valeur: ValeurJSON) -> PreuvePerimetre {
        guard case .objet(let filtre) = valeur, filtre.count == 1, let (cle, contenu) = filtre.first else {
            return .illisible
        }
        guard cle == "and" else { return preuveTerme(valeur) }
        guard case .liste(let termes) = contenu, !termes.isEmpty else { return .illisible }
        let preuves = termes.map(preuveTerme)
        if preuves.contains(.illisible) { return .illisible }
        return preuves.contains(.limiteAuService) ? .limiteAuService : .elargi
    }

    /// `dimensions` ou `tags`, exactement l'un des deux, et une comparaison complète. L'API ne
    /// connaît que l'opérateur `In` : tout autre est une forme inconnue.
    private static func preuveTerme(_ valeur: ValeurJSON) -> PreuvePerimetre {
        guard case .objet(let terme) = valeur, terme.count == 1, let (cle, contenu) = terme.first,
              case .objet(let comparaison) = contenu,
              Set(comparaison.keys).isSubset(of: ["name", "operator", "values"]),
              case .texte(let nom)? = comparaison["name"], case .texte(let operateur)? = comparaison["operator"],
              let valeurs = comparaison["values"]?.textes
        else { return .illisible }
        guard operateur.caseInsensitiveCompare("In") == .orderedSame else { return .illisible }
        switch cle {
        case "dimensions":
            guard nom.caseInsensitiveCompare("MeterSubCategory") == .orderedSame,
                  !valeurs.isEmpty, valeurs.allSatisfy(estSousCategorieOpenAI) else { return .elargi }
            return .limiteAuService
        case "tags":
            return .elargi
        default:
            return .illisible
        }
    }

    // MARK: - Appels

    private static func charger(_ requete: URLRequest, session: URLSession) async -> (Int, Data)? {
        do {
            let (donnees, reponse) = try await session.data(for: requete,
                                                            delegate: QuotaWindsurf.RefusDeRedirection())
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            if code != 200 {
                // Le statut seul : ni le secret, ni le jeton, ni le corps.
                Journal.donnees.notice("Dépense Azure : statut HTTP \(code)")
            }
            return (code, donnees)
        } catch {
            Journal.donnees.debug("Dépense Azure : service injoignable")
            return nil
        }
    }

    static func jeton(tenant: String, client: String, secret: SecretAzure, session: URLSession,
                      delai: TimeInterval) async -> Result<JetonAzure, EchecBudget> {
        guard let requete = requeteJeton(tenant: tenant, client: client, secret: secret, delai: delai),
              let (code, donnees) = await charger(requete, session: session)
        else { return .failure(.indetermine) }
        switch interpreterJeton(code: code, donnees: donnees) {
        case .jeton(let jeton): return .success(jeton)
        case .echec(let echec): return .failure(echec)
        }
    }

    /// `nil` : le principal ne porte que des lectures sur l'abonnement.
    static func verifierPortee(_ jeton: JetonAzure, abonnement: String, session: URLSession,
                               delai: TimeInterval) async -> EchecBudget? {
        guard let route = adressePermissions(abonnement: abonnement) else { return .indetermine }
        var adresse = route
        var vues: Set<String> = []
        for _ in 0..<pagesMaximales {
            guard let (code, donnees) = await charger(requeteGestion(adresse, jeton: jeton, delai: delai),
                                                      session: session)
            else { return .indetermine }
            switch interpreterPermissions(code: code, donnees: donnees) {
            case .echec(let echec): return echec
            case .page(let page):
                // Une écriture vue sur une page suffit : inutile de lire les suivantes.
                guard lectureSeule(page.actions) else { return .porteeEcriture }
                guard let suivante = page.suivante else { return nil }
                guard let prochaine = pageSuivanteAdmise(suivante, route: route),
                      vues.insert(prochaine.absoluteString).inserted else { return .indetermine }
                adresse = prochaine
            }
        }
        return .indetermine
    }

    static func budgets(_ jeton: JetonAzure, abonnement: String, session: URLSession,
                        delai: TimeInterval) async -> Result<[Budget], EchecBudget> {
        guard let route = adresseBudgets(abonnement: abonnement) else { return .failure(.indetermine) }
        var adresse = route
        var vues: Set<String> = []
        var tous: [Budget] = []
        for _ in 0..<pagesMaximales {
            let instant = Date()
            guard let (code, donnees) = await charger(requeteGestion(adresse, jeton: jeton, delai: delai),
                                                      session: session)
            else { return .failure(.indetermine) }
            switch interpreterBudgets(code: code, donnees: donnees, mesureA: instant) {
            case .echec(let echec): return .failure(echec)
            case .page(let page):
                tous += page.budgets
                guard let suivante = page.suivante else { return .success(tous) }
                guard let prochaine = pageSuivanteAdmise(suivante, route: route),
                      vues.insert(prochaine.absoluteString).inserted else { return .failure(.indetermine) }
                adresse = prochaine
            }
        }
        return .failure(.indetermine)
    }

    static func choisir(_ budgets: [Budget], nom: String?) -> Result<Budget, EchecBudget> {
        let deCout = budgets.filter(\.deCout)
        if let nom {
            // Azure compare les noms de ressource sans tenir compte de la casse.
            guard let trouve = deCout.first(where: { $0.nom.caseInsensitiveCompare(nom) == .orderedSame })
            else { return .failure(.budgetAbsent) }
            return .success(trouve)
        }
        switch deCout.count {
        case 0: return .failure(.aucunBudget)
        case 1: return .success(deCout[0])
        default: return .failure(.budgetAmbigu)
        }
    }

    /// Jeton, portée, budgets : dans cet ordre, et rien ne part après un refus.
    private static func lire(tenant: String, client: String, secret: SecretAzure, abonnement: String,
                             nom: String?, session: URLSession,
                             delai: TimeInterval) async -> Result<DepenseBudget, EchecBudget> {
        let jeton: JetonAzure
        switch await self.jeton(tenant: tenant, client: client, secret: secret, session: session, delai: delai) {
        case .failure(let echec): return .failure(echec)
        case .success(let lu): jeton = lu
        }
        if let refus = await verifierPortee(jeton, abonnement: abonnement, session: session, delai: delai) {
            return .failure(refus)
        }
        switch await budgets(jeton, abonnement: abonnement, session: session, delai: delai) {
        case .failure(let echec): return .failure(echec)
        case .success(let budgets):
            switch choisir(budgets, nom: nom) {
            case .failure(let echec): return .failure(echec)
            case .success(let budget):
                guard let usage = budget.usage else { return .failure(.illisible) }
                return .success(DepenseBudget(budget: budget.nom, usage: usage))
            }
        }
    }

    static func relever(_ secret: SecretAzure, enregistrement: EnregistrementAzure, session: URLSession,
                        delai: TimeInterval = 8) async -> ReleveBudget {
        switch await lire(tenant: enregistrement.tenant, client: enregistrement.client, secret: secret,
                          abonnement: enregistrement.abonnement, nom: enregistrement.budget,
                          session: session, delai: delai) {
        case .success(let depense): return .mesure(depense)
        case .failure(let echec): return .echec(echec == .aucunBudget ? .budgetAbsent : echec)
        }
    }

    static func resoudre(_ saisie: Saisie, session: URLSession,
                         delai: TimeInterval = 15) async -> Result<(EnregistrementAzure, DepenseBudget), EchecBudget> {
        switch await lire(tenant: saisie.tenant, client: saisie.client, secret: saisie.secret,
                          abonnement: saisie.abonnement, nom: saisie.budget, session: session, delai: delai) {
        case .failure(let echec): return .failure(saisie.budget != nil && echec == .aucunBudget ? .budgetAbsent : echec)
        case .success(let depense):
            return .success((EnregistrementAzure(tenant: saisie.tenant, client: saisie.client,
                                                 abonnement: saisie.abonnement, budget: depense.budget),
                             depense))
        }
    }
}
