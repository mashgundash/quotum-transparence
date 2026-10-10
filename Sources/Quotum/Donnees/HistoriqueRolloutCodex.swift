import Foundation

/// Ce qu'un `CODEX_HOME` dit du niveau de son compte : la dernière mesure que le CLI
/// Codex a écrite dans ses rollouts, et l'heure à laquelle il l'a écrite.
struct MesureRolloutCodex: Sendable, Equatable {
    var quota: Quota
    var mesureA: Date
}

/// Lecture des rollouts `<CODEX_HOME>/sessions/AAAA/MM/JJ/rollout-*.jsonl`, écrits par
/// le CLI Codex à chaque tour de session. C'est la seule source de niveau pour un
/// compte ChatGPT que rien d'autre ne mesure : `auth.json` ne décrit que celui du
/// dernier `codex login`, et un compte hors du pool n'a pas davantage de proxy.
///
/// ⚠️ Elle ne porte des données que si le CLI a tourné sous ce `CODEX_HOME`-là : un
/// compte dont le terminal n'a jamais été épinglé n'a aucune mesure, et c'est un cas
/// ordinaire.
enum HistoriqueRolloutCodex {
    static let dossierSessions = "sessions"
    static let prefixeRollout = "rollout-"
    static let suffixeRollout = ".jsonl"
    static let typeTokenCount = "token_count"

    /// ⚠️ Le balayage est borné par construction, jamais par la taille de
    /// l'arborescence. `~/.codex` peut porter des milliers de rollouts et plusieurs gigaoctets, et
    /// l'auteur de mobius en mesure 50 000 pour 19 Go chez lui : énumérer récursivement
    /// `sessions/` rendrait l'ouverture du panneau tributaire de l'historique complet
    /// d'un outil tiers. Seuls les dossiers de date les plus récents sont ouverts.
    static let joursExplores = 3
    /// Une journée chargée compte une cinquantaine de rollouts sur cette machine.
    ///
    /// ⚠️ Ce plafond borne ce qui est **ouvert et lu**, pas le listage : classer les
    /// rollouts par date d'écriture suppose de connaître celle de chacun, donc de tous
    /// les énumérer. Ce coût-là reste proportionnel au contenu d'un dossier de date, et
    /// il est sans commune mesure avec celui d'ouvrir un fichier d'un mégaoctet.
    static let fichiersExplores = 40

    /// Un rollout pèse couramment un mégaoctet, et une session peut en peser dix : il
    /// se lit **par la fin**, par blocs, jamais en entier. Le dernier `token_count`
    /// tient dans les derniers kilooctets — seul le message d'un tour interrompu peut
    /// l'en éloigner, d'où la marge.
    static let tailleBloc = 64 * 1024
    static let lectureMaximale = 512 * 1024

    /// Ce qui dit qu'un rollout n'a pas bougé depuis sa dernière lecture.
    struct Signature: Sendable, Equatable {
        var modifieA: Date
        var taille: Int
    }

    struct EntreeFichier: Sendable, Equatable {
        var signature: Signature
        /// Un rollout sans mesure est mis en cache avec son absence : le rouvrir à
        /// chaque tour ne lui en ferait pas apparaître une.
        var mesure: MesureRolloutCodex?
    }

    struct Relecture: Sendable {
        var mesures: [String: MesureRolloutCodex] = [:]
        var fichiers: [String: EntreeFichier] = [:]
    }

