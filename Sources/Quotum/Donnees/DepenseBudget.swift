import Foundation

/// La dépense d'un budget de coût, telle qu'un nuage la publie : AWS Budgets ou les budgets
/// de consommation d'Azure. Deux lecteurs autonomes la rendent ; seuls ce type, l'issue d'un
/// relevé et la lecture des montants leur sont communs.
struct DepenseBudget: Sendable, Equatable {
    let budget: String
    let usage: UsagePayant
}

/// Pourquoi un relevé n'a pas donné de dépense.
enum EchecBudget: Error, Sendable, Equatable {
    /// Identifiants refusés : révoqués, expirés, mal copiés.
    case identiteRefusee
    /// AWS : les identifiants de l'utilisateur racine du compte, qui peuvent tout.
    case cleRacine
    /// AWS : une identité qui n'est pas un utilisateur IAM, ou qui n'est plus celle qu'on a
    /// gardée.
    case identiteNonAdmise
    /// Azure : le principal porte une action qui n'est pas une lecture.
    case porteeEcriture
    /// L'identité ne lit pas les budgets, ou pas l'abonnement.
    case lectureRefusee
    /// Aucun budget de coût sur le compte ou l'abonnement.
    case aucunBudget
    /// Le budget nommé n'existe pas, ou plus.
    case budgetAbsent
    /// Plusieurs budgets de coût, et aucun nommé : on ne choisit pas au hasard.
    case budgetAmbigu
    /// Le budget existe, mais ses montants ne se lisent pas.
    case illisible
    /// Réseau, redirection refusée, limite de débit, 5xx : rien n'est établi.
    case indetermine

    /// Ce qui ne dit rien de la clé : la dernière dépense mesurée reste valable.
    var silencieux: Bool {
        switch self {
        case .illisible, .indetermine: true
        case .identiteRefusee, .cleRacine, .identiteNonAdmise, .porteeEcriture, .lectureRefusee,
             .aucunBudget, .budgetAbsent, .budgetAmbigu: false
        }
    }
}

/// Un filtre de budget tel que publié, sans interprétation : sa forme est récursive, et seul
/// le lecteur de chaque nuage sait ce qu'il prouve. Un nombre ou un booléen ne disent rien
/// d'un service : ils restent `autre`.
indirect enum ValeurJSON: Decodable, Sendable, Equatable {
    case texte(String)
    case liste([ValeurJSON])
    case objet([String: ValeurJSON])
    case nul
    case autre

    init(from decodeur: Decoder) throws {
        let conteneur = try decodeur.singleValueContainer()
        if conteneur.decodeNil() {
            self = .nul
        } else if let texte = try? conteneur.decode(String.self) {
            self = .texte(texte)
        } else if let liste = try? conteneur.decode([ValeurJSON].self) {
            self = .liste(liste)
        } else if let objet = try? conteneur.decode([String: ValeurJSON].self) {
            self = .objet(objet)
        } else {
            self = .autre
        }
    }

    /// Absent, `null` ou objet vide : aucun filtre posé.
    static func vide(_ valeur: ValeurJSON?) -> Bool {
        switch valeur {
        case nil, .nul?: true
        case .objet(let objet)?: objet.isEmpty
        case .texte?, .liste?, .autre?: false
        }
    }

    var textes: [String]? {
        guard case .liste(let elements) = self else { return nil }
        var textes: [String] = []
        for element in elements {
            guard case .texte(let texte) = element else { return nil }
            textes.append(texte)
        }
        return textes
    }
}

/// Ce qu'un filtre de budget établit sur son périmètre de services.
enum PreuvePerimetre: Sendable, Equatable {
    case limiteAuService
    /// Une forme connue qui laisse passer d'autres services.
    case elargi
    /// Une forme qu'on ne connaît pas : elle ne prouve rien, et n'en laisse rien prouver.
    case illisible

    /// Les filtres publiés ensemble s'appliquent tous. ⛔ Sans filtre, la dépense est celle du
    /// compte entier ; une forme inconnue n'autorise aucune affirmation.
    static func perimetre(_ preuves: [PreuvePerimetre]) -> PerimetreDepense {
        if preuves.isEmpty { return .elargi }
        if preuves.contains(.illisible) { return .nonVerifie }
        return preuves.allSatisfy { $0 == .limiteAuService } ? .limite : .elargi
    }
}

