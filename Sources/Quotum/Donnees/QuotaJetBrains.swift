import Foundation

/// Ce que le fichier de quota d'un IDE JetBrains établit, et lequel l'a écrit.
///
/// ⛔ **Aucune identité.** Le fichier ne porte ni courriel, ni identifiant de compte, ni
/// organisation : la ligne est anonyme, un seul compte par Mac. Deux IDE connectés à deux
/// comptes différents ne se distinguent pas — seul le plus récent est retenu.
struct MesureJetBrains: Sendable, Equatable {
    /// Une fenêtre exactement : le fichier n'en publie qu'une.
    var quota: Quota
    /// La date de modification du fichier. Le fichier ne porte aucun horodatage de la
    /// mesure : `quotaInfo.until` est la fin de l'abonnement, `nextRefill.next` la
    /// prochaine recharge. C'est donc la seule date qui dise quand l'IDE a écrit ce qu'il
    /// savait — voir `QuotaJetBrains` pour ce qu'elle vaut.
    var mesureA: Date
    /// Le dossier de configuration de l'IDE qui a écrit le fichier, tel qu'il est nommé sur
    /// le disque : « IntelliJIdea2025.3 », « PyCharm2025.2 », « AndroidStudio2025.1 ».
    var ide: String
    var fichier: URL
}

enum ReleveJetBrains: Sendable, Equatable {
    case releve(MesureJetBrains)
    /// Au moins un fichier de quota existe, mais aucun ne donne de fenêtre : illisible,
    /// trop gros, malformé, ou sans `quotaInfo` exploitable.
    case indetermine
    /// Aucun fichier de quota : aucun IDE JetBrains, ou l'assistant IA n'y a jamais servi.
    case aucun
}

/// Les trois gestes de disque dont le lecteur a besoin, injectés.
///
/// ⛔ Aucune valeur par défaut nulle part : un appelant qui oublie de câbler le disque ne
/// compile pas, au lieu de lire le poste réel en silence. Le disque réel est `.reel`, et
/// seul `Inventaire` doit le passer.
struct DisqueJetBrains: Sendable {
    /// Les noms des entrées d'un dossier ; `nil` s'il n'existe pas ou ne se lit pas.
    var entrees: @Sendable (URL) -> [String]?
    /// La date de modification d'un **fichier ordinaire** ; `nil` pour un chemin absent, un
    /// lien symbolique, un tube ou un dossier.
    var modification: @Sendable (URL) -> Date?
    /// Le contenu, borné à la taille donnée ; `nil` au-delà, ou s'il ne se lit pas.
    var lire: @Sendable (URL, Int) -> Data?

    static let reel = DisqueJetBrains(
        entrees: { url in try? FileManager.default.contentsOfDirectory(atPath: url.path) },
        modification: { url in
            // `attributesOfItem` ne suit pas un lien symbolique : il est écarté ici, avant
            // que `LectureFichier`, qui le suivrait, ne l'ouvre.
            guard let attributs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributs[.type] as? FileAttributeType == .typeRegular else { return nil }
            return attributs[.modificationDate] as? Date
        },
        lire: { url, taille in try? LectureFichier.lire(url, tailleMaximale: taille) }
    )
}

/// Lecture du quota de JetBrains AI dans le fichier XML que l'IDE tient à jour.
/// **Zéro réseau, aucune écriture.**
///
/// `~/Library/Application Support/JetBrains/<Produit><version>/options/AIAssistantQuotaManager2.xml`,
/// et `~/Library/Application Support/Google/AndroidStudio<version>/…` pour Android Studio.
/// Le fichier n'existe qu'une fois l'assistant IA utilisé dans cet IDE.
///
/// Forme lue : `<component name="AIAssistantQuotaManager2">` porte deux
/// `<option name="…" value="…"/>` dont la valeur est un objet JSON échappé en entités XML.
/// - `quotaInfo` : `current` et `maximum` (nombres écrits en chaînes), `until` (fin de
///   l'abonnement, **pas** l'échéance), `tariffQuota`.
/// - `nextRefill` : `next` (ISO 8601, la prochaine recharge — l'équivalent de `resets_at`),
///   `duration` ou `tariff.duration` (`PT720H`).
///
/// **Plusieurs IDE, plusieurs versions** : chaque sous-dossier des deux racines qui porte le
/// fichier est un candidat. Le retenu est celui dont le fichier a été **modifié le plus
/// récemment**, à égalité le chemin le plus petit dans l'ordre lexicographique — l'ordre ne
/// dépend donc jamais de celui que rend le système de fichiers. Un candidat qui ne donne
/// aucune fenêtre cède la place au suivant : le plus récent qui se lit l'emporte, et son âge
/// s'affiche.
///
/// ⚠️ **L'âge est celui de l'écriture, pas celui de la mesure.** Un IDE fermé n'écrit plus
/// rien, et la date vieillit honnêtement. Mais la plateforme IntelliJ ne réécrit un fichier
/// d'options que lorsque son contenu change : un IDE ouvert qui revoit le serveur sans que
/// rien n'ait bougé laisse une date plus ancienne que sa dernière vérification. Non mesuré
/// sur cette machine, qui n'a aucun IDE JetBrains.
///
/// ⚠️ La consommation est `current / maximum`. `tariffQuota.available` n'est pas lu : la
/// relation entre lui et `maximum − current` n'est établie par aucune réponse réelle, et un
/// restant qu'on inverserait à tort afficherait un compte plein comme vide.
enum QuotaJetBrains {
    static let nomFichier = "AIAssistantQuotaManager2.xml"
    static let composant = "AIAssistantQuotaManager2"
    /// Le fichier réel tient en quelques centaines d'octets.
    static let tailleMaximale = 256 * 1024
    /// Par racine. Au-delà, le dossier n'est pas celui d'un poste ordinaire.
    static let dossiersMaximum = 256
    /// Une durée publiée qui n'est pas d'un mois : la fenêtre existe, sans période nommée.
    static let libellePeriodeInconnue = "Fenêtre en cours"

