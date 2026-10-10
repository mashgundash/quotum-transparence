import Foundation

/// La porte de Muse Code et la dernière mesure qu'elle a laissé passer, **uniques pour l'app**.
///
/// ⛔ Chaque envoi crée une clé chez Meta (`QuotaMuse`) : une seconde `CadenceMuse` doublerait
/// le rythme. D'où une seule instance réelle, `systeme`, et la date du dernier envoi gardée
/// dans les préférences — sans elle, chaque relance de l'app enverrait une requête de plus.
///
/// Porte fermée (`.differe`), rien ne part et la dernière mesure reste la meilleure connue :
/// elle est rendue telle quelle, avec sa date, et l'âge affiché dit ce qu'elle vaut. Sans
/// mesure antérieure — l'app vient de démarrer —, rien n'est établi.
actor ReleveurMuse {
    /// Hors de `Reglages` : c'est un état de la porte, pas un choix de l'utilisateur.
    static let cleDernierEnvoi = "mesure.muse.dernierEnvoi"

    /// Une valeur absente, d'un autre type ou non finie ne ferme pas la porte.
    static func dernierEnvoi(dans memoire: UserDefaults) -> Date? {
        guard let date = memoire.object(forKey: cleDernierEnvoi) as? Date,
              date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return date
    }

    static func memoriser(_ date: Date, dans memoire: UserDefaults) {
        memoire.set(date, forKey: cleDernierEnvoi)
    }

    /// Le seul jeu réel : les préférences de l'app, le disque, le Trousseau et le réseau.
    static let systeme = ReleveurMuse(
        cadence: CadenceMuse(dernierEnvoi: dernierEnvoi(dans: .standard),
                             memoriser: { date in memoriser(date, dans: .standard) }),
        dependances: .systeme)

    private let cadence: CadenceMuse
    private let dependances: DependancesMuse
    private var dernier: ReleveMuse?

    init(cadence: CadenceMuse, dependances: DependancesMuse) {
        self.cadence = cadence
        self.dependances = dependances
    }

    func relever() async -> ReleveMuse {
        let resultat = await QuotaMuse.relever(cadence: cadence, dependances: dependances)
        let suite = Self.combiner(resultat, dernier: dernier)
        dernier = suite.dernier
        return suite.rendu
    }

    /// Ce que la ligne reçoit, et ce qu'on garde pour le prochain tour.
    ///
    /// Un envoi qui n'a rien établi ne fait pas oublier ce qu'un envoi précédent a établi —
    /// mais il ne le répète pas non plus : la ligne dit qu'on n'a rien appris.
    static func combiner(_ resultat: ReleveMuse,
                         dernier: ReleveMuse?) -> (rendu: ReleveMuse, dernier: ReleveMuse?) {
        switch resultat {
        case .differe:
            (dernier ?? .indetermine, dernier)
        case .indetermine:
            (.indetermine, dernier)
        case .releve, .reconnexionNecessaire, .sansAbonnement, .paiementRequis, .aucun:
            (resultat, resultat)
        }
    }
}
