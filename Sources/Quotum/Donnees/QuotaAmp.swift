import Foundation

/// Ce qu'une sortie de `amp usage` établit, une fois reconnue ligne à ligne.
struct MesureAmp: Sendable, Equatable {
    /// `nil` quand aucune réserve publiée n'a à la fois une dotation et une échéance : des
    /// crédits seuls ne font aucune fenêtre.
    var quota: Quota?
    var mesureA: Date
    /// La ligne « Signed in as » : seule ancre d'identité de la sortie.
    var courriel: String
    var organisation: String?
    /// Le nom du palier tel qu'imprimé (« Megawatt »), jamais traduit.
    var formule: String?
    /// « Individual credits » : un solde en dollars **sans plafond ni échéance**.
    var creditsIndividuels: Montant?
    /// « Workspace <nom> » : l'argent d'un espace de travail, partagé avec ses membres.
    var creditsEspaces: [CreditEspaceAmp] = []

    /// La forme que prendraient les crédits individuels dans le modèle, s'ils étaient
    /// affichés : une réserve prépayée, comme chez Codex ou Warp. Rien ne la branche encore.
    ///
    /// ⚠️ `bloque` reste faux à zéro dollar : rien n'établit qu'un solde vide arrête Amp, la
    /// dotation gratuite et celle du palier se consomment avant lui.
    var usagePayantPropose: UsagePayant? {
        guard let credits = creditsIndividuels else { return nil }
        return UsagePayant(nature: .solde,
                           unite: credits.unite,
                           consomme: nil,
                           plafond: nil,
                           solde: credits,
                           utilisation: nil,
                           illimite: nil,
                           actif: nil,
                           bloque: false,
                           motif: nil,
                           echeance: nil,
                           mesureA: mesureA)
    }
}

struct CreditEspaceAmp: Sendable, Equatable {
    var nom: String
    var solde: Montant
}

/// Ce que le lancement de `amp usage` a pu établir.
enum ReleveAmp: Sendable, Equatable {
    case releve(MesureAmp)
    /// Aucun des emplacements connus ne porte d'exécutable, ou le lanceur ne l'a pas trouvé.
    case binaireIntrouvable
    /// La commande a rendu la main avec un code non nul — compte déconnecté, panne réseau,
    /// version qui ne connaît pas la sous-commande : la sortie ne permet pas de trancher.
    case echecCommande(code: Int32)
    case delaiDepasse
    /// Le lanceur a refusé d'exécuter le binaire.
    case refusee
    /// Une sortie qui n'est pas exactement l'une des formes connues — tronquée, vide, autre
    /// langue, ligne connue dont la forme a changé. ⛔ Rien n'en est retenu, pas même ce qui
    /// semblait lisible : un format qui bouge sur une ligne peut avoir bougé sur les autres.
    case illisible
    /// Personne n'a regardé : le suivi est éteint, ou la ligne est verrouillée par l'essai.
    case indetermine
}

/// Le quota de Sourcegraph Amp, lu par son CLI officiel : `amp usage`.
///
/// ⛔ **Aucune analyse approximative.** La sortie est un texte pour humains, sans schéma
/// publié. Chaque ligne qui commence comme une ligne connue doit en avoir **exactement** la
/// forme, sinon la sortie entière est `illisible` ; les lignes d'un autre préfixe (conseils,
/// annonces) sont ignorées. Aucune casse tolérée, aucun séparateur de milliers autre que la
/// virgule anglaise, aucun signe moins : un CLI qui changerait de langue ou de format rend
/// « illisible », jamais un chiffre faux.
///
/// ⚠️ Formes relevées dans des sources tierces (CodexBar, MIT : faits seulement) — aucune
/// sortie réelle observée, Amp n'est pas installé sur la machine de développement.
enum QuotaAmp {
    /// La commande exacte. Ni `--no-color` ni option de format : aucune n'est documentée par
    /// Amp, et un drapeau inconnu ferait échouer la commande. Les séquences ANSI sont retirées
    /// à l'analyse.
    static let arguments = ["usage"]