enum ReleveBudget: Sendable, Equatable {
    case mesure(DepenseBudget)
    case echec(EchecBudget)
}

/// Lectures communes aux deux budgets : les montants, et l'échéance d'une période.
enum LectureBudget {
    /// Un montant publié en texte décimal (« 46.31 », « 500.0 ») ou en notation scientifique
    /// (« 6.9E-4 », qu'AWS emploie pour les très petites dépenses). Vide, signe double, `NaN`,
    /// infini ou au-delà de dix-huit chiffres : aucun montant.
    static func montant(_ texte: String, code: String) -> Montant? {
        let unite = Montant.Unite.devise(code)
        guard unite.estReconnue, !texte.isEmpty, texte.utf8.count <= 64 else { return nil }
        if let direct = Montant(texteDecimal: texte, unite: unite) { return direct }
        guard texte.wholeMatch(of: /-?[0-9]{1,20}(\.[0-9]{1,20})?[eE][+-]?[0-9]{1,2}/) != nil,
              let decimal = Decimal(string: texte, locale: Locale(identifier: "en_US_POSIX")),
              decimal.isFinite
        else { return nil }
        return Montant(texteDecimal: NSDecimalNumber(decimal: decimal).stringValue, unite: unite)
    }

    /// Un nombre JSON lu en `Decimal`, rendu en texte puis en montant : jamais de `Double`.
    static func montant(_ decimal: Decimal, code: String) -> Montant? {
        guard decimal.isFinite else { return nil }
        return Montant(texteDecimal: NSDecimalNumber(decimal: decimal).stringValue, unite: .devise(code))
    }

    /// Le premier début de période après `instant`, en pas de `mois` depuis `debut`, en UTC.
    /// `nil` quand le début manque ou que le pas n'avance pas.
    static func prochaineRemise(debut: Date?, mois pas: Int, apres instant: Date) -> Date? {
        guard let debut, pas > 0, let utc = TimeZone(identifier: "UTC") else { return nil }
        var calendrier = Calendar(identifier: .gregorian)
        calendrier.timeZone = utc
        // Mille deux cents pas couvrent un siècle de mois : au-delà, la date publiée est absurde.
        for rang in 1...1_200 {
            guard let date = calendrier.date(byAdding: .month, value: rang * pas, to: debut) else { return nil }
            if date > instant { return date }
        }
        return nil
    }

    /// Minuit UTC suivant.
    static func prochainJour(apres instant: Date) -> Date? {
        guard let utc = TimeZone(identifier: "UTC") else { return nil }
        var calendrier = Calendar(identifier: .gregorian)
        calendrier.timeZone = utc
        return calendrier.date(byAdding: .day, value: 1, to: calendrier.startOfDay(for: instant))
    }

    /// Le premier du mois suivant à 00:00 UTC.
    static func moisSuivant(apres instant: Date) -> Date? {
        guard let utc = TimeZone(identifier: "UTC") else { return nil }
        var calendrier = Calendar(identifier: .gregorian)
        calendrier.timeZone = utc
        guard let debut = calendrier.date(from: calendrier.dateComponents([.year, .month], from: instant))
        else { return nil }
        return calendrier.date(byAdding: .month, value: 1, to: debut)
    }

    /// La dépense d'une période, contre son plafond quand il est publié.
    static func usage(consomme: Montant,
                      plafond: Montant?,
                      code: String,
                      periode: PeriodeDepense,
                      echeance: Date?,
                      mesureA: Date,
                      perimetre: PerimetreDepense) -> UsagePayant? {
        UsagePayant(nature: .depense,
                    unite: .devise(code),
                    consomme: consomme,
                    plafond: plafond,
                    solde: nil,
                    utilisation: nil,
                    illimite: nil,
                    actif: nil,
                    bloque: false,
                    motif: nil,
                    echeance: echeance,
                    mesureA: mesureA,
                    periode: periode,
                    perimetre: perimetre)
    }

    /// Le nom d'un budget tel qu'on le garde et l'affiche : sans caractère de contrôle, borné.
    static func nomLisible(_ nom: String) -> Bool {
        !nom.isEmpty && nom.count <= 100
            && !nom.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}
