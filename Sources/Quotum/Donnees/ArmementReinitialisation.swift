import Foundation

/// Faut-il proposer une réinitialisation anticipée pour ce compte, maintenant ?
///
/// Une seule réponse pour les deux chemins : l'invite que l'utilisateur voit dans le
/// tiroir, et le mode automatique quand il est armé. Les écrire séparément les ferait
/// diverger, et l'automatisme finirait par dépenser un crédit dans une situation où
/// l'invite, elle, refuse de le proposer.
///
/// ⛔ Cette fonction n'autorise rien à elle seule : elle dit qu'une proposition a du
/// sens. Le geste humain reste obligatoire sur le chemin manuel, et le mode automatique
/// est une option que l'utilisateur doit délibérément armer.
enum ArmementReinitialisation {
    /// Au-delà de cet âge, la mesure ne décrit plus le présent.
    ///
    /// Dix minutes, soit deux tours du minuteur à son intervalle par défaut de cinq.
    /// Le pourcentage d'un compte de pool vient des en-têtes de sa dernière requête et
    /// peut dater de plusieurs heures ; dépenser un crédit là-dessus, c'est le dépenser
    /// sur un quota le plus souvent revenu tout seul — et un crédit dépensé est perdu.
    ///
    /// Le seuil est fixe et ne suit pas l'intervalle réglé : allonger le
    /// rafraîchissement désarme alors la décision au lieu d'élargir la fenêtre de tir,
    /// ce qui est le bon sens du repli pour une dépense irréversible.
    static let fraicheurMaximale: TimeInterval = 10 * 60

    /// Les deux délais réglés, avec l'invariant qui les lie posé une seconde fois ici : un
    /// appelant qui les construirait à la main ne pourrait pas donner à l'automatisme un délai
    /// plus court que celui de la proposition.
    struct Delais: Sendable, Equatable {
        let proposition: TimeInterval
        let automatique: TimeInterval

        init(propositionHeures: Int, automatiqueHeures: Int) {
            let proposition = max(0, propositionHeures)
            self.proposition = TimeInterval(proposition) * 3600
            automatique = TimeInterval(max(automatiqueHeures, proposition)) * 3600
        }
    }

    /// ⛔ La règle unique. `delaiMinimal` est le délai de la proposition pour le geste humain,
    /// celui de l'automatisme pour le mode automatique — qui n'est jamais plus court : un
    /// retour assez proche pour faire taire la proposition fait taire l'automatisme.
    static func estArme(_ ligne: Ligne, delaiMinimal: TimeInterval, maintenant: Date = .now) -> Bool {
        verdict(ligne, delaiMinimal: delaiMinimal, maintenant: maintenant) == .arme
    }

    /// Ce qui retient une ligne Codex, dit au tiroir quand il montre un crédit sans bouton.
    enum Raison: Sendable, Equatable {
        /// Aucun épuisement constaté, ou un retour déjà passé.
        case pasASec
        /// Le quota revient seul avant le délai réglé.
        case retourTropProche(Date)
        /// La constatation a vieilli, ou porte une date que l'horloge n'atteint pas encore.
        case mesureAncienne
        /// Quotum ne lit pas la connexion de ce compte, ou celle qu'il lit en mesure un autre.
        case compteNonLisible
        /// La connexion de ce compte est connue, mais sa mesure n'a pas abouti ce tour-ci.
        case mesureIndisponible
    }

    /// `nil` : la ligne est armée, ou il n'y a rien à expliquer — un autre outil, ou un
    /// compte Codex lisible sans crédit. Le même examen que `estArme`, jamais une copie.
    static func raison(_ ligne: Ligne, delaiMinimal: TimeInterval, maintenant: Date = .now) -> Raison? {
        guard case .refuse(let raison) = verdict(ligne, delaiMinimal: delaiMinimal, maintenant: maintenant)
        else { return nil }
        return raison
    }

    private enum Verdict: Equatable {
        case arme
        case refuse(Raison?)
    }

