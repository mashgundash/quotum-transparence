import Foundation

/// Ce que le Trousseau dit d'une clé de lecture, sans en lire le secret.
enum EtatCle<Enregistrement: Sendable & Equatable>: Sendable, Equatable {
    case aucune
    /// Trousseau verrouillé ou accès refusé : la clé peut être là, intacte.
    case empechee
    /// L'élément existe, mais ce qui l'accompagne n'a pas la forme écrite par l'app.
    case illisible
    case enregistree(Enregistrement)

    static func depuis(_ lecture: LectureElementCle, decoder: (Data) -> Enregistrement?) -> Self {
        switch lecture {
        case .absent: .aucune
        case .empeche: .empechee
        case .present(let donnees): decoder(donnees).map(Self.enregistree) ?? .illisible
        }
    }

    var enregistrement: Enregistrement? {
        if case .enregistree(let enregistrement) = self { return enregistrement }
        return nil
    }
}

typealias EtatCleAnthropic = EtatCle<EnregistrementAnthropic>
typealias EtatCleAWS = EtatCle<EnregistrementAWS>
typealias EtatCleAzure = EtatCle<EnregistrementAzure>

extension EtatCle where Enregistrement == EnregistrementAnthropic {
    static func depuis(_ lecture: LectureElementCle) -> Self { depuis(lecture, decoder: EnregistrementAnthropic.decoder) }
}

extension EtatCle where Enregistrement == EnregistrementAWS {
    static func depuis(_ lecture: LectureElementCle) -> Self { depuis(lecture, decoder: EnregistrementAWS.decoder) }
}

extension EtatCle where Enregistrement == EnregistrementAzure {
    static func depuis(_ lecture: LectureElementCle) -> Self { depuis(lecture, decoder: EnregistrementAzure.decoder) }
}

/// Les lectures des clés de lecture, telles qu'`Inventaire` les appelle.
///
/// ⛔ Aucune valeur par défaut, comme `LecteursDirects` : un test qui ne les fournit pas ne
/// compile pas, au lieu de lire le Trousseau et d'appeler le réseau de la machine qui le lance.
///
/// La présence d'une clé **est** le consentement : elle n'existe que parce que l'utilisateur
/// l'a collée, et la retirer l'éteint. Sans clé, rien n'est lu ni envoyé.
struct LecteursClesLecture: Sendable {
    var etatAnthropic: @Sendable () async -> EtatCleAnthropic
    var releverAnthropic: @Sendable (EnregistrementAnthropic) async -> ReleveCleAnthropic
    var etatAWS: @Sendable () async -> EtatCleAWS
    var releverAWS: @Sendable (EnregistrementAWS) async -> ReleveBudget
    var etatAzure: @Sendable () async -> EtatCleAzure
    var releverAzure: @Sendable (EnregistrementAzure) async -> ReleveBudget

    static func systeme(magasin: MagasinClesLecture, session: URLSession) -> LecteursClesLecture {
        LecteursClesLecture(
            etatAnthropic: { EtatCleAnthropic.depuis(await magasin.attribut(.anthropicEntreprise)) },
            releverAnthropic: { enregistrement in
                guard case .present(let donnees) = await magasin.secret(.anthropicEntreprise),
                      let texte = String(data: donnees, encoding: .utf8),
                      // La garde de saisie, une seconde fois : un élément retouché au Trousseau
                      // ne fait pas partir une clé que la saisie aurait refusée.
                      case .success(let cle) = DepenseAnthropicEntreprise.valider(cle: texte)
                else { return .indetermine }
                return await DepenseAnthropicEntreprise.relever(cle: cle, enregistrement: enregistrement,
                                                                session: session)
            },
            etatAWS: { EtatCleAWS.depuis(await magasin.attribut(.awsBedrock)) },
            releverAWS: { enregistrement in
                // `IdentiteAWS.decoder` repasse par la garde de saisie.
                guard case .present(let donnees) = await magasin.secret(.awsBedrock),
                      let identite = IdentiteAWS.decoder(donnees)
                else { return .echec(.indetermine) }
                return await DepenseAWS.relever(identite, enregistrement: enregistrement, session: session)
            },
            etatAzure: { EtatCleAzure.depuis(await magasin.attribut(.azureOpenAI)) },
            releverAzure: { enregistrement in
                guard case .present(let donnees) = await magasin.secret(.azureOpenAI),
                      let secret = SecretAzure.decoder(donnees)
                else { return .echec(.indetermine) }
                return await DepenseAzure.relever(secret, enregistrement: enregistrement, session: session)
            })
    }
}

/// Ce que le Trousseau dit des trois sources, lu ensemble et sans aucun secret.
struct EtatsClesLecture: Sendable, Equatable {
    var anthropic: EtatCleAnthropic
    var aws: EtatCleAWS
    var azure: EtatCleAzure

