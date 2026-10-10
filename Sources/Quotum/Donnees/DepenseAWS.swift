import Foundation

/// Ce que la garde de saisie AWS refuse, avant tout appel.
enum RefusSaisieAWS: Error, Sendable, Equatable {
    case identifiantVide
    /// `ASIA…` : des identifiants temporaires, qui expirent dans l'heure.
    case identifiantsTemporaires
    case identifiantInconnu
    case secretVide
    case secretInvalide
    case regionInconnue
    case budgetInvalide
}

/// Une identité IAM longue durée passée par la garde. ⛔ Sa description ne montre que
/// l'identifiant de clé, jamais le secret.
struct IdentiteAWS: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let identifiant: String
    let secret: SecretAWS

    fileprivate init(identifiant: String, secret: SecretAWS) {
        self.identifiant = identifiant
        self.secret = secret
    }

    var description: String { "\(identifiant) + secret…" }
    var debugDescription: String { description }

    /// Ce que l'élément du Trousseau garde comme secret : les deux moitiés, ensemble.
    func encoder() -> Data? {
        try? JSONEncoder().encode(["identifiant": identifiant, "secret": secret.valeur])
    }

    /// ⛔ Un secret relu au Trousseau repasse par la garde de saisie : un élément retouché ne
    /// fait partir que ce que la saisie aurait accepté.
    static func decoder(_ donnees: Data) -> IdentiteAWS? {
        guard let lu = try? JSONDecoder().decode([String: String].self, from: donnees),
              let identifiant = lu["identifiant"], let secret = lu["secret"],
              case .success(let identite) = DepenseAWS.valider(identifiant: identifiant, secret: secret)
        else { return nil }
        return identite
    }
}

/// Ce qui accompagne l'identité au Trousseau, sans être secret.
struct EnregistrementAWS: Codable, Sendable, Equatable {
    static let versionCourante = 1

    let version: Int
    let region: String
    /// Le compte AWS (12 chiffres) et l'utilisateur IAM, lus par `GetCallerIdentity` à
    /// l'ajout : une identité qui en changerait ensuite n'est plus celle qu'on a admise.
    let compte: String
    let utilisateur: String
    let budget: String

    init(region: String, compte: String, utilisateur: String, budget: String) {
        version = Self.versionCourante
        self.region = region
        self.compte = compte
        self.utilisateur = utilisateur
        self.budget = budget
    }

    func encoder() -> Data? {
        let encodeur = JSONEncoder()
        encodeur.outputFormatting = .sortedKeys
        return try? encodeur.encode(self)
    }

    static func decoder(_ donnees: Data) -> EnregistrementAWS? {
        guard let lu = try? JSONDecoder().decode(EnregistrementAWS.self, from: donnees),
              lu.version == versionCourante,
              DepenseAWS.regions.contains(lu.region),
              DepenseAWS.estCompte(lu.compte),
              DepenseAWS.classer(arn: lu.utilisateur, compte: lu.compte) == .utilisateur,
              DepenseAWS.estNomDeBudget(lu.budget)
        else { return nil }
        return lu
    }
}

/// La dépense d'un budget de coût AWS, lue par une identité IAM de lecture.
///
/// Deux appels, rien d'autre : `sts:GetCallerIdentity`, qui ne demande aucune permission et
/// dit **qui** signe — pour refuser l'utilisateur racine —, puis `budgets:DescribeBudgets`
/// (`budgets:ViewBudget`), gratuit. ⛔ Jamais Cost Explorer : chaque requête y est facturée.
/// Ce qu'aucune route ne permet de vérifier, c'est l'**absence** d'autres permissions sur
/// l'identité : l'interface le dit avant la saisie.
enum DepenseAWS {
    /// Les régions de la partition commerciale `aws`, liste fermée. Ni GovCloud, ni la Chine,
    /// ni le cloud souverain européen : d'autres partitions, d'autres hôtes, d'autres comptes.
    static let regions: [String] = [
        "us-east-1", "us-east-2", "us-west-1", "us-west-2",
        "af-south-1",
        "ap-east-1", "ap-east-2", "ap-south-1", "ap-south-2",
        "ap-southeast-1", "ap-southeast-2", "ap-southeast-3", "ap-southeast-4", "ap-southeast-5",
        "ap-southeast-6", "ap-southeast-7",
        "ap-northeast-1", "ap-northeast-2", "ap-northeast-3",
        "ca-central-1", "ca-west-1",
        "eu-central-1", "eu-central-2", "eu-west-1", "eu-west-2", "eu-west-3",
        "eu-south-1", "eu-south-2", "eu-north-1",
        "il-central-1", "me-south-1", "me-central-1", "mx-central-1",
        "sa-east-1",
    ]
    static let adresseBudgets = "https://budgets.amazonaws.com/"
    /// AWS Budgets est un service global, signé pour `us-east-1`.
    static let regionBudgets = "us-east-1"
    static let cibleDescribeBudgets = "AWSBudgetServiceGateway.DescribeBudgets"
    static let corpsIdentite = "Action=GetCallerIdentity&Version=2011-06-15"
    static let budgetsParPage = 100
    static let pagesMaximales = 10