    private static func verdict(_ ligne: Ligne, delaiMinimal: TimeInterval, maintenant: Date) -> Verdict {
        // Seul OpenAI propose le mécanisme.
        guard ligne.compte.fournisseur == .chatgpt else { return .refuse(nil) }
        // ⛔ Sans le fichier dont vient le relevé, l'exécuteur ne saurait quel auth.json
        // relire : il retomberait sur celui du terminal, qui peut porter un autre compte.
        guard ligne.etat.fichierCodex != nil else {
            return .refuse(ligne.etat.releveCodexIndetermine == nil ? .compteNonLisible : .mesureIndisponible)
        }
        guard let restantes = ligne.etat.reinitialisationsDisponibles, restantes > 0 else { return .refuse(nil) }
        // ⛔ Une constatation du relevé direct, avec sa propre date — jamais une pause
        // du proxy, jamais une déduction depuis un pourcentage à 100. Une pause
        // d'authentification ou de réseau n'y entre pas : un relevé qui a abouti a
        // prouvé le jeton, et dépenser un crédit ne répare pas un jeton.
        guard let epuisement = ligne.etat.epuisementReleve else { return .refuse(.pasASec) }
        guard estFraiche(epuisement.constateA, maintenant: maintenant) else { return .refuse(.mesureAncienne) }
        // ⛔ L'échéance annoncée doit encore être devant. Une mesure peut être fraîche
        // et le quota déjà revenu : relevée à 10:54, elle dit « épuisé jusqu'à 11:00 »,
        // et il est 11:03. La fenêtre s'est rouverte toute seule entre-temps, et
        // dépenser un crédit pour la rouvrir une seconde fois le gâcherait.
        // Une échéance absente ne prouve rien et ne bloque donc pas le geste humain.
        if let retour = epuisement.retour, retour <= maintenant { return .refuse(.pasASec) }
        // ⛔ Un quota qui revient seul avant le délai réglé n'a pas à dépenser un crédit. Un
        // délai qui n'est pas un nombre ne laisse rien passer : la comparaison échoue.
        if let retour = epuisement.retour, !(retour.timeIntervalSince(maintenant) >= delaiMinimal) {
            return .refuse(.retourTropProche(retour))
        }
        // ⛔ Un relevé apparié par courriel peut décrire un autre compte que celui que la
        // rangée déclare. L'épuisement de B n'autorise pas à dépenser le crédit de A.
        if let mesure = epuisement.compte, let declare = ligne.compte.organisationIdentifiant,
           mesure.lowercased() != declare.lowercased() { return .refuse(.compteNonLisible) }
        return .arme
    }

    /// Ce qu'une dépense doit savoir, pris d'un coup, au moment où elle se décide : le
    /// geste manuel le prend au clic, l'automatisme au tour du minuteur.
    struct Instantane: Sendable, Equatable {
        var arme: Bool
        /// La réservation et la consignation portent sur elle — l'`account_id` quand il
        /// est connu, jamais l'identifiant d'affichage seul.
        var cle: String
        /// Le compte que le jeton relu devra porter. `nil` : aucun n'est connu, et seul
        /// un humain devant l'écran peut alors dépenser.
        var compte: String?
        /// L'auth.json que l'exécuteur relira, celui dont vient le relevé de la rangée.
        /// `nil` : rien n'est armé, rien ne part.
        var fichier: URL?
        var echeance: Date?
        /// Au-delà, la mesure a vieilli ou l'échéance est passée : rien ne doit plus partir,
        /// même si tout le reste a été vérifié avant les attentes.
        var valableJusqua: Date?

        /// ⛔ `fichier` n'a pas de valeur par défaut, même `nil` : un instantané fabriqué sans
        /// y penser ne doit pas compiler.
        init(arme: Bool, cle: String = "ligne:inconnue", compte: String? = nil, fichier: URL?,
             echeance: Date? = nil, valableJusqua: Date? = nil) {
            self.arme = arme
            self.cle = cle
            self.compte = compte
            self.fichier = fichier
            self.echeance = echeance
            self.valableJusqua = valableJusqua
        }