    static func racines(accueil: URL) -> [URL] {
        let support = accueil.appendingPathComponent("Library/Application Support", isDirectory: true)
        return [support.appendingPathComponent("JetBrains", isDirectory: true),
                support.appendingPathComponent("Google", isDirectory: true)]
    }

    static func fichier(dossierIDE: URL) -> URL {
        dossierIDE.appendingPathComponent("options", isDirectory: true).appendingPathComponent(nomFichier)
    }

    /// Hors du fil principal : le panneau reste dessinable pendant la lecture.
    static func relever(accueil: URL, disque: DisqueJetBrains) async -> ReleveJetBrains {
        let racines = racines(accueil: accueil)
        return await HorsFil.executer { releverSansAttendre(racines: racines, disque: disque) }
    }

    static func releverSansAttendre(racines: [URL], disque: DisqueJetBrains) -> ReleveJetBrains {
        let trouves = candidats(racines: racines, disque: disque)
        guard !trouves.isEmpty else { return .aucun }
        for candidat in trouves {
            guard let donnees = disque.lire(candidat.fichier, tailleMaximale) else {
                Journal.donnees.notice("JetBrains : fichier de quota illisible ou trop gros (\(candidat.ide, privacy: .public))")
                continue
            }
            guard let quota = decoder(donnees) else {
                Journal.donnees.notice("JetBrains : fichier de quota sans fenêtre lisible (\(candidat.ide, privacy: .public))")
                continue
            }
            return .releve(MesureJetBrains(quota: quota,
                                           mesureA: candidat.modifieA,
                                           ide: candidat.ide,
                                           fichier: candidat.fichier))
        }
        return .indetermine
    }

    struct Candidat: Sendable, Equatable {
        var ide: String
        var fichier: URL
        var modifieA: Date
    }

    /// Du plus récent au plus ancien, puis par chemin : un ordre total, qui ne dépend pas de
    /// celui des entrées du dossier.
    static func candidats(racines: [URL], disque: DisqueJetBrains) -> [Candidat] {
        var trouves: [Candidat] = []
        for racine in racines {
            let noms = (disque.entrees(racine) ?? [])
                .filter { !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("/") }
                .sorted()
                .prefix(dossiersMaximum)
            for nom in noms {
                let url = fichier(dossierIDE: racine.appendingPathComponent(nom, isDirectory: true))
                guard let modifieA = disque.modification(url) else { continue }
                trouves.append(Candidat(ide: nom, fichier: url, modifieA: modifieA))
            }
        }
        return trouves.sorted {
            $0.modifieA != $1.modifieA ? $0.modifieA > $1.modifieA : $0.fichier.path < $1.fichier.path
        }
    }

    // MARK: - Analyse pure

