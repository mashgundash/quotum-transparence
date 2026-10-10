import Foundation

/// Ce qu'un fichier `plan-usage-history.json` dit d'une organisation : le dernier
/// échantillon qu'elle y a écrit, et l'heure à laquelle il l'a été.
///
/// ⚠️ Aucune échéance : les échantillons ne portent pas de `resets_at`, et le `Quota`
/// qui en sort n'a donc pas de `seRechargeA`. Seule la durée de chaque fenêtre est connue
/// et déclarée : une fenêtre mesurée à t s'est rechargée au plus tard à t + sa durée, ce
/// que le panneau dit « au plus tard », puis « avant », jamais comme une heure exacte.
struct MesureHistoriquePlan: Sendable, Equatable {
    var organisationIdentifiant: String
    /// `nil` quand aucun échantillon de l'organisation ne porte de fenêtre lisible, mais
    /// qu'un échantillon porte la part payante : celle-ci se transmet seule.
    var quota: Quota?
    /// L'heure du dernier échantillon à fenêtres — ou, sans fenêtre, celle de la part payante.
    var mesureA: Date
    /// La part d'usage payant (`u.xu`) : un pourcentage consommé, **sans montant, sans
    /// devise, sans plafond** — son `unite` reste `nil`, en prêter une inventerait une
    /// donnée. `nil` quand aucun échantillon de l'organisation ne porte `u.xu`, ce qui
    /// n'est pas zéro.
    ///
    /// ⚠️ L'échelle 0-100 est celle de `fh` et `sd` dans le même objet, et de l'`utilization`
    /// d'`extra_usage` côté API ; la valeur n'a jamais été vue qu'à 0, où l'échelle ne se lit pas.
    ///
    /// ⛔ Sa date est celle de l'échantillon qui l'a publiée, jamais celle du dernier
    /// échantillon de l'organisation : `xu` n'est présent que dans une minorité d'entre eux,
    /// et rajeunir la part sur l'échantillon suivant la dirait vue à une heure où personne
    /// ne l'a lue.
    var usagePayant: UsagePayant? = nil
}

/// Lecture de `<dossier de données>/plan-usage-history.json`, écrit par l'application
/// de bureau de Claude. C'est la seule source de niveau pour un compte que ni le
/// Trousseau ni un proxy ne mesure.
///
/// ⚠️ Elle ne porte des données que si **cette** application-là a tourné : le fichier
/// d'un bundle rarement ouvert compte peu d'échantillons, quand celui du profil par
/// défaut, ouvert tous les jours, en compte beaucoup plus. Un bundle jamais ouvert n'a
/// donc aucune mesure, et c'est un cas ordinaire.
///
/// ⛔ Le dossier du profil par défaut n'est le dossier de données d'aucun bundle : il
/// appartient au compte du dernier `/login`, que le Trousseau mesure déjà exactement.
/// Le lire « pour avoir plus de données » lui fabriquerait une seconde ligne.
enum HistoriquePlanClaude {
    static let nom = "plan-usage-history.json"

    /// Les durées des deux fenêtres que les échantillons nomment `fh` et `sd`, déclarées par
    /// leur clé et jamais déduites du libellé.
    static let dureeCinqHeures: TimeInterval = 5 * 3600
    static let dureeSeptJours: TimeInterval = 7 * 24 * 3600

    static func fichier(dataDir: String) -> URL {
        URL(fileURLWithPath: dataDir, isDirectory: true).appendingPathComponent(nom)
    }

    /// Ce qui dit qu'un fichier n'a pas bougé.
    struct Signature: Sendable, Equatable {
        var modifieA: Date
        var taille: Int
    }

    struct Entree: Sendable, Equatable {
        var signature: Signature
        var mesures: [MesureHistoriquePlan]
    }

    /// Les mesures de chaque compte local de Claude, rangées sous son dossier de
    /// données. La lecture sort du fil principal : le panneau doit rester dessinable
    /// pendant qu'elle a lieu.
    static func mesures(comptesLocaux: [CompteLocal],
                        cache: CacheHistoriquePlan = .partage) async -> [String: [MesureHistoriquePlan]] {
        let dossiers = comptesLocaux.filter { $0.fournisseur == .claude }
            .map(\.dataDir)
            .filter { !$0.isEmpty }
        guard !dossiers.isEmpty else {
            await cache.enregistrer([:])
            return [:]
        }
        let connues = await cache.entrees()
        let relues = await HorsFil.executer { relire(dossiers: dossiers, connues: connues) }
        await cache.enregistrer(relues)
        return relues.mapValues(\.mesures)
    }