    /// Les emplacements où les installations officielles posent `amp`, relatifs au dossier
    /// personnel : l'installeur d'ampcode.com range le binaire dans `~/.amp/bin` (sans
    /// `AMP_HOME`) et le lie dans `~/.local/bin`.
    static let cheminsRelatifsMaison = [".amp/bin/amp", ".local/bin/amp"]
    /// Le paquet npm `@ampcode/cli`, installé globalement par Homebrew ou par le Node du système.
    static let cheminsAbsolus = ["/opt/homebrew/bin/amp", "/usr/local/bin/amp"]

    /// ⛔ **Liste fermée.** Ni `PATH`, ni shell de connexion, ni variable d'environnement :
    /// Quotum n'exécute que ce qui se trouve à l'un de ces chemins.
    static func cheminsBinaire(maison: URL) -> [URL] {
        let systeme = cheminsAbsolus.map { URL(filePath: $0, directoryHint: .notDirectory) }
        guard maison.isFileURL, maison.path(percentEncoded: false).hasPrefix("/") else { return systeme }
        let personnels = cheminsRelatifsMaison.map {
            maison.appending(path: $0, directoryHint: .notDirectory)
        }
        return personnels + systeme
    }

    static func localiserBinaire(maison: URL, estExecutable: (URL) -> Bool) -> URL? {
        cheminsBinaire(maison: maison).first(where: estExecutable)
    }

    /// `estExecutable` et `lanceur` sont injectés, sans valeur par défaut : un appel sous
    /// test ne peut ni sonder le disque ni lancer le vrai binaire.
    static func relever(maison: URL,
                        estExecutable: (URL) -> Bool,
                        lanceur: LanceurCLI,
                        horloge: @Sendable () -> Date = { .now }) async -> ReleveAmp {
        guard let binaire = localiserBinaire(maison: maison, estExecutable: estExecutable) else {
            return .binaireIntrouvable
        }
        let resultat = await lanceur(binaire, arguments)
        return interpreter(resultat, maintenant: horloge())
    }

    static func interpreter(_ resultat: ResultatCLI, maintenant: Date) -> ReleveAmp {
        switch resultat.issue {
        case .introuvable: return .binaireIntrouvable
        case .delaiDepasse: return .delaiDepasse
        case .refusee: return .refusee
        case .terminee(let code) where code != 0: return .echecCommande(code: code)
        case .terminee: break
        }
        // Une sortie coupée peut l'être au milieu d'un nombre : « $4.7 » pour « $4.71 ».
        guard !resultat.tronquee,
              let texte = String(data: resultat.sortie, encoding: .utf8),
              let mesure = analyser(texte, maintenant: maintenant)
        else { return .illisible }
        return .releve(mesure)
    }

    // MARK: - Analyse

    /// `nil` dès qu'une ligne connue n'a pas exactement sa forme, qu'une ligne unique est
    /// répétée, que l'identité manque ou que rien de mesurable n'est publié.
    static func analyser(_ texte: String, maintenant: Date) -> MesureAmp? {
        var identite: (courriel: String, organisation: String?)?
        var gratuit: LigneGratuite?
        var palier: LignePalier?
        var ancienAbonnement: String?
        var creditsIndividuels: Montant?
        var espaces: [CreditEspaceAmp] = []

        for brute in sansSequencesTerminal(texte).split(whereSeparator: \.isNewline) {
            guard let ligne = normaliser(String(brute)) else { return nil }
            if ligne.isEmpty { continue }

            switch Prefixe(ligne) {
            case nil:
                continue
            case .identite:
                guard identite == nil, let lue = lireIdentite(ligne) else { return nil }
                identite = lue
            case .gratuit:
                guard gratuit == nil, let lue = lireGratuit(ligne) else { return nil }
                gratuit = lue
            case .palier:
                guard palier == nil, ancienAbonnement == nil, let lue = lirePalier(ligne) else { return nil }
                palier = lue
            case .ancienAbonnement:
                guard palier == nil, ancienAbonnement == nil,
                      let lue = lireAncienAbonnement(ligne) else { return nil }
                ancienAbonnement = lue
            case .creditsIndividuels:
                guard creditsIndividuels == nil, let lue = lireCredits(ligne) else { return nil }
                creditsIndividuels = lue
            case .espace:
                guard let lue = lireEspace(ligne),
                      !espaces.contains(where: { $0.nom == lue.nom }) else { return nil }
                espaces.append(lue)
            }
        }

        guard let identite,
              gratuit != nil || palier != nil || ancienAbonnement != nil
                || creditsIndividuels != nil || !espaces.isEmpty
        else { return nil }

        let fenetres = [gratuit?.fenetre(maintenant: maintenant),
                        palier?.fenetreAgent,
                        palier?.fenetreOrb].compactMap { $0 }
        return MesureAmp(quota: fenetres.isEmpty ? nil : Quota(fenetres),
                         mesureA: maintenant,
                         courriel: identite.courriel,
                         organisation: identite.organisation,
                         formule: palier?.formule ?? ancienAbonnement,
                         creditsIndividuels: creditsIndividuels,
                         creditsEspaces: espaces)
    }