    static let aucune = EtatsClesLecture(anthropic: .aucune, aws: .aucune, azure: .aucune)

    static func lire(_ cles: LecteursClesLecture) async -> EtatsClesLecture {
        async let anthropic = cles.etatAnthropic()
        async let aws = cles.etatAWS()
        async let azure = cles.etatAzure()
        return await EtatsClesLecture(anthropic: anthropic, aws: aws, azure: azure)
    }

    /// Les lignes que ces clés poseront dans le panneau, avant toute requête.
    var prevues: [Ligne] {
        [LignesCleLecture.prevue(anthropic),
         LignesCleLecture.prevue(.awsBedrock, aws, budget: \.budget),
         LignesCleLecture.prevue(.azureOpenAI, azure, budget: \.budget)].compactMap { $0 }
    }
}

/// Ce qu'un cycle a établi pour la clé Claude Enterprise.
struct TourCleAnthropic: Sendable, Equatable {
    var etat: EtatCleAnthropic
    /// `nil` quand aucune requête n'est partie : pas de clé, clé illisible, ou ligne
    /// verrouillée par l'essai.
    var releve: ReleveCleAnthropic?
}

/// Ce qu'un cycle a établi pour un budget de nuage.
struct TourCleBudget<Enregistrement: Sendable & Equatable>: Sendable, Equatable {
    var etat: EtatCle<Enregistrement>
    /// `nil` quand aucune requête n'est partie.
    var releve: ReleveBudget?
}

typealias TourCleAWS = TourCleBudget<EnregistrementAWS>
typealias TourCleAzure = TourCleBudget<EnregistrementAzure>

/// Les trois sources d'un cycle.
struct ToursClesLecture: Sendable, Equatable {
    var anthropic: TourCleAnthropic
    var aws: TourCleAWS
    var azure: TourCleAzure

    static let aucune = ToursClesLecture(anthropic: TourCleAnthropic(etat: .aucune, releve: nil),
                                         aws: TourCleAWS(etat: .aucune, releve: nil),
                                         azure: TourCleAzure(etat: .aucune, releve: nil))
    /// Le cycle où le Trousseau n'a pas été regardé : rien n'est établi, rien ne s'efface.
    static let empechees = ToursClesLecture(anthropic: TourCleAnthropic(etat: .empechee, releve: nil),
                                            aws: TourCleAWS(etat: .empechee, releve: nil),
                                            azure: TourCleAzure(etat: .empechee, releve: nil))
}

/// Les dernières dépenses mesurées, une par source, pour le cycle muet. En mémoire seulement.
struct DepensesRetenues: Sendable, Equatable {
    var anthropic: DepenseMembre?
    var aws: DepenseBudget?
    var azure: DepenseBudget?
}

/// La ligne du panneau qui vit d'une clé de lecture.
enum LignesCleLecture {
    static func nom() -> String { Mots.dit("Dépense à l'API") }

    /// La ligne avant tout appel : son identifiant, sa place, et ce que l'essai en décide.
    static func prevue(_ etat: EtatCleAnthropic) -> Ligne? {
        ligne(TourCleAnthropic(etat: etat, releve: nil), precedente: nil)
    }

    /// `precedente` : la dernière dépense mesurée, gardée pour le cycle où la requête ne
    /// rapporte rien. Un refus, lui, l'efface — la clé ne lit plus, le chiffre ne vaut plus.
    static func ligne(_ tour: TourCleAnthropic, precedente: DepenseMembre?) -> Ligne? {
        let source = SourceCleLecture.anthropicEntreprise
        var compte = Compte(id: source.identifiantCompte, nom: nom(), fournisseur: .claude)
        var etat = EtatCompte()

        switch tour.etat {
        case .aucune:
            return nil
        case .empechee:
            if let precedente { poser(precedente, compte: &compte, etat: &etat) } else { etat.disponibilite = .libre }
        case .illisible:
            etat.disponibilite = .enPause(retour: nil, cause: .authentification)
        case .enregistree(let enregistrement):
            compte.courriel = enregistrement.courriel
            switch tour.releve {
            case .mesure(let depense) where depense.membre == enregistrement.membre:
                poser(depense, compte: &compte, etat: &etat)
            case .cleRefusee, .porteeRefusee, .membreAbsent:
                etat.disponibilite = .enPause(retour: nil, cause: .authentification)
            case .mesure, .indetermine, nil:
                if let precedente, precedente.membre == enregistrement.membre {
                    poser(precedente, compte: &compte, etat: &etat)
                } else {
                    etat.disponibilite = .libre
                }
            }
        }
        return Ligne(compte: compte, etat: etat)
    }

    private static func poser(_ depense: DepenseMembre, compte: inout Compte, etat: inout EtatCompte) {
        compte.courriel = depense.courriel ?? compte.courriel
        etat.disponibilite = .libre
        etat.usagesPayants = [depense.usage]
    }