    static func adresseSTS(_ region: String) -> String { "https://sts.\(region).amazonaws.com/" }

    // MARK: - Garde de saisie

    static func valider(identifiant brut: String, secret brutSecret: String) -> Result<IdentiteAWS, RefusSaisieAWS> {
        let identifiant = brut.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifiant.isEmpty else { return .failure(.identifiantVide) }
        if identifiant.hasPrefix("ASIA") { return .failure(.identifiantsTemporaires) }
        guard identifiant.utf8.count == 20, identifiant.hasPrefix("AKIA"),
              identifiant.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) })
        else { return .failure(.identifiantInconnu) }
        let secret = brutSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return .failure(.secretVide) }
        guard secret.utf8.count == 40,
              secret.unicodeScalars.allSatisfy({
                  ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "/" || $0 == "+"
              })
        else { return .failure(.secretInvalide) }
        return .success(IdentiteAWS(identifiant: identifiant, secret: SecretAWS(valeur: secret)))
    }

    static func valider(region brute: String) -> Result<String, RefusSaisieAWS> {
        let region = brute.trimmingCharacters(in: .whitespacesAndNewlines)
        return regions.contains(region) ? .success(region) : .failure(.regionInconnue)
    }

    /// Vide : le seul budget de coût du compte, s'il n'y en a qu'un.
    static func valider(budget brut: String) -> Result<String?, RefusSaisieAWS> {
        let budget = brut.trimmingCharacters(in: .whitespacesAndNewlines)
        if budget.isEmpty { return .success(nil) }
        return estNomDeBudget(budget) ? .success(budget) : .failure(.budgetInvalide)
    }

    /// AWS refuse `:` et `\` dans un nom de budget ; cent caractères au plus.
    static func estNomDeBudget(_ texte: String) -> Bool {
        LectureBudget.nomLisible(texte) && !texte.contains(":") && !texte.contains("\\")
    }

    static func estCompte(_ texte: String) -> Bool {
        texte.utf8.count == 12 && texte.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    // MARK: - Qui signe

    enum SorteArn: Sendable, Equatable {
        case utilisateur
        case racine
        case autre
    }

    /// Seul un utilisateur IAM de la partition commerciale, sur le compte annoncé, est admis.
    /// Un rôle assumé ou un utilisateur fédéré viendraient d'identifiants temporaires.
    static func classer(arn: String, compte: String) -> SorteArn {
        let parties = arn.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        guard parties.count == 6, parties[0] == "arn", parties[1] == "aws", parties[3].isEmpty,
              String(parties[4]) == compte, estCompte(compte),
              !arn.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0)
                  || CharacterSet.whitespacesAndNewlines.contains($0) })
        else { return .autre }
        let ressource = parties[5]
        if parties[2] == "iam", ressource == "root" { return .racine }
        guard parties[2] == "iam", ressource.hasPrefix("user/"), ressource.count > "user/".count else { return .autre }
        return .utilisateur
    }

    // MARK: - Requêtes

    static func requeteIdentite(_ identite: IdentiteAWS, region: String, instant: Date, delai: TimeInterval) -> URLRequest? {
        guard regions.contains(region), let url = URL(string: adresseSTS(region)) else { return nil }
        let corps = Data(corpsIdentite.utf8)
        let signes = ["content-type": "application/x-www-form-urlencoded; charset=utf-8"]
        return requete(url: url, corps: corps, signes: signes, accepte: "text/xml",
                       identite: identite, region: region, service: "sts", instant: instant, delai: delai)
    }

    static func requeteBudgets(_ identite: IdentiteAWS, compte: String, suivant: String?,
                               instant: Date, delai: TimeInterval) -> URLRequest? {
        guard estCompte(compte), let url = URL(string: adresseBudgets) else { return nil }
        var objet: [String: Any] = ["AccountId": compte, "MaxResults": budgetsParPage]
        if let suivant {
            guard estJetonDePage(suivant) else { return nil }
            objet["NextToken"] = suivant
        }
        guard let corps = try? JSONSerialization.data(withJSONObject: objet, options: [.sortedKeys]) else { return nil }
        let signes = ["content-type": "application/x-amz-json-1.1", "x-amz-target": cibleDescribeBudgets]
        return requete(url: url, corps: corps, signes: signes, accepte: "application/json",
                       identite: identite, region: regionBudgets, service: "budgets", instant: instant, delai: delai)
    }

    private static func requete(url: URL, corps: Data, signes: [String: String], accepte: String,
                                identite: IdentiteAWS, region: String, service: String,
                                instant: Date, delai: TimeInterval) -> URLRequest? {
        guard let signee = SignatureAWS.signer(methode: "POST", url: url, entetes: signes, corps: corps,
                                               identifiant: identite.identifiant, secret: identite.secret,
                                               region: region, service: service, instant: instant)
        else { return nil }
        var requete = URLRequest(url: url)
        requete.httpMethod = "POST"
        requete.httpBody = corps
        requete.timeoutInterval = delai
        for (nom, valeur) in signes { requete.setValue(valeur, forHTTPHeaderField: nom) }
        requete.setValue(signee.date, forHTTPHeaderField: "X-Amz-Date")
        requete.setValue(signee.autorisation, forHTTPHeaderField: "Authorization")
        requete.setValue(accepte, forHTTPHeaderField: "Accept")
        requete.setValue("Quotum", forHTTPHeaderField: "User-Agent")
        return requete
    }

    /// Le jeton de page vient du serveur et y repart, dans un corps JSON : borné, sans
    /// caractère de contrôle.
    static func estJetonDePage(_ texte: String) -> Bool {
        !texte.isEmpty && texte.utf8.count <= 2_048
            && !texte.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    // MARK: - Réponses

    struct Appelant: Sendable, Equatable {
        let arn: String
        let compte: String
    }

    enum ReponseIdentite: Sendable, Equatable {
        case appelant(Appelant)
        case echec(EchecBudget)
    }

    static func interpreterIdentite(code: Int, donnees: Data) -> ReponseIdentite {
        switch code {
        case 200:
            guard let lu = LecteurIdentiteSTS.lire(donnees) else { return .echec(.indetermine) }
            return .appelant(lu)
        // STS rend 403 pour un identifiant inconnu (`InvalidClientTokenId`) comme pour une
        // signature fausse (`SignatureDoesNotMatch`).
        case 401, 403: return .echec(.identiteRefusee)
        default: return .echec(.indetermine)
        }
    }

    /// Ce que `GetCallerIdentity` admet : un utilisateur IAM, jamais la racine.
    static func admettre(_ appelant: Appelant) -> EchecBudget? {
        switch classer(arn: appelant.arn, compte: appelant.compte) {
        case .utilisateur: nil
        case .racine: .cleRacine
        case .autre: .identiteNonAdmise
        }
    }

    struct Budget: Sendable, Equatable {
        let nom: String
        /// `nil` quand le budget n'est pas un budget de coût, ou que ses montants ne se
        /// lisent pas : il compte pour savoir qu'il existe, pas pour mesurer.
        let usage: UsagePayant?
        let deCout: Bool
    }

    struct PageBudgets: Sendable, Equatable {
        let budgets: [Budget]
        let suivant: String?
    }

    enum ReponseBudgets: Sendable, Equatable {
        case page(PageBudgets)
        case echec(EchecBudget)
    }

    /// Le protocole JSON 1.1 d'AWS rend la plupart des refus en 400 : c'est le type d'erreur
    /// (`__type`, ou l'en-tête `x-amzn-ErrorType`) qui dit de quoi il s'agit.
    static func interpreterBudgets(code: Int, typeErreur: String?, donnees: Data, mesureA: Date) -> ReponseBudgets {
        if code == 200 {
            return decoderBudgets(donnees, mesureA: mesureA).map(ReponseBudgets.page) ?? .echec(.indetermine)
        }
        let type = (typeErreur ?? typeDansLeCorps(donnees) ?? "").lowercased()
        if type.contains("accessdenied") { return .echec(.lectureRefusee) }
        // `DescribeBudgets` sur un compte sans budget répond `NotFoundException`.
        if type.contains("notfound") { return .echec(.aucunBudget) }
        if ["unrecognizedclient", "invalidsignature", "invalidclienttokenid", "signaturedoesnotmatch",
            "incompletesignature", "missingauthenticationtoken"].contains(where: type.contains) {
            return .echec(.identiteRefusee)
        }
        switch code {
        case 401: return .echec(.identiteRefusee)
        case 403: return .echec(.lectureRefusee)
        default: return .echec(.indetermine)
        }
    }

    private static func typeDansLeCorps(_ donnees: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: donnees) as? [String: Any])?["__type"] as? String
    }

    private struct ReponseBrute: Decodable {
        let budgets: [Tolerant]?
        let suivant: String?

        enum CodingKeys: String, CodingKey {
            case budgets = "Budgets"
            case suivant = "NextToken"
        }
    }

    private struct Tolerant: Decodable {
        let budget: BudgetBrut?
        init(from decodeur: Decoder) throws { budget = try? BudgetBrut(from: decodeur) }
    }

    private struct Somme: Decodable {
        let montant: String?
        let unite: String?

        enum CodingKeys: String, CodingKey {
            case montant = "Amount"
            case unite = "Unit"
        }
    }

    private struct BudgetBrut: Decodable {
        struct Periode: Decodable {
            let debut: Horodatage?
            let fin: Horodatage?

            enum CodingKeys: String, CodingKey {
                case debut = "Start"
                case fin = "End"
            }
        }

        struct Calcul: Decodable {
            let reelle: Somme?
            enum CodingKeys: String, CodingKey { case reelle = "ActualSpend" }
        }

        let nom: String
        let type: String?
        let unitePeriode: String?
        let plafond: Somme?
        let periode: Periode?
        let calcul: Calcul?
        let filtres: ValeurJSON?
        let expression: ValeurJSON?

        enum CodingKeys: String, CodingKey {
            case nom = "BudgetName"
            case type = "BudgetType"
            case unitePeriode = "TimeUnit"
            case plafond = "BudgetLimit"
            case periode = "TimePeriod"
            case calcul = "CalculatedSpend"
            case filtres = "CostFilters"
            case expression = "FilterExpression"
        }
    }

    /// `nil` quand le corps n'a pas la forme publiée. Un budget d'une forme inattendue ne
    /// fait pas tomber les autres.
    static func decoderBudgets(_ donnees: Data, mesureA: Date) -> PageBudgets? {
        guard let brute = try? JSONDecoder().decode(ReponseBrute.self, from: donnees) else { return nil }
        if let suivant = brute.suivant, !estJetonDePage(suivant) { return nil }
        let budgets = (brute.budgets ?? []).compactMap(\.budget).compactMap { budget -> Budget? in
            guard estNomDeBudget(budget.nom) else { return nil }
            let deCout = budget.type == "COST"
            return Budget(nom: budget.nom, usage: deCout ? usage(budget, mesureA: mesureA) : nil, deCout: deCout)
        }
        return PageBudgets(budgets: budgets, suivant: brute.suivant)
    }

    private static func usage(_ budget: BudgetBrut, mesureA: Date) -> UsagePayant? {
        guard let reelle = budget.calcul?.reelle, let code = reelle.unite, let texte = reelle.montant,
              let consomme = LectureBudget.montant(texte, code: code)
        else { return nil }
        var plafond: Montant?
        if let publie = budget.plafond {
            // Un plafond dans une autre devise que la dépense ne se compare pas.
            guard publie.unite == code, let texte = publie.montant,
                  let lu = LectureBudget.montant(texte, code: code), lu.unitesMineures >= 0
            else { return nil }
            plafond = lu
        }
        let debut = budget.periode?.debut?.date
        let (periode, echeance): (PeriodeDepense, Date?) = switch budget.unitePeriode {
        case "DAILY": (.jour, LectureBudget.prochainJour(apres: mesureA))
        case "MONTHLY": (.mois, LectureBudget.prochaineRemise(debut: debut, mois: 1, apres: mesureA)
                                 ?? LectureBudget.moisSuivant(apres: mesureA))
        case "QUARTERLY": (.trimestre, LectureBudget.prochaineRemise(debut: debut, mois: 3, apres: mesureA))
        case "ANNUALLY": (.annee, LectureBudget.prochaineRemise(debut: debut, mois: 12, apres: mesureA))
        // `CUSTOM` : une seule période, qui finit à `End`.
        default: (.personnalisee, budget.periode?.fin?.date.flatMap { $0 > mesureA ? $0 : nil })
        }
        return LectureBudget.usage(consomme: consomme, plafond: plafond, code: code, periode: periode,
                                   echeance: echeance, mesureA: mesureA,
                                   perimetre: perimetre(filtres: budget.filtres, expression: budget.expression))
    }

    // MARK: - Périmètre

    /// Le service de Bedrock dans les coûts d'AWS.
    static let serviceBedrock = "Amazon Bedrock"
    /// Les modèles tiers de Bedrock se facturent chacun sous un service à leur nom :
    /// « Claude Sonnet 4.5 (Amazon Bedrock Edition) ».
    static let suffixeEditionBedrock = " (Amazon Bedrock Edition)"
    static let profondeurFiltreMaximale = 16

    static func estServiceBedrock(_ nom: String) -> Bool {
        nom == serviceBedrock || (nom.hasSuffix(suffixeEditionBedrock) && nom.count > suffixeEditionBedrock.count)
    }

    /// ⛔ Fermé par défaut : la dépense n'est celle de Bedrock que si chaque filtre publié le
    /// prouve — `CostFilters`, déprécié, et `FilterExpression`, qu'AWS peut rendre ensemble —
    /// et qu'il y en a au moins un.
    static func perimetre(filtres: ValeurJSON?, expression: ValeurJSON?) -> PerimetreDepense {
        var preuves: [PreuvePerimetre] = []
        if !ValeurJSON.vide(filtres), let filtres { preuves.append(preuveFiltres(filtres)) }
        if !ValeurJSON.vide(expression), let expression { preuves.append(preuveExpression(expression, profondeur: 0)) }
        return PreuvePerimetre.perimetre(preuves)
    }

    /// `CostFilters` : des clés combinées en « et », chacune vers une liste de valeurs.
    static func preuveFiltres(_ valeur: ValeurJSON) -> PreuvePerimetre {
        guard case .objet(let carte) = valeur else { return .illisible }
        var services: [String]?
        for (cle, liste) in carte {
            guard let textes = liste.textes else { return .illisible }
            if cle == "Service" { services = textes }
        }
        guard let services, !services.isEmpty, services.allSatisfy(estServiceBedrock) else { return .elargi }
        return .limiteAuService
    }

    /// `FilterExpression` : un seul opérateur par nœud. Un « non » se reporte sur ce qu'il nie
    /// (De Morgan) : sous une négation, un « et » devient un « ou » et réciproquement, et deux
    /// négations s'annulent. Une intersection est limitée dès qu'une branche l'est, une union
    /// seulement si toutes le sont ; le complément d'une condition, lui, laisse passer les
    /// autres services.
    static func preuveExpression(_ valeur: ValeurJSON, profondeur: Int, nie: Bool = false) -> PreuvePerimetre {
        guard profondeur < profondeurFiltreMaximale, case .objet(let noeud) = valeur, noeud.count == 1,
              let (cle, contenu) = noeud.first else { return .illisible }
        switch cle {
        case "Dimensions":
            let preuve = preuveDimension(contenu)
            return nie && preuve != .illisible ? .elargi : preuve
        case "And", "Or":
            guard case .liste(let branches) = contenu, !branches.isEmpty else { return .illisible }
            let preuves = branches.map { preuveExpression($0, profondeur: profondeur + 1, nie: nie) }
            if preuves.contains(.illisible) { return .illisible }
            let intersection = (cle == "And") != nie
            let limite = intersection ? preuves.contains(.limiteAuService) : preuves.allSatisfy { $0 == .limiteAuService }
            return limite ? .limiteAuService : .elargi
        case "Not":
            return preuveExpression(contenu, profondeur: profondeur + 1, nie: !nie)
        case "Tags", "CostCategories", "ProductAttributes":
            guard case .objet = contenu else { return .illisible }
            return .elargi
        default:
            return .illisible
        }
    }

    private static func preuveDimension(_ valeur: ValeurJSON) -> PreuvePerimetre {
        guard case .objet(let dimension) = valeur,
              Set(dimension.keys).isSubset(of: ["Key", "Values", "MatchOptions"]),
              case .texte(let cle)? = dimension["Key"], let valeurs = dimension["Values"]?.textes
        else { return .illisible }
        var options: [String] = []
        if let brutes = dimension["MatchOptions"], brutes != .nul {
            guard let lues = brutes.textes else { return .illisible }
            options = lues
        }
        // La casse ne change pas l'opérateur : seul EQUALS, explicite ou par défaut, limite.
        let operateurs = Set(options).subtracting(["CASE_SENSITIVE", "CASE_INSENSITIVE"])
        guard cle == "SERVICE", operateurs.isEmpty || operateurs == ["EQUALS"],
              !valeurs.isEmpty, valeurs.allSatisfy(estServiceBedrock) else { return .elargi }
        return .limiteAuService
    }

    // MARK: - Appels

    private static func charger(_ requete: URLRequest, session: URLSession) async -> (Int, String?, Data)? {
        do {
            let (donnees, reponse) = try await session.data(for: requete,
                                                            delegate: QuotaWindsurf.RefusDeRedirection())
            let http = reponse as? HTTPURLResponse
            let code = http?.statusCode ?? -1
            if code != 200 {
                // Le statut seul : ni l'identité, ni le corps, qui peut citer l'utilisateur.
                Journal.donnees.notice("Dépense AWS : statut HTTP \(code)")
            }
            return (code, http?.value(forHTTPHeaderField: "x-amzn-ErrorType"), donnees)
        } catch {
            Journal.donnees.debug("Dépense AWS : service injoignable")
            return nil
        }
    }

    /// Qui signe, et si on l'admet.
    static func appelant(_ identite: IdentiteAWS, region: String, session: URLSession,
                         delai: TimeInterval) async -> Result<Appelant, EchecBudget> {
        guard let requete = requeteIdentite(identite, region: region, instant: Date(), delai: delai),
              let (code, _, donnees) = await charger(requete, session: session)
        else { return .failure(.indetermine) }
        switch interpreterIdentite(code: code, donnees: donnees) {
        case .echec(let echec): return .failure(echec)
        case .appelant(let appelant):
            if let refus = admettre(appelant) { return .failure(refus) }
            return .success(appelant)
        }
    }

    /// Tous les budgets du compte, page après page.
    static func budgets(_ identite: IdentiteAWS, compte: String, session: URLSession,
                        delai: TimeInterval) async -> Result<[Budget], EchecBudget> {
        var suivant: String?
        var vus: Set<String> = []
        var tous: [Budget] = []
        for _ in 0..<pagesMaximales {
            let instant = Date()
            guard let requete = requeteBudgets(identite, compte: compte, suivant: suivant, instant: instant, delai: delai),
                  let (code, type, donnees) = await charger(requete, session: session)
            else { return .failure(.indetermine) }
            switch interpreterBudgets(code: code, typeErreur: type, donnees: donnees, mesureA: instant) {
            case .echec(let echec): return .failure(echec)
            case .page(let page):
                tous += page.budgets
                guard let prochain = page.suivant else { return .success(tous) }
                guard vus.insert(prochain).inserted else { return .failure(.indetermine) }
                suivant = prochain
            }
        }
        return .failure(.indetermine)
    }

    /// Le budget suivi parmi ceux du compte. Sans nom, le seul budget de coût.
    static func choisir(_ budgets: [Budget], nom: String?) -> Result<Budget, EchecBudget> {
        let deCout = budgets.filter(\.deCout)
        if let nom {
            guard let trouve = deCout.first(where: { $0.nom == nom }) else { return .failure(.budgetAbsent) }
            return .success(trouve)
        }
        switch deCout.count {
        case 0: return .failure(.aucunBudget)
        case 1: return .success(deCout[0])
        default: return .failure(.budgetAmbigu)
        }
    }

    /// Le relevé d'un cycle : l'identité d'abord, de nouveau, puis le budget gardé.
    static func relever(_ identite: IdentiteAWS, enregistrement: EnregistrementAWS, session: URLSession,
                        delai: TimeInterval = 8) async -> ReleveBudget {
        switch await appelant(identite, region: enregistrement.region, session: session, delai: delai) {
        case .failure(let echec): return .echec(echec)
        case .success(let appelant):
            guard appelant.compte == enregistrement.compte, appelant.arn == enregistrement.utilisateur else {
                return .echec(.identiteNonAdmise)
            }
        }
        switch await budgets(identite, compte: enregistrement.compte, session: session, delai: delai) {
        case .failure(let echec): return .echec(echec == .aucunBudget ? .budgetAbsent : echec)
        case .success(let budgets):
            switch choisir(budgets, nom: enregistrement.budget) {
            case .failure(let echec): return .echec(echec)
            case .success(let budget):
                guard let usage = budget.usage else { return .echec(.illisible) }
                return .mesure(DepenseBudget(budget: budget.nom, usage: usage))
            }
        }
    }

    /// À l'ajout : l'identité est-elle admise, et quel budget suivre ?
    static func resoudre(_ identite: IdentiteAWS, region: String, budget nom: String?, session: URLSession,
                         delai: TimeInterval = 15) async -> Result<(EnregistrementAWS, DepenseBudget), EchecBudget> {
        let appelant: Appelant
        switch await self.appelant(identite, region: region, session: session, delai: delai) {
        case .failure(let echec): return .failure(echec)
        case .success(let lu): appelant = lu
        }
        switch await budgets(identite, compte: appelant.compte, session: session, delai: delai) {
        case .failure(let echec): return .failure(nom != nil && echec == .aucunBudget ? .budgetAbsent : echec)
        case .success(let budgets):
            switch choisir(budgets, nom: nom) {
            case .failure(let echec): return .failure(echec)
            case .success(let budget):
                guard let usage = budget.usage else { return .failure(.illisible) }
                return .success((EnregistrementAWS(region: region, compte: appelant.compte,
                                                   utilisateur: appelant.arn, budget: budget.nom),
                                 DepenseBudget(budget: budget.nom, usage: usage)))
            }
        }
    }
}