    /// La fenêtre que le fichier publie, ou `nil` : XML refusé ou malformé, composant ou
    /// `quotaInfo` absent, consommation ou plafond illisible, négatif ou non fini, plafond nul.
    ///
    /// ⛔ Aucune valeur de repli : un `current` manquant n'est pas zéro — ce serait une
    /// grille pleine, feu vert pour un travail qui échouera.
    static func decoder(_ donnees: Data) -> Quota? {
        guard let valeurs = analyserXML(donnees),
              let brut = valeurs.quotaInfo, !brut.isEmpty,
              let info = try? JSONDecoder().decode(InfoQuota.self, from: Data(brut.utf8)),
              let consomme = info.consomme?.valeur, consomme >= 0,
              let maximum = info.maximum?.valeur, maximum > 0 else { return nil }

        // Un `nextRefill` illisible ne fait pas tomber la mesure : la fenêtre reste, sans
        // échéance — ce que le panneau sait dire.
        let recharge = valeurs.nextRefill
            .flatMap { $0.isEmpty ? nil : try? JSONDecoder().decode(Recharge.self, from: Data($0.utf8)) }
        let periode = periode(publiee: recharge?.duree)
        guard let fenetre = Fenetre(libelle: periode.libelle,
                                    sorte: periode.sorte,
                                    utilisation: consomme / maximum * 100,
                                    seRechargeA: recharge?.prochaine,
                                    duree: periode.duree) else { return nil }
        return Quota(fenetre)
    }

    /// ⚠️ **`.mois`, pas `.glissante`.** Le fichier décrit une **recharge à date fixe** —
    /// `next`, d'une durée `PT720H` —, pas une consommation qui s'efface au fil de l'eau :
    /// tout le crédit revient d'un coup à l'échéance. C'est un cycle d'environ un mois, au
    /// même titre que celui de Cursor ou d'Augment, et `.glissante` est de plus une sorte
    /// **courte**, qui ferait d'une période de trente jours une fenêtre de la journée.
    /// Sans durée publiée, ou illisible, `.mois` reste la convention (forme relevée chez un
    /// tiers : `PT720H`). Une durée lisible qui n'est pas d'un mois ne se fait pas passer
    /// pour un mois : `.cycle`, sans période nommée.
    static func periode(publiee: String?) -> (libelle: String, sorte: Fenetre.Sorte, duree: TimeInterval?) {
        guard let publiee, let secondes = duree(iso8601: publiee) else {
            return (Fenetre.libelleMois, .mois, nil)
        }
        let jour: TimeInterval = 86_400
        if (28 * jour...31 * jour).contains(secondes) {
            return (Fenetre.libelleMois, .mois, secondes)
        }
        return (libellePeriodeInconnue, .cycle, secondes)
    }

    /// `P<n>D`, `PT<n>H`, `PT<n>M`, `PT<n>S` et leurs combinaisons, en entiers. Rien d'autre :
    /// ni année ni mois, dont la durée n'est pas fixe.
    static func duree(iso8601 texte: String) -> TimeInterval? {
        let motif = /^P(?:([0-9]{1,6})D)?(?:T(?=[0-9])(?:([0-9]{1,7})H)?(?:([0-9]{1,9})M)?(?:([0-9]{1,10})S)?)?$/
        guard let correspondance = try? motif.wholeMatch(in: texte) else { return nil }
        let (_, jours, heures, minutes, secondes) = correspondance.output
        guard jours != nil || heures != nil || minutes != nil || secondes != nil else { return nil }
        func valeur(_ partie: Substring?) -> Double { partie.flatMap { Double($0) } ?? 0 }
        let total = valeur(jours) * 86_400 + valeur(heures) * 3_600 + valeur(minutes) * 60 + valeur(secondes)
        return total > 0 ? total : nil
    }

    struct ValeursXML: Sendable, Equatable {
        var quotaInfo: String?
        var nextRefill: String?
    }

    /// Les deux valeurs, entités XML déjà résolues par l'analyseur, ou `nil`.
    ///
    /// ⛔ **Aucune DTD.** Le fichier de l'IDE n'en porte jamais ; un document qui en déclare
    /// une est refusé avant l'analyse — ni entité externe (lecture d'un fichier arbitraire,
    /// requête sortante), ni entité interne (expansion exponentielle). L'analyseur n'en
    /// résout de toute façon aucune, et refuse encore toute déclaration qui passerait.
    /// Un document qui n'est pas de l'UTF-8 est refusé aussi : un encodage sur deux octets
    /// cacherait la DTD à la recherche d'octets.
    ///
    /// Un composant ou une option en double est refusé : deux valeurs contradictoires ne
    /// désignent pas laquelle croire.
    static func analyserXML(_ donnees: Data) -> ValeursXML? {
        guard String(data: donnees, encoding: .utf8) != nil,
              donnees.range(of: Data("<!DOCTYPE".utf8)) == nil,
              donnees.range(of: Data("<!ENTITY".utf8)) == nil else { return nil }
        let analyseur = XMLParser(data: donnees)
        analyseur.shouldResolveExternalEntities = false
        analyseur.shouldProcessNamespaces = false
        analyseur.shouldReportNamespacePrefixes = false
        let delegue = DelegueXML(composant: composant)
        analyseur.delegate = delegue
        guard analyseur.parse(), !delegue.refuse else { return nil }
        return ValeursXML(quotaInfo: delegue.quotaInfo, nextRefill: delegue.nextRefill)
    }