    /// La dernière mesure de chaque compte local de ChatGPT, rangée sous son dossier
    /// de données.
    ///
    /// ⚠️ **Deux verrous distincts, et c'est la raison d'être de cette forme.** Le
    /// balayage est une fonction pure — il reçoit ce qu'on sait déjà, il rend ce qu'il
    /// a lu — exécutée hors du fil principal par `HorsFil.executer` ; l'acteur de
    /// cache n'est touché qu'avant et après, jamais pendant. Un verrou unique tenu
    /// pendant tout le parcours et partagé avec les accesseurs observables fige
    /// l'interface : mesuré chez mobius, six minutes de gel après un redémarrage.
    static func mesures(comptesLocaux: [CompteLocal],
                        cache: CacheRolloutCodex = .partage) async -> [String: MesureRolloutCodex] {
        let dossiers = comptesLocaux.filter { $0.fournisseur == .chatgpt && !$0.dataDir.isEmpty }
            .compactMap { local in local.dossiers.codexHome.map { (dataDir: local.dataDir, codexHome: $0) } }
        guard !dossiers.isEmpty else {
            await cache.enregistrer([:])
            return [:]
        }
        let connues = await cache.entrees()
        let relue = await HorsFil.executer { relire(dossiers: dossiers, connues: connues) }
        await cache.enregistrer(relue.fichiers)
        return relue.mesures
    }

    // MARK: - Lecture du disque

    /// Le `CODEX_HOME` vient de `DossiersCompte`, relu dans le lanceur : jamais redit ici.
    private static func relire(dossiers: [(dataDir: String, codexHome: String)],
                               connues: [String: EntreeFichier]) -> Relecture {
        var relue = Relecture()
        for (dataDir, codexHome) in dossiers {
            let lue = mesure(codexHome: URL(fileURLWithPath: codexHome, isDirectory: true),
                             connues: connues)
            relue.fichiers.merge(lue.fichiers) { _, neuve in neuve }
            if let mesure = lue.mesure { relue.mesures[dataDir] = mesure }
        }
        return relue
    }

    /// La dernière mesure d'un `CODEX_HOME`, et ce qu'il faut retenir des rollouts
    /// ouverts pour ne pas les relire. Rien n'est partagé ni verrouillé : tout entre
    /// par `connues` et ressort par la valeur de retour.
    static func mesure(codexHome: URL,
                       connues: [String: EntreeFichier] = [:])
        -> (mesure: MesureRolloutCodex?, fichiers: [String: EntreeFichier]) {
        let racine = codexHome.appendingPathComponent(dossierSessions, isDirectory: true)
        var fichiers: [String: EntreeFichier] = [:]
        // ⚠️ Une seule règle, et elle vaut aussi bien entre deux rollouts du même jour
        // qu'entre deux dossiers de date : la mesure dont l'horodatage est le plus
        // récent gagne. Le nom du dossier dit quand la session a commencé, pas quand
        // elle a écrit sa dernière ligne — une session reprise le lendemain écrit dans
        // le dossier de la veille, et s'arrêter au premier dossier qui rend une mesure
        // afficherait alors la plus ancienne des deux.
        var meilleure: MesureRolloutCodex?
        for jour in joursRecents(racine: racine) {
            for url in rolloutsRecents(jour: jour) {
                guard let signature = signature(de: url) else { continue }
                let entree: EntreeFichier
                if let connue = connues[url.path], connue.signature == signature {
                    entree = connue
                } else {
                    entree = EntreeFichier(signature: signature, mesure: derniereMesure(fichier: url))
                }
                fichiers[url.path] = entree
                if let mesure = entree.mesure, meilleure == nil || meilleure!.mesureA < mesure.mesureA {
                    meilleure = mesure
                }
            }
        }
        return (meilleure, fichiers)
    }

    /// ⛔ Le type est vérifié avant toute ouverture, et c'est la raison d'être de ce
    /// contrôle : ouvrir un tube nommé en lecture **bloque** jusqu'à ce qu'un écrivain
    /// se présente, et le balayage entier ne rendrait plus la main. Un lien symbolique
    /// est écarté pour une autre raison : ces attributs-ci décrivent le lien, tandis
    /// qu'une ouverture lirait sa cible — la signature ne dirait pas ce qui a été lu.
    private static func signature(de url: URL) -> Signature? {
        guard let attributs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributs[.type] as? FileAttributeType == .typeRegular,
              let modifieA = attributs[.modificationDate] as? Date,
              let taille = attributs[.size] as? Int else { return nil }
        return Signature(modifieA: modifieA, taille: taille)
    }

