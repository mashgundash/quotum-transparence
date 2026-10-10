import Foundation

/// Les offres que `arkcli usage plan` publie. Une offre absente de cette liste n'est jamais
/// lue : rien ne dit que ses périodes décomptent un quota de codage.
enum ProduitDoubao: String, Sendable, Equatable, CaseIterable {
    case codingPlan = "coding-plan"
    case agentPlan = "agent-plan"
    case codingPlanEquipe = "coding-plan-team"
    case agentPlanEquipe = "agent-plan-team"

    /// Le nom de l'offre sur sa ligne : un nom de produit, qui ne se traduit pas.
    var nom: String {
        switch self {
        case .codingPlan: "Coding Plan"
        case .agentPlan: "Agent Plan"
        case .codingPlanEquipe: "Coding Plan Team"
        case .agentPlanEquipe: "Agent Plan Team"
        }
    }
}

/// Une offre souscrite et les fenêtres qu'elle publie, de la plus courte à la plus longue.
struct OffreDoubao: Sendable, Equatable {
    var produit: ProduitDoubao
    var quota: Quota
}

/// Ce qu'une sortie d'`arkcli` établit. Elle ne nomme personne : aucune ancre d'identité.
struct MesureDoubao: Sendable, Equatable {
    /// Dans l'ordre de `ProduitDoubao.allCases`, une seule par produit, jamais vide.
    var offres: [OffreDoubao]
    /// Le `updated_at` le plus récent des offres mesurées, ramené à l'heure de la lecture
    /// s'il la dépasse ; l'heure de la lecture quand aucune offre n'en publie.
    var mesureA: Date
}

enum ReleveDoubao: Sendable, Equatable {
    case releve(MesureDoubao)
    /// `arkcli` répond, mais sa session est absente ou expirée : `arkcli auth login`.
    case reconnexionNecessaire
    /// Connecté, et aucune offre connue n'est souscrite.
    case aucuneOffre
    /// Rien d'établi : délai dépassé, lancement refusé, sortie tronquée ou illisible, code
    /// de sortie non nul, offre souscrite sans période lisible.
    case indetermine
    /// `arkcli` n'est à aucun des emplacements connus.
    case absent
}

/// Relevé du quota Volcengine Ark (Doubao) par le CLI officiel `arkcli`, lancé en lecture
/// seule par un `LanceurCLI` injecté.
///
/// ⛔ Le schéma de sortie a déjà varié d'une version à l'autre (`updated_at` en secondes ou
/// en millisecondes, `reset_at` en chaîne ou en nombre) : chaque champ se lit seul, et un
/// champ illisible retire sa fenêtre, jamais il n'en fabrique une.
enum QuotaDoubao {
    static let arguments = ["usage", "plan", "--format", "json"]

    /// Les emplacements où l'installation officielle (`npm i -g @volcengine/ark-cli`) pose le
    /// binaire : préfixe npm de Homebrew, préfixe npm du paquet Node officiel, et
    /// `~/.local/bin`. Liste fermée, chemins absolus, essayés dans cet ordre.
    static func emplacements(accueil: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [accueil.appendingPathComponent(".local/bin/arkcli"),
         URL(fileURLWithPath: "/opt/homebrew/bin/arkcli"),
         URL(fileURLWithPath: "/usr/local/bin/arkcli")]
    }

    /// Le paquet npm dont le binaire doit provenir, une fois ses liens symboliques résolus.
    /// ⚠️ Un autre outil peut porter le nom `arkcli` : le lanceur vérifie le chemin réel
    /// avant d'exécuter quoi que ce soit.
    static let paquetAttendu = "/node_modules/@volcengine/ark-cli/"

    static func binaireReconnu(cheminReel: String) -> Bool {
        cheminReel.hasPrefix("/") && cheminReel.contains(paquetAttendu)
    }

    /// Essaie chaque emplacement jusqu'au premier qui existe ; seul `.introuvable` fait
    /// passer au suivant.
    static func relever(lanceur: LanceurCLI,
                        emplacements: [URL],
                        maintenant: @Sendable () -> Date = { Date() }) async -> ReleveDoubao {
        for binaire in emplacements {
            let resultat = await lanceur(binaire, arguments)
            if resultat.issue == .introuvable { continue }
            return conclure(resultat, maintenant: maintenant())
        }
        return .absent
    }