    // MARK: - Lecture du disque

    private static func relire(dossiers: [String],
                               connues: [String: Entree]) -> [String: Entree] {
        var sortie: [String: Entree] = [:]
        for dossier in dossiers {
            let url = fichier(dataDir: dossier)
            guard let signature = signature(de: url) else { continue }
            if let connue = connues[dossier], connue.signature == signature {
                sortie[dossier] = connue
                continue
            }
            guard let donnees = try? Data(contentsOf: url) else { continue }
            // Un fichier illisible est mis en cache lui aussi, avec ses zéro mesure :
            // le redécoder à chaque tour ne le rendrait pas plus lisible.
            sortie[dossier] = Entree(signature: signature, mesures: mesures(donnees: donnees))
        }
        return sortie
    }

    /// ⚠️ Le contrôle de type précède toute ouverture, et ce n'est pas une précaution
    /// de principe : un tube nommé porté par ce chemin ferait bloquer `Data(contentsOf:)`
    /// jusqu'à ce qu'un écrivain se présente — jamais, en pratique. Le rafraîchissement
    /// ne rendrait plus la main et l'inventaire resterait figé pour de bon. Un lien
    /// symbolique pose un autre problème, plus discret : `attributesOfItem` ne le suit
    /// pas alors que la lecture le suit, si bien que la signature décrirait un fichier
    /// et le cache en garderait un autre.
    private static func signature(de url: URL) -> Signature? {
        guard let attributs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributs[.type] as? FileAttributeType == .typeRegular,
              let modifieA = attributs[.modificationDate] as? Date,
              let taille = attributs[.size] as? Int else { return nil }
        return Signature(modifieA: modifieA, taille: taille)
    }

    // MARK: - Analyse pure

    private struct Contenu: Decodable {
        var echantillons: [Echantillon] = []

        enum CodingKeys: String, CodingKey {
            case echantillons = "samples"
        }

        /// `version` n'est pas modélisé, et aucun champ inconnu ne l'est : un numéro de
        /// version que Quotum ne connaît pas ne change rien à des échantillons dont la
        /// forme, elle, est vérifiée champ par champ.
        init(from decodeur: Decoder) throws {
            let boite = try decodeur.container(keyedBy: CodingKeys.self)
            echantillons = ((try? boite.decodeIfPresent([Echantillon].self,
                                                        forKey: .echantillons)) ?? nil) ?? []
        }
    }

    private struct Echantillon: Decodable {
        var horodatage: Date?
        var organisation: String?
        var cinqHeures: Double?
        var septJours: Double?
        var usagePayant: Double?

        enum CodingKeys: String, CodingKey {
            case horodatage = "t"
            case organisation = "org"
            case utilisation = "u"
        }

        enum ClesUtilisation: String, CodingKey {
            case cinqHeures = "fh"
            case septJours = "sd"
            case usagePayant = "xu"
        }

        /// Chaque champ est lu pour lui seul. `JSONDecoder` abandonne le corps entier
        /// dès qu'un élément le fait échouer : un seul échantillon mal formé — ou
        /// portant un littéral que `Double` ne sait pas représenter — emporterait
        /// sinon les centaines d'autres du même fichier.
        init(from decodeur: Decoder) throws {
            guard let boite = try? decodeur.container(keyedBy: CodingKeys.self) else { return }
            horodatage = ((try? boite.decodeIfPresent(Horodatage.self, forKey: .horodatage)) ?? nil)?.date
            organisation = (try? boite.decodeIfPresent(String.self, forKey: .organisation)) ?? nil
            guard let utilisation = try? boite.nestedContainer(keyedBy: ClesUtilisation.self,
                                                              forKey: .utilisation) else { return }
            cinqHeures = (try? utilisation.decodeIfPresent(Double.self, forKey: .cinqHeures)) ?? nil
            septJours = (try? utilisation.decodeIfPresent(Double.self, forKey: .septJours)) ?? nil
            usagePayant = (try? utilisation.decodeIfPresent(Double.self, forKey: .usagePayant)) ?? nil
        }
    }