    /// Les plages que chaque étage du chemin `AAAA/MM/JJ` accepte. Un nombre hors
    /// plage n'est pas une date : `sessions/2026/99/01` prendrait une des places
    /// d'exploration, et se rangerait même devant les vrais mois.
    private static let plageAnnee = 1970...9999
    private static let plageMois = 1...12
    private static let plageJour = 1...31

    /// Les dossiers `AAAA/MM/JJ` les plus récents, dans cet ordre.
    private static func joursRecents(racine: URL) -> [URL] {
        var jours: [URL] = []
        for annee in sousDossiersDecroissants(racine, plage: plageAnnee) {
            for mois in sousDossiersDecroissants(annee, plage: plageMois) {
                for jour in sousDossiersDecroissants(mois, plage: plageJour) {
                    jours.append(jour)
                    if jours.count == joursExplores { return jours }
                }
            }
        }
        return jours
    }

    /// Les sous-dossiers dont le nom est un nombre de la plage, du plus grand au plus
    /// petit. Le tri est numérique : lexicographiquement, « 9 » se rangerait après
    /// « 10 », et un dossier étranger à l'arborescence de dates est écarté plutôt que
    /// classé au hasard.
    private static func sousDossiersDecroissants(_ dossier: URL, plage: ClosedRange<Int>) -> [URL] {
        guard let contenu = try? FileManager.default.contentsOfDirectory(
            at: dossier,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return contenu
            .compactMap { url -> (URL, Int)? in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      let rang = Int(url.lastPathComponent), plage.contains(rang) else { return nil }
                return (url, rang)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Les rollouts d'un dossier de date, du plus récemment écrit au plus ancien.
    private static func rolloutsRecents(jour: URL) -> [URL] {
        guard let contenu = try? FileManager.default.contentsOfDirectory(
            at: jour,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return contenu
            .filter { $0.lastPathComponent.hasPrefix(prefixeRollout)
                && $0.lastPathComponent.hasSuffix(suffixeRollout) }
            .map { url -> (URL, Date) in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                return (url, date ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(fichiersExplores)
            .map(\.0)
    }

    /// Remonte le fichier par blocs depuis sa fin et rend la première mesure
    /// rencontrée — donc la dernière écrite. Au-delà de `lectureMaximale`, la
    /// recherche s'arrête : un rollout qui n'a pas publié de niveau dans sa dernière
    /// tranche n'en a pas de frais à donner, et le lire en entier coûterait le prix
    /// d'une session complète pour rien.
    private static func derniereMesure(fichier url: URL) -> MesureRolloutCodex? {
        guard let poignee = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? poignee.close() }
        guard let taille = try? poignee.seekToEnd(), taille > 0 else { return nil }

        let sautDeLigne = UInt8(ascii: "\n")
        var fin = taille
        var lu = 0
        var debordement = Data()
        while fin > 0, lu < lectureMaximale {
            let debut = fin > UInt64(tailleBloc) ? fin - UInt64(tailleBloc) : 0
            guard (try? poignee.seek(toOffset: debut)) != nil,
                  let bloc = lireExactement(poignee, Int(fin - debut)) else { return nil }
            lu += bloc.count
            var lignes = (bloc + debordement).split(separator: sautDeLigne,
                                                    omittingEmptySubsequences: false)
            // Le premier morceau d'un bloc qui ne commence pas le fichier est une ligne
            // coupée en deux : elle attend la suite du parcours pour être complète.
            debordement = debut > 0 && !lignes.isEmpty ? Data(lignes.removeFirst()) : Data()
            for ligne in lignes.reversed() {
                if let mesure = mesure(ligne: Data(ligne)) { return mesure }
            }
            fin = debut
        }
        return nil
    }

    /// ⛔ Une lecture courte n'est pas une fin de fichier : elle en rend moins que
    /// demandé sans rien signaler. Le bloc servirait alors de base au recollement de la
    /// ligne coupée, et celle-ci serait recollée sur des octets qui ne se suivent pas.
    /// Un bloc incomplet fait donc abandonner le fichier, jamais deviner.
    private static func lireExactement(_ poignee: FileHandle, _ compte: Int) -> Data? {
        var donnees = Data()
        while donnees.count < compte {
            guard let morceau = try? poignee.read(upToCount: compte - donnees.count),
                  !morceau.isEmpty else { return nil }
            donnees.append(morceau)
        }
        return donnees
    }

    // MARK: - Analyse pure

    private struct LigneRollout: Decodable {
        var horodatage: Date?
        var charge: Charge?

        enum CodingKeys: String, CodingKey {
            case horodatage = "timestamp"
            case charge = "payload"
        }

        /// Chaque champ est lu pour lui seul, comme dans les autres lecteurs de
        /// disque : un rollout mêle des lignes de formats très différents, et un champ
        /// d'un type inattendu ne doit coûter que lui-même.
        init(from decodeur: Decoder) throws {
            guard let boite = try? decodeur.container(keyedBy: CodingKeys.self) else { return }
            horodatage = ((try? boite.decodeIfPresent(Horodatage.self, forKey: .horodatage)) ?? nil)?.date
            charge = (try? boite.decodeIfPresent(Charge.self, forKey: .charge)) ?? nil
        }
    }

    private struct Charge: Decodable {
        var type: String?
        var limites: Limites?

        enum CodingKeys: String, CodingKey {
            case type
            case limites = "rate_limits"
        }

        init(from decodeur: Decoder) throws {
            guard let boite = try? decodeur.container(keyedBy: CodingKeys.self) else { return }
            type = (try? boite.decodeIfPresent(String.self, forKey: .type)) ?? nil
            limites = (try? boite.decodeIfPresent(Limites.self, forKey: .limites)) ?? nil
        }
    }

    private struct Limites: Decodable {
        /// ⛔ **Un `limit_name` renseigné désigne la limite d'un modèle, jamais celle
        /// du compte.** Mesuré sur cette machine : une ligne « GPT-5.3-Codex-Spark »
        /// voisine des lignes du compte dans le même rollout. La retenir afficherait le
        /// niveau d'un modèle sous le nom du compte — le pendant exact de
        /// `additional_rate_limits` côté API et de `seven_day_breakdown` côté Anthropic.
        /// N'importe quelle valeur non nulle suffit à écarter la ligne : c'est sa
        /// présence qui dit « limite d'un modèle », pas le nom qu'elle porte.
        var estLimiteDeModele = false
        var principale: FenetreRollout?
        var secondaire: FenetreRollout?

        enum CodingKeys: String, CodingKey {
            case nomLimite = "limit_name"
            case principale = "primary"
            case secondaire = "secondary"
        }

        init(from decodeur: Decoder) throws {
            guard let boite = try? decodeur.container(keyedBy: CodingKeys.self) else { return }
            if boite.contains(.nomLimite), (try? boite.decodeNil(forKey: .nomLimite)) == false {
                estLimiteDeModele = true
            }
            principale = (try? boite.decodeIfPresent(FenetreRollout.self, forKey: .principale)) ?? nil
            secondaire = (try? boite.decodeIfPresent(FenetreRollout.self, forKey: .secondaire)) ?? nil
        }
    }

    private struct FenetreRollout: Decodable {
        var pourcentage: Double?
        var minutes: Double?
        var seRechargeA: Date?

        enum CodingKeys: String, CodingKey {
            case pourcentage = "used_percent"
            case minutes = "window_minutes"
            case seRechargeA = "resets_at"
        }

        init(from decodeur: Decoder) throws {
            guard let boite = try? decodeur.container(keyedBy: CodingKeys.self) else { return }
            pourcentage = (try? boite.decodeIfPresent(Double.self, forKey: .pourcentage)) ?? nil
            minutes = (try? boite.decodeIfPresent(Double.self, forKey: .minutes)) ?? nil
            // `resets_at` arrive en epoch, tantôt en secondes tantôt en millisecondes ;
            // `Horodatage` tranche seul, sur la seule borne qui distingue les deux.
            seRechargeA = ((try? boite.decodeIfPresent(Horodatage.self, forKey: .seRechargeA)) ?? nil)?.date
        }
    }

    private struct FenetreClassee {
        var fenetre: Fenetre
        var minutes: Double
    }

    /// Ce qu'une ligne de rollout dit du niveau du compte, ou rien.
    ///
    /// ⛔ **Une mesure sans horodatage n'en est pas une** : c'est sa date qui décide,
    /// dans la fusion, si elle remplace ce que le panneau affiche déjà.
    static func mesure(ligne: Data) -> MesureRolloutCodex? {
        guard let contenu = try? JSONDecoder().decode(LigneRollout.self, from: ligne),
              let charge = contenu.charge,
              charge.type == typeTokenCount,
              let limites = charge.limites,
              !limites.estLimiteDeModele,
              let mesureA = contenu.horodatage else { return nil }

        var classees = [limites.principale, limites.secondaire].compactMap(classer)
        // ⛔ **La position du créneau ne dit pas la durée de la fenêtre.** OpenAI ayant
        // retiré la limite de 5 h, l'hebdomadaire est passée dans `primary` : ranger
        // les fenêtres par leur rang afficherait la semaine dans la jauge de 5 h, un
        // chiffre faux présenté comme juste. `Quota` les veut de la plus courte à la
        // plus longue, et c'est le lecteur qui le garantit.
        if classees.count == 2, classees[1].minutes < classees[0].minutes {
            classees.swapAt(0, 1)
        }
        guard !classees.isEmpty else { return nil }
        return MesureRolloutCodex(quota: Quota(classees.map(\.fenetre)), mesureA: mesureA)
    }

    /// Le seuil qui range la fenêtre n'est pas ici : `QuotaCodex.fenetreClassee` le
    /// porte pour les deux lecteurs du fournisseur. Les rollouts publient des
    /// minutes là où l'API publie des secondes — c'est la seule différence, et elle
    /// se règle à l'appel.
    private static func classer(_ brute: FenetreRollout?) -> FenetreClassee? {
        guard let brute, let pourcentage = brute.pourcentage, let minutes = brute.minutes,
              let fenetre = QuotaCodex.fenetreClassee(utilisation: pourcentage,
                                                      dureeSecondes: minutes * 60,
                                                      seRechargeA: brute.seRechargeA)
        else { return nil }
        return FenetreClassee(fenetre: fenetre, minutes: minutes)
    }
}

/// Ce qui évite de rouvrir un rollout qui n'a pas bougé. Une journée chargée en compte
/// une cinquantaine, et la boucle de statut tourne bien plus vite qu'une session ne
/// s'écrit.
///
/// ⚠️ Cet acteur n'est jamais tenu pendant un balayage : il rend ce qu'il sait, le
/// balayage a lieu ailleurs, il enregistre ensuite.
actor CacheRolloutCodex {
    static let partage = CacheRolloutCodex()

    private var entreesParFichier: [String: HistoriqueRolloutCodex.EntreeFichier] = [:]

    func entrees() -> [String: HistoriqueRolloutCodex.EntreeFichier] { entreesParFichier }

    /// Un fichier absent de la relecture sort du cache : un compte supprimé, ou une
    /// journée qu'on ne balaye plus, ne garde pas sa mesure en mémoire.
    func enregistrer(_ relues: [String: HistoriqueRolloutCodex.EntreeFichier]) {
        entreesParFichier = relues
    }
}