        func estValable(a maintenant: Date) -> Bool {
            guard arme, fichier != nil, let valableJusqua else { return false }
            return maintenant <= valableJusqua
        }
    }

    /// ⛔ La prise vaut jusqu'à ce que le retour entre dans le délai : une confirmation laissée
    /// ouverte ne dépense pas sur un quota qui reviendra seul avant ce délai.
    static func instantane(_ ligne: Ligne, delaiMinimal: TimeInterval, maintenant: Date = .now) -> Instantane {
        guard estArme(ligne, delaiMinimal: delaiMinimal, maintenant: maintenant),
              let epuisement = ligne.etat.epuisementReleve else {
            return Instantane(arme: false, cle: RegistreReinitialisation.cle(pour: ligne), fichier: nil)
        }
        var limite = epuisement.constateA.addingTimeInterval(fraicheurMaximale)
        if let retour = epuisement.retour { limite = min(limite, retour.addingTimeInterval(-max(0, delaiMinimal))) }
        return Instantane(arme: true,
                          cle: RegistreReinitialisation.cle(pour: ligne),
                          compte: RegistreReinitialisation.compteDe(ligne),
                          fichier: ligne.etat.fichierCodex,
                          echeance: epuisement.retour,
                          valableJusqua: limite)
    }

    /// Ce que le mode automatique exige en plus, faute d'un humain devant l'écran.
    ///
    /// ⛔ L'épisode doit être identifiable : c'est son échéance qui empêche de dépenser
    /// deux fois sur le même, d'un tour à l'autre et d'un lancement à l'autre.
    ///
    /// ⛔ Le compte mesuré doit être nommé, et être celui de la rangée : c'est lui que
    /// l'exécuteur exigera de retrouver dans `auth.json` avant d'envoyer quoi que ce soit.
    ///
    /// ⛔ Le délai est celui de l'automatisme, jamais plus court que celui de la proposition,
    /// et l'échéance doit être connue : sans elle, rien ne dit que le quota ne revient pas
    /// seul dans l'heure, et une dépense irréversible ne part pas sur une inconnue.
    static func episodeSansSurveillance(_ ligne: Ligne, delais: Delais, maintenant: Date = .now) -> Instantane? {
        let prise = instantane(ligne, delaiMinimal: delais.automatique, maintenant: maintenant)
        // Une fenêtre épuisée sans échéance — celle que le proxy a publiée après le relevé,
        // par exemple — laisse le retour inconnu, quelle que soit l'échéance du relevé.
        let epuiseeSansEcheance = ligne.etat.quota?.fenetres
            .contains { $0.utilisation >= 100 && $0.seRechargeA == nil } ?? false
        guard prise.arme, prise.echeance != nil, !epuiseeSansEcheance,
              let mesure = ligne.etat.epuisementReleve?.compte,
              let declare = ligne.compte.organisationIdentifiant,
              mesure.lowercased() == declare.lowercased() else { return nil }
        return prise
    }

    /// Une date de mesure absente ne vaut pas mesure fraîche : elle ne vaut rien du
    /// tout, et c'est un motif de refus au même titre qu'une mesure périmée.
    ///
    /// Une mesure datée d'un peu plus tard que l'horloge passe — deux horloges ne
    /// s'accordent jamais à la seconde. Au-delà d'une minute, elle a été prise avec une
    /// horloge avancée depuis corrigée, et son âge réel ne se connaît plus.
    static func estFraiche(_ mesureA: Date?, maintenant: Date = .now) -> Bool {
        guard let mesureA else { return false }
        let age = maintenant.timeIntervalSince(mesureA)
        return age >= -avanceToleree && age <= fraicheurMaximale
    }

    static let avanceToleree: TimeInterval = 60
}