/// La réponse XML de `GetCallerIdentity` : `Arn` et `Account` sous `GetCallerIdentityResult`.
private final class LecteurIdentiteSTS: NSObject, XMLParserDelegate {
    private var chemin: [String] = []
    private var texte = ""
    private var arn: String?
    private var compte: String?
    private var doublon = false

    static func lire(_ donnees: Data) -> DepenseAWS.Appelant? {
        guard donnees.count <= 64 * 1_024 else { return nil }
        let analyseur = XMLParser(data: donnees)
        analyseur.shouldResolveExternalEntities = false
        let lecteur = LecteurIdentiteSTS()
        analyseur.delegate = lecteur
        guard analyseur.parse(), !lecteur.doublon,
              let arn = lecteur.arn, let compte = lecteur.compte, DepenseAWS.estCompte(compte)
        else { return nil }
        return DepenseAWS.Appelant(arn: arn, compte: compte)
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        chemin.append(element)
        texte = ""
    }

    func parser(_ parser: XMLParser, foundCharacters caracteres: String) {
        texte += caracteres
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let parent = chemin.dropLast().last
        if parent == "GetCallerIdentityResult" {
            let valeur = texte.trimmingCharacters(in: .whitespacesAndNewlines)
            switch element {
            case "Arn":
                if arn != nil { doublon = true }
                arn = valeur
            case "Account":
                if compte != nil { doublon = true }
                compte = valeur
            default: break
            }
        }
        chemin.removeLast()
        texte = ""
    }
}