    /// Le dernier échantillon de chaque organisation, dans l'ordre où elles paraissent.
    ///
    /// ⚠️ Le groupement n'est pas un raffinement : un dossier de données de cette
    /// machine porte **deux** organisations dans un seul fichier. Présumer un compte
    /// par fichier afficherait le niveau de l'une sous le nom de l'autre.
    ///
    /// ⛔ Aucune fenêtre n'est inventée pour remplir un gabarit : un échantillon dont
    /// les deux valeurs tombent ne produit aucune mesure, et un `Quota` peut n'en
    /// porter qu'une — ce que le modèle sait déjà représenter.
    ///
    /// La part d'usage payant suit sa propre règle : la dernière **publiée** par
    /// l'organisation, avec l'heure de l'échantillon qui la portait. Une organisation qui
    /// n'a qu'elle la transmet seule, avec un quota nul — aucune fenêtre n'est fabriquée.
    static func mesures(donnees: Data) -> [MesureHistoriquePlan] {
        guard let contenu = try? JSONDecoder().decode(Contenu.self, from: donnees) else { return [] }
        var dernieres: [String: MesureHistoriquePlan] = [:]
        var ordre: [String] = []
        var partsPayantes: [String: UsagePayant] = [:]
        for echantillon in contenu.echantillons {
            guard let organisation = nonVide(echantillon.organisation),
                  let mesureA = echantillon.horodatage else { continue }
            if let part = echantillon.usagePayant.flatMap({ partPayante($0, mesureA: mesureA) }),
               partsPayantes[organisation].map({ $0.mesureA <= mesureA }) ?? true {
                if partsPayantes[organisation] == nil, dernieres[organisation] == nil { ordre.append(organisation) }
                partsPayantes[organisation] = part
            }
            let fenetres = [echantillon.cinqHeures.flatMap { Fenetre.cinqHeures(utilisation: $0, duree: dureeCinqHeures) },
                            echantillon.septJours.flatMap { Fenetre.septJours(utilisation: $0, duree: dureeSeptJours) }]
                .compactMap { $0 }
            guard !fenetres.isEmpty else { continue }
            if let deja = dernieres[organisation], deja.mesureA > mesureA { continue }
            if dernieres[organisation] == nil, partsPayantes[organisation] == nil { ordre.append(organisation) }
            dernieres[organisation] = MesureHistoriquePlan(organisationIdentifiant: organisation,
                                                          quota: Quota(fenetres),
                                                          mesureA: mesureA)
        }
        return ordre.compactMap { organisation in
            let part = partsPayantes[organisation]
            guard var mesure = dernieres[organisation]
                ?? part.map({ MesureHistoriquePlan(organisationIdentifiant: organisation,
                                                   quota: nil,
                                                   mesureA: $0.mesureA) })
            else { return nil }
            mesure.usagePayant = part
            return mesure
        }
    }

    /// Les crédits d'utilisation de Claude se consomment contre un plafond : une dépense.
    /// Une valeur non finie ou négative n'est pas une part, et l'initialiseur la refuse.
    private static func partPayante(_ utilisation: Double, mesureA: Date) -> UsagePayant? {
        UsagePayant(nature: .depense,
                    unite: nil,
                    consomme: nil,
                    plafond: nil,
                    solde: nil,
                    utilisation: utilisation,
                    illimite: nil,
                    actif: nil,
                    bloque: false,
                    motif: nil,
                    echeance: nil,
                    mesureA: mesureA)
    }

    private static func nonVide(_ valeur: String?) -> String? {
        guard let coupe = valeur?.trimmingCharacters(in: .whitespacesAndNewlines), !coupe.isEmpty else {
            return nil
        }
        return coupe
    }
}

/// Ce qui évite de redécoder un fichier qui n'a pas bougé. Celui du profil par défaut
/// fait 34 Ko, l'application de bureau le réécrit toutes les cinq à quinze minutes, et
/// la boucle de statut tourne bien plus vite.
actor CacheHistoriquePlan {
    static let partage = CacheHistoriquePlan()

    private var entreesParDossier: [String: HistoriquePlanClaude.Entree] = [:]

    func entrees() -> [String: HistoriquePlanClaude.Entree] { entreesParDossier }

    /// Un dossier absent de la relecture sort du cache : un bundle supprimé ne garde
    /// pas sa mesure en mémoire jusqu'au redémarrage.
    func enregistrer(_ relues: [String: HistoriquePlanClaude.Entree]) {
        entreesParDossier = relues
    }
}