    /// Ce qu'il faut garder pour le prochain cycle.
    static func retenue(_ tour: TourCleAnthropic, precedente: DepenseMembre?) -> DepenseMembre? {
        switch tour.etat {
        case .aucune, .illisible: return nil
        case .empechee: return precedente
        case .enregistree(let enregistrement):
            switch tour.releve {
            case .mesure(let depense): return depense
            case .cleRefusee, .porteeRefusee, .membreAbsent: return nil
            case .indetermine, nil: return precedente?.membre == enregistrement.membre ? precedente : nil
            }
        }
    }

    // MARK: - Budgets des nuages

    /// La ligne d'un budget avant tout appel.
    static func prevue<E>(_ source: SourceCleLecture, _ etat: EtatCle<E>, budget: (E) -> String) -> Ligne? {
        ligne(source, TourCleBudget(etat: etat, releve: nil), precedente: nil, budget: budget)
    }

    /// Le nom de la ligne est celui du budget suivi : l'en-tête du groupe dit déjà le nuage.
    static func ligne<E>(_ source: SourceCleLecture,
                         _ tour: TourCleBudget<E>,
                         precedente: DepenseBudget?,
                         budget: (E) -> String) -> Ligne? {
        let suivi = tour.etat.enregistrement.map(budget)
        let memeBudget = { (depense: DepenseBudget) in
            suivi.map { depense.budget.caseInsensitiveCompare($0) == .orderedSame } ?? true
        }
        let gardee = precedente.flatMap { memeBudget($0) ? $0 : nil }
        let compte = Compte(id: source.identifiantCompte, nom: suivi ?? gardee?.budget ?? nom(),
                            fournisseur: source.porteur)
        var etat = EtatCompte()

        switch tour.etat {
        case .aucune:
            return nil
        case .empechee:
            if let gardee { etat.usagesPayants = [gardee.usage] }
            etat.disponibilite = .libre
        case .illisible:
            etat.disponibilite = .enPause(retour: nil, cause: .authentification)
        case .enregistree:
            switch tour.releve {
            case .mesure(let depense) where memeBudget(depense):
                etat.disponibilite = .libre
                etat.usagesPayants = [depense.usage]
            case .echec(let echec) where !echec.silencieux:
                etat.disponibilite = .enPause(retour: nil, cause: .authentification)
            case .mesure, .echec, nil:
                etat.disponibilite = .libre
                if let gardee { etat.usagesPayants = [gardee.usage] }
            }
        }
        return Ligne(compte: compte, etat: etat)
    }

    static func retenue<E>(_ tour: TourCleBudget<E>, precedente: DepenseBudget?, budget: (E) -> String) -> DepenseBudget? {
        switch tour.etat {
        case .aucune, .illisible: return nil
        case .empechee: return precedente
        case .enregistree(let enregistrement):
            let suivi = budget(enregistrement)
            let meme = { (depense: DepenseBudget) in depense.budget.caseInsensitiveCompare(suivi) == .orderedSame }
            switch tour.releve {
            case .mesure(let depense): return meme(depense) ? depense : nil
            case .echec(let echec) where !echec.silencieux: return nil
            case .echec, nil: return precedente.flatMap { meme($0) ? $0 : nil }
            }
        }
    }

    /// Les lignes d'un cycle, une par source qui a une clé.
    static func lignes(_ tours: ToursClesLecture, retenues: DepensesRetenues) -> [Ligne] {
        [ligne(tours.anthropic, precedente: retenues.anthropic),
         ligne(.awsBedrock, tours.aws, precedente: retenues.aws, budget: \.budget),
         ligne(.azureOpenAI, tours.azure, precedente: retenues.azure, budget: \.budget)].compactMap { $0 }
    }

    static func retenues(_ tours: ToursClesLecture, precedentes: DepensesRetenues) -> DepensesRetenues {
        DepensesRetenues(anthropic: retenue(tours.anthropic, precedente: precedentes.anthropic),
                         aws: retenue(tours.aws, precedente: precedentes.aws, budget: \.budget),
                         azure: retenue(tours.azure, precedente: precedentes.azure, budget: \.budget))
    }

    /// À la place de son groupe, après la dernière ligne qui le partage : `Fusion` range les
    /// lignes dans l'ordre de `Fournisseur.allCases`, et les nuages viennent après.
    static func inserer(_ ligne: Ligne, dans lignes: [Ligne]) -> [Ligne] {
        let cible = ligne.compte.groupe.rang
        var resultat = lignes.filter { $0.id != ligne.id }
        let index = resultat.firstIndex { $0.compte.groupe.rang > cible } ?? resultat.endIndex
        resultat.insert(ligne, at: index)
        return resultat
    }
}