    private final class DelegueXML: NSObject, XMLParserDelegate {
        let composant: String
        var quotaInfo: String?
        var nextRefill: String?
        var refuse = false
        private var profondeur = 0
        private var profondeurComposant: Int?
        private var composantsVus = 0

        init(composant: String) { self.composant = composant }

        private func refuser(_ analyseur: XMLParser) {
            refuse = true
            analyseur.abortParsing()
        }

        func parser(_ analyseur: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            profondeur += 1
            if element == "component", attributes["name"] == composant {
                composantsVus += 1
                guard composantsVus == 1 else { return refuser(analyseur) }
                profondeurComposant = profondeur
                return
            }
            guard let parent = profondeurComposant, profondeur == parent + 1, element == "option" else { return }
            // Une option sans `value` compte comme vue : un double reste détectable, et
            // une valeur vide se lit comme absente.
            let valeur = attributes["value"] ?? ""
            switch attributes["name"] {
            case "quotaInfo":
                guard quotaInfo == nil else { return refuser(analyseur) }
                quotaInfo = valeur
            case "nextRefill":
                guard nextRefill == nil else { return refuser(analyseur) }
                nextRefill = valeur
            default:
                break
            }
        }

        func parser(_ analyseur: XMLParser, didEndElement element: String, namespaceURI: String?,
                    qualifiedName: String?) {
            if profondeurComposant == profondeur { profondeurComposant = nil }
            profondeur -= 1
        }

        func parser(_ analyseur: XMLParser, foundInternalEntityDeclarationWithName nom: String, value: String?) {
            refuser(analyseur)
        }

        func parser(_ analyseur: XMLParser, foundExternalEntityDeclarationWithName nom: String,
                    publicID: String?, systemID: String?) {
            refuser(analyseur)
        }

        func parser(_ analyseur: XMLParser, foundUnparsedEntityDeclarationWithName nom: String,
                    publicID: String?, systemID: String?, notationName: String?) {
            refuser(analyseur)
        }

        func parser(_ analyseur: XMLParser, resolveExternalEntityName nom: String, systemID: String?) -> Data? {
            refuser(analyseur)
            return nil
        }
    }

    /// Un nombre publié, en chaîne (`"7478.3"`, la forme relevée) ou en nombre JSON. `valeur`
    /// vaut `nil` quand il n'est pas un nombre décimal fini : `Double` accepterait sinon
    /// `"nan"`, `"inf"` ou `"0x10"`.
    private struct NombrePublie: Decodable {
        let valeur: Double?

        init(from decodeur: Decoder) throws {
            let conteneur = try decodeur.singleValueContainer()
            if let texte = try? conteneur.decode(String.self) {
                valeur = Self.lire(texte)
            } else if let nombre = try? conteneur.decode(Double.self), nombre.isFinite {
                valeur = nombre
            } else {
                valeur = nil
            }
        }

        private static func lire(_ texte: String) -> Double? {
            let coupe = texte.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !coupe.isEmpty,
                  coupe.allSatisfy({ "0123456789.+-eE".contains($0) }),
                  let nombre = Double(coupe), nombre.isFinite else { return nil }
            return nombre
        }
    }

    private struct InfoQuota: Decodable {
        var consomme: NombrePublie?
        var maximum: NombrePublie?

        enum CodingKeys: String, CodingKey {
            case consomme = "current"
            case maximum
        }

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            consomme = (try? c.decodeIfPresent(NombrePublie.self, forKey: .consomme)) ?? nil
            maximum = (try? c.decodeIfPresent(NombrePublie.self, forKey: .maximum)) ?? nil
        }
    }

    private struct Recharge: Decodable {
        var prochaine: Date?
        var duree: String?

        enum CodingKeys: String, CodingKey {
            case prochaine = "next"
            case duree = "duration"
            case tarif = "tariff"
        }

        enum ClesTarif: String, CodingKey {
            case duree = "duration"
        }

        init(from decodeur: Decoder) throws {
            let c = try decodeur.container(keyedBy: CodingKeys.self)
            prochaine = ((try? c.decodeIfPresent(String.self, forKey: .prochaine)) ?? nil)
                .flatMap(Horodatage.analyser)
            let tarif = try? c.nestedContainer(keyedBy: ClesTarif.self, forKey: .tarif)
            duree = ((try? c.decodeIfPresent(String.self, forKey: .duree)) ?? nil)
                ?? ((try? tarif?.decodeIfPresent(String.self, forKey: .duree)) ?? nil)
        }
    }
}