    static func conclure(_ resultat: ResultatCLI, maintenant: Date) -> ReleveDoubao {
        switch resultat.issue {
        case .introuvable:
            return .absent
        case .delaiDepasse:
            Journal.donnees.notice("Doubao : arkcli n'a pas répondu dans le délai")
            return .indetermine
        case .refusee:
            Journal.donnees.notice("Doubao : lancement d'arkcli refusé")
            return .indetermine
        case .terminee(let code):
            // Une sortie coupée peut encore se décoder en JSON valide si la coupure tombe
            // entre deux offres : elle n'en dirait que la moitié.
            guard !resultat.tronquee else {
                Journal.donnees.notice("Doubao : sortie d'arkcli tronquée")
                return .indetermine
            }
            guard code == 0 else {
                Journal.donnees.notice("Doubao : arkcli a terminé avec le code \(code)")
                return demandeConnexion(resultat.sortie) ? .reconnexionNecessaire : .indetermine
            }
            return decoder(resultat.sortie, maintenant: maintenant)
        }
    }

    /// Les messages par lesquels `arkcli` dit qu'il n'a pas de session.
    static let messagesSansSession = ["not logged in", "not authenticated", "authentication required",
                                      "login required", "please login", "please log in"]

    static func demandeConnexion(_ sortie: Data) -> Bool {
        let texte = String(decoding: sortie, as: UTF8.self).lowercased()
        return messagesSansSession.contains(where: texte.contains)
    }

    // MARK: - Analyse pure

    private struct Reponse: Decodable {
        var spectateur: Spectateur?
        var elements: [Element]?

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            spectateur = try? c.decode(Spectateur.self, forKey: .spectateur)
            elements = try? c.decode([Tolerant<Element>].self, forKey: .elements).compactMap(\.valeur)
        }