    /// Le dollar de rechargement continu n'a pas de fenêtre nommée : la durée qu'on en tire
    /// est un calcul, pas une convention publiée.
    static let libelleGlissante = "Fenêtre glissante"
    /// Les noms des deux réserves du palier, tels qu'Amp les imprime : des noms de produit.
    static let reserveAgent = "Agent"
    static let reserveOrb = "Orb"

    private enum Prefixe {
        case identite, gratuit, palier, ancienAbonnement, creditsIndividuels, espace

        init?(_ ligne: String) {
            if ligne.hasPrefix("Signed in as") { self = .identite }
            else if ligne.hasPrefix("Amp Free:") { self = .gratuit }
            else if ligne.hasPrefix("Individual credits:") { self = .creditsIndividuels }
            else if ligne.hasPrefix("Workspace ") { self = .espace }
            else if ligne.hasPrefix("Subscription ") { self = .ancienAbonnement }
            else if ligne.hasPrefix("Amp "), ligne.contains(" Subscription:") { self = .ancienAbonnement }
            else if ligne.hasPrefix("Amp "), ligne.contains(" Tier:") { self = .palier }
            else { return nil }
        }
    }

    private enum LigneGratuite {
        /// « N% remaining » — `quotidienne` seulement si la ligne le dit (« today » ou
        /// « (resets daily) ») : un pourcentage seul ne dit pas sa période.
        case pourcentage(restant: Double, quotidienne: Bool)
        /// « $R/$Q remaining (replenishes +$H/hour) ».
        case dollars(restant: Double, dotation: Double, parHeure: Double?)

        func fenetre(maintenant: Date) -> Fenetre? {
            switch self {
            case .pourcentage(let restant, let quotidienne):
                guard quotidienne else { return nil }
                // ⚠️ L'heure de remise à zéro n'est pas imprimée : `seRechargeA` reste nul
                // plutôt que de reprendre une heure relevée chez un tiers.
                return Fenetre(libelle: Fenetre.libelleVingtQuatreHeures,
                               sorte: .vingtQuatreHeures,
                               utilisation: 100 - restant,
                               duree: 86_400)
            case .dollars(let restant, let dotation, let parHeure):
                // Sans rythme de recharge, aucune échéance : pas de fenêtre.
                guard let parHeure, parHeure > 0 else { return nil }
                let consomme = dotation - restant
                let jusquAuPlein = consomme / parHeure * 3_600
                let duree = dotation / parHeure * 3_600
                guard jusquAuPlein.isFinite, duree.isFinite else { return nil }
                return Fenetre(libelle: QuotaAmp.libelleGlissante,
                               sorte: .glissante,
                               utilisation: consomme / dotation * 100,
                               seRechargeA: maintenant.addingTimeInterval(jusquAuPlein),
                               duree: duree)
            }
        }
    }

    private struct LignePalier {
        var formule: String
        var fenetreAgent: Fenetre?
        var fenetreOrb: Fenetre?
    }

    // MARK: - Formes connues

    /// Un montant à l'anglaise : chiffres ASCII, virgule des milliers par groupes de trois,
    /// point décimal. Ni signe, ni exposant.
    private static let nombre = #"((?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)"#
    private static let pourcentage = #"([0-9]+(?:\.[0-9]+)?)"#
    private static let date = #"([0-9]{4}-[0-9]{2}-[0-9]{2})"#
    private static let renouvellement = #"resets upon renewal in [0-9]+(?:,[0-9]{3})* (?:day|days|month|months)"#
    private static let parenthese = #"(?: \([^()]*\))?"#

    private static func lireIdentite(_ ligne: String) -> (courriel: String, organisation: String?)? {
        guard let c = captures(#"Signed in as ([^\s()]+)(?: \(([^()]+)\))?"#, ligne),
              let courriel = c[0] else { return nil }
        return (String(courriel), c[1].map(String.init))
    }

    private static func lireGratuit(_ ligne: String) -> LigneGratuite? {
        if let c = captures("Amp Free: \(pourcentage)% remaining( today)?( \\(resets daily\\))?", ligne) {
            guard let restant = valeur(c[0]), restant <= 100 else { return nil }
            return .pourcentage(restant: restant, quotidienne: c[1] != nil || c[2] != nil)
        }
        let forme = "Amp Free: \\$\(nombre) ?/ ?\\$\(nombre) remaining(?: \\(replenishes \\+\\$\(nombre) ?/ ?hour\\))?"
        guard let c = captures(forme, ligne),
              let restant = valeur(c[0]),
              let dotation = valeur(c[1]), dotation > 0, restant <= dotation
        else { return nil }
        let parHeure: Double?
        if let texte = c[2] {
            guard let lu = valeur(texte) else { return nil }
            parHeure = lu
        } else {
            parHeure = nil
        }
        return .dollars(restant: restant, dotation: dotation, parHeure: parHeure)
    }

    /// « Amp Megawatt Tier: agent usage $18.57 of $20 remaining (93%), orb usage 732.8h of
    /// 750h a1.small orb hours remaining (98%) - period 2026-09-13 to 2026-10-13, resets upon
    /// renewal in 27 days ».
    ///
    /// Les deux réserves sont des dotations mensuelles : fenêtre `.mois`, échéance à la fin de
    /// la période imprimée. ⚠️ Cette date n'a que la précision du jour (minuit UTC). Sans
    /// période, le compte à rebours arrondi (« in 27 days ») ne fait pas d'échéance, donc pas
    /// de fenêtre — la ligne reste reconnue.
    private static func lirePalier(_ ligne: String) -> LignePalier? {
        let orb = "(?:, orb usage \(nombre)h of \(nombre)h a1\\.small orb hours remaining(?: \\([0-9]+%\\))?)?"
        let forme = "Amp (.+?) Tier: agent usage \\$\(nombre) of \\$\(nombre) remaining(?: \\([0-9]+%\\))?"
            + orb + " - (?:period \(date) to \(date), )?" + renouvellement
        guard let c = captures(forme, ligne),
              let formule = c[0],
              let agentRestant = valeur(c[1]), let agentDotation = valeur(c[2])
        else { return nil }

        var fin: Date?
        if let debutTexte = c[5], let finTexte = c[6] {
            guard let debut = jourUTC(debutTexte), let finLue = jourUTC(finTexte), finLue > debut else { return nil }
            fin = finLue
        }

        // ⚠️ Pas de `try?` : il aplatit l'optionnel, et une réserve incohérente se confondrait
        // avec une réserve sans fenêtre.
        do {
            let agent = try reserve(restant: agentRestant, dotation: agentDotation, fin: fin, nom: reserveAgent)
            var orb: Fenetre?
            if let restantTexte = c[3], let dotationTexte = c[4] {
                guard let restant = valeur(restantTexte), let dotation = valeur(dotationTexte) else { return nil }
                orb = try reserve(restant: restant, dotation: dotation, fin: fin, nom: reserveOrb)
            }
            return LignePalier(formule: String(formule), fenetreAgent: agent, fenetreOrb: orb)
        } catch {
            return nil
        }
    }

    private struct ReserveIncoherente: Error {}

    /// Un restant supérieur à la dotation est une incohérence (`throw`) ; une dotation nulle
    /// ou une échéance absente, une réserve qui ne fait pas de fenêtre (`nil`).
    private static func reserve(restant: Double, dotation: Double, fin: Date?, nom: String) throws -> Fenetre? {
        guard restant <= dotation else { throw ReserveIncoherente() }
        guard dotation > 0, let fin else { return nil }
        return Fenetre(libelle: Fenetre.libelleMois,
                       sorte: .mois,
                       utilisation: (dotation - restant) / dotation * 100,
                       seRechargeA: fin,
                       reserve: nom)
    }

    /// L'ancienne forme, en pourcentages arrondis et sans date : reconnue pour ne pas rendre
    /// la sortie illisible, mais elle ne fait aucune fenêtre faute d'échéance.
    private static func lireAncienAbonnement(_ ligne: String) -> String? {
        let suite = ": \(pourcentage)% other usage and \(pourcentage)% orb usage remaining - " + renouvellement
        for forme in ["Subscription (.+?)" + suite, "Amp (.+?) Subscription" + suite] {
            guard let c = captures(forme, ligne), let formule = c[0] else { continue }
            let bornes = [c[1], c[2]].allSatisfy { valeur($0).map { $0 <= 100 } ?? false }
            return bornes ? String(formule) : nil
        }
        return nil
    }

    private static func lireCredits(_ ligne: String) -> Montant? {
        guard let c = captures("Individual credits: \\$\(nombre) remaining" + parenthese, ligne),
              let texte = c[0] else { return nil }
        return dollars(texte)
    }

    private static func lireEspace(_ ligne: String) -> CreditEspaceAmp? {
        guard let c = captures("Workspace (.+?): \\$\(nombre) remaining" + parenthese, ligne),
              let nom = c[0], let texte = c[1], let solde = dollars(texte) else { return nil }
        return CreditEspaceAmp(nom: String(nom), solde: solde)
    }

    // MARK: - Outils

    /// Retire les séquences CSI (couleurs, styles) et OSC (liens hypertexte de terminal).
    private static func sansSequencesTerminal(_ texte: String) -> String {
        texte
            .replacing(#/\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)/#, with: "")
            .replacing(#/\x1B\[[0-9;?]*[A-Za-z]/#, with: "")
    }

    /// La ligne sans gras Markdown, sans lien final, sans blancs de bord. `nil` si un caractère
    /// de contrôle y reste — une séquence de terminal qu'on ne connaît pas.
    private static func normaliser(_ ligne: String) -> String? {
        guard !ligne.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            return nil
        }
        return ligne
            .replacing("**", with: "")
            .replacing(#/ - https?:\/\/\S+$/#, with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Les groupes d'une correspondance **entière**, ou `nil`.
    private static func captures(_ motif: String, _ ligne: String) -> [Substring?]? {
        guard let regex = try? Regex(motif),
              let correspondance = try? regex.wholeMatch(in: ligne) else { return nil }
        return correspondance.output.dropFirst().map { $0.substring }
    }

    private static func valeur(_ texte: Substring?) -> Double? {
        guard let texte, let lu = Double(texte.replacing(",", with: "")), lu.isFinite, lu >= 0 else { return nil }
        return lu
    }

    private static func dollars(_ texte: Substring) -> Montant? {
        Montant(texteDecimal: String(texte.replacing(",", with: "")), unite: .devise("USD"))
    }

    /// Une date `AAAA-MM-JJ` qui existe : « 2026-02-30 » ne glisse pas au 2 mars.
    private static func jourUTC(_ texte: Substring) -> Date? {
        let parties = texte.split(separator: "-").compactMap { Int($0) }
        guard parties.count == 3 else { return nil }
        var calendrier = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else { return nil }
        calendrier.timeZone = utc
        let composantes = DateComponents(year: parties[0], month: parties[1], day: parties[2])
        guard let jour = calendrier.date(from: composantes) else { return nil }
        let relu = calendrier.dateComponents([.year, .month, .day], from: jour)
        guard relu.year == parties[0], relu.month == parties[1], relu.day == parties[2] else { return nil }
        return jour
    }
}