        enum CodingKeys: String, CodingKey {
            case spectateur = "viewer"
            case elements = "items"
        }
    }

    private struct Spectateur: Decodable {
        var methode: String?
        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            methode = try? c.decode(String.self, forKey: .methode)
        }
        enum CodingKeys: String, CodingKey { case methode = "auth_method" }
    }

    private struct Element: Decodable {
        var produit: String?
        var souscrit: Bool?
        var periodes: [Periode]?
        var misAJourA: Date?

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            produit = try? c.decode(String.self, forKey: .produit)
            souscrit = try? c.decode(Bool.self, forKey: .souscrit)
            periodes = try? c.decode([Tolerant<Periode>].self, forKey: .periodes).compactMap(\.valeur)
            misAJourA = (try? c.decode(DateLue.self, forKey: .misAJourA))?.date
        }

        enum CodingKeys: String, CodingKey {
            case produit = "product"
            case souscrit = "subscribed"
            case periodes = "periods"
            case misAJourA = "updated_at"
        }
    }

    private struct Periode: Decodable {
        var nom: String?
        var pourcentage: Double?
        var consomme: Double?
        var dotation: Double?
        var rechargeA: Date?

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            nom = try? c.decode(String.self, forKey: .nom)
            pourcentage = try? c.decode(Double.self, forKey: .pourcentage)
            consomme = try? c.decode(Double.self, forKey: .consomme)
            dotation = try? c.decode(Double.self, forKey: .dotation)
            rechargeA = (try? c.decode(DateLue.self, forKey: .rechargeA))?.date
        }

        enum CodingKeys: String, CodingKey {
            case nom = "label"
            case pourcentage = "percent"
            case consomme = "used"
            case dotation = "total"
            case rechargeA = "reset_at"
        }

        /// `percent` est un consommé en points (0 à 100) : `used / total` le recoupe sur les
        /// sorties publiées. Il ne se calcule depuis `used` et `total` qu'en son absence.
        /// ⛔ Un négatif est écarté, pas ramené à zéro : zéro dirait la fenêtre intacte.
        /// Au-delà de 100, la valeur reste une mesure, que `Fenetre` borne.
        var utilisation: Double? {
            if let pourcentage { return pourcentage >= 0 ? pourcentage : nil }
            guard let consomme, let dotation, dotation > 0, consomme >= 0 else { return nil }
            return consomme / dotation * 100
        }
    }

    /// Un élément de tableau illisible est écarté sans faire tomber ses voisins.
    private struct Tolerant<T: Decodable>: Decodable {
        let valeur: T?
        init(from decodeur: Decoder) throws { valeur = try? T(from: decodeur) }
    }

    /// Un epoch, en secondes ou en millisecondes selon sa grandeur, ou une chaîne ISO 8601.
    private struct DateLue: Decodable {
        let date: Date?

        init(from decodeur: Decoder) throws {
            let c = try decodeur.singleValueContainer()
            if let nombre = try? c.decode(Double.self) {
                date = QuotaDoubao.date(epoch: nombre)
            } else if let texte = try? c.decode(String.self) {
                date = QuotaDoubao.date(iso: texte)
            } else {
                date = nil
            }
        }
    }

    /// 1e11 secondes tombent en l'an 5138, 1e11 millisecondes en 1973 : aucune valeur réelle
    /// ne se trouve dans la zone où les deux lectures se confondent.
    static func date(epoch: Double) -> Date? {
        guard epoch.isFinite, epoch > 0 else { return nil }
        return Date(timeIntervalSince1970: epoch >= 1e11 ? epoch / 1000 : epoch)
    }

    static func date(iso texte: String) -> Date? {
        let coupe = texte.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !coupe.isEmpty else { return nil }
        let simple = ISO8601DateFormatter()
        if let date = simple.date(from: coupe) { return date }
        let fractionnaire = ISO8601DateFormatter()
        fractionnaire.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionnaire.date(from: coupe)
    }

    /// La sorte d'une période se lit dans son nom, préfixe d'offre retiré. Un nom inconnu ne
    /// fait pas de fenêtre : lui prêter une durée serait l'inventer.
    static func sorte(nom: String) -> Fenetre.Sorte? {
        var nom = nom.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefixe in ["agent_team_", "coding_team_", "agent_"] where nom.hasPrefix(prefixe) {
            nom.removeFirst(prefixe.count)
            break
        }
        switch nom {
        case "session", "5h", "5-hour", "five_hour": return .cinqHeures
        case "weekly", "week": return .septJours
        case "monthly", "month": return .mois
        default: return nil
        }
    }

    private static func fenetre(_ periode: Periode) -> Fenetre? {
        guard let nom = periode.nom, let sorte = sorte(nom: nom) else {
            Journal.donnees.notice("Doubao : période au nom inconnu écartée")
            return nil
        }
        guard let utilisation = periode.utilisation else { return nil }
        let libelle: String
        switch sorte {
        case .cinqHeures: libelle = Fenetre.libelleCinqHeures
        case .septJours: libelle = Fenetre.libelleSeptJours
        default: libelle = Fenetre.libelleMois
        }
        return Fenetre(libelle: libelle, sorte: sorte, utilisation: utilisation, seRechargeA: periode.rechargeA)
    }

    private static let rangSorte: [Fenetre.Sorte] = [.cinqHeures, .septJours, .mois]

    static func decoder(_ donnees: Data, maintenant: Date) -> ReleveDoubao {
        guard let reponse = try? JSONDecoder().decode(Reponse.self, from: donnees) else {
            return demandeConnexion(donnees) ? .reconnexionNecessaire : .indetermine
        }
        if reponse.spectateur?.methode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none" {
            return .reconnexionNecessaire
        }
        guard let elements = reponse.elements else { return .indetermine }

        var offres: [OffreDoubao] = []
        var miseAJour: Date?
        var souscriteIllisible = false
        for produit in ProduitDoubao.allCases {
            let candidats = elements.filter {
                $0.produit?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == produit.rawValue
                    && $0.souscrit != false
            }
            guard let element = candidats.first else { continue }
            if candidats.count > 1 {
                Journal.donnees.notice("Doubao : offre \(produit.rawValue) publiée plusieurs fois, la première est gardée")
            }
            var parSorte: [Fenetre.Sorte: Fenetre] = [:]
            for periode in element.periodes ?? [] {
                guard let fenetre = fenetre(periode), parSorte[fenetre.sorte] == nil else { continue }
                parSorte[fenetre.sorte] = fenetre
            }
            let fenetres = rangSorte.compactMap { parSorte[$0] }
            guard !fenetres.isEmpty else {
                souscriteIllisible = true
                continue
            }
            offres.append(OffreDoubao(produit: produit, quota: Quota(fenetres)))
            if let date = element.misAJourA, miseAJour.map({ date > $0 }) ?? true { miseAJour = date }
        }

        // Une offre souscrite sans fenêtre lisible n'est pas une offre absente : se taire
        // laisserait croire qu'il n'y a rien à surveiller.
        guard !offres.isEmpty else { return souscriteIllisible ? .indetermine : .aucuneOffre }
        return .releve(MesureDoubao(offres: offres, mesureA: min(miseAJour ?? maintenant, maintenant)))
    }
}
