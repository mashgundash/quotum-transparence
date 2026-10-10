import Foundation

/// Un compte tel qu'il se lit sur le disque : un bundle de `~/Applications` dont le
/// script `launcher` ouvre l'application du fournisseur sur son propre dossier de
/// données. Rien n'est codé en dur ; renommer un compte ne casse rien.
struct CompteLocal: Sendable, Equatable {
    var nom: String
    var fournisseur: Fournisseur
    var cheminApp: URL
    /// Chemin complet du dossier de données, `$HOME` déjà résolu.
    var dataDir: String
    /// Le dossier de configuration que le lanceur pose (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`).
    var configuration: ConfigurationLanceur = .absente
    var profilChrome: String?
    var appLancee = false

    var nomDataDir: String { (dataDir as NSString).lastPathComponent }

    var dossiers: DossiersCompte {
        DossiersCompte(fournisseur: fournisseur, dossierDonnees: dataDir, configuration: configuration)
    }
}

/// Mesuré le 2026-09-16 : les deux applications de bureau sont des bundles Electron,
/// d'où le `--user-data-dir` sur lequel repose le multi-comptes. `/Applications/ChatGPT.app`
/// s'identifie `com.openai.codex` et cache son Chromium sous « Codex Framework », mais
/// porte bien `app.asar` et le commutateur. Aucun bundle de compte ChatGPT n'existe
/// encore dans `~/Applications` : la découverte est agnostique et en verra un dès qu'il
/// y sera, qu'il vienne de `CreationCompte` ou d'ailleurs.
enum Decouverte {
    static let marqueurDataDir = "--user-data-dir="

    static var dossierApplications: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    }

    static var dossierChrome: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome")
    }

    static var fichierLocalState: URL {
        dossierChrome.appendingPathComponent("Local State")
    }

    static func comptes() async -> [CompteLocal] {
        await HorsFil.executer {
            comptesSurDisque(dossier: dossierApplications,
                             accueil: FileManager.default.homeDirectoryForCurrentUser.path,
                             chrome: etatChrome(),
                             lances: dataDirsLances(),
                             rattachements: RattachementsChrome(preferences: .standard).tous())
        }
    }

    // MARK: - Lecture du disque

    /// Les comptes d'un dossier d'applications. Chrome, les processus et les
    /// rattachements arrivent en paramètres : la lecture du système reste dans
    /// `comptes()`, et un test ne touche ni au vrai `Local State` ni à `ps`.
    static func comptesSurDisque(dossier racine: URL,
                                 accueil: String,
                                 chrome: EtatChrome,
                                 lances: Set<String>,
                                 rattachements: [String: String]) -> [CompteLocal] {
        let entrees = (try? FileManager.default.contentsOfDirectory(at: racine,
                                                                    includingPropertiesForKeys: nil)) ?? []

        return entrees.compactMap { url -> CompteLocal? in
            guard url.pathExtension == "app" else { return nil }
            let launcher = url.appendingPathComponent("Contents/MacOS/launcher")
            guard let script = try? String(contentsOf: launcher, encoding: .utf8),
                  let dataDir = dataDir(dansLauncher: script, accueil: accueil) else { return nil }
            let nom = url.deletingPathExtension().lastPathComponent
            let fournisseur = fournisseur(dansLauncher: script) ?? .claude
            return CompteLocal(nom: nom,
                               fournisseur: fournisseur,
                               cheminApp: url,
                               dataDir: dataDir,
                               configuration: configuration(dansLauncher: script, fournisseur: fournisseur,
                                                            accueil: accueil),
                               profilChrome: profil(nom: nom, dataDir: dataDir,
                                                    chrome: chrome, rattachements: rattachements),
                               appLancee: lances.contains(RattachementsChrome.normaliser(dataDir)))
        }
        .sorted { $0.nom.localizedStandardCompare($1.nom) == .orderedAscending }
    }

    /// Le dossier rattaché, s'il existe encore sur le disque et n'appartient qu'à ce compte ;
    /// sinon rien. Le nom exact du bundle ne sert qu'aux comptes **jamais** rattachés, pour
    /// les profils créés à la main — et jamais vers un profil rattaché à un autre compte.
    ///
    /// ⛔ Un rattachement dont le dossier a disparu ne retombe pas sur le nom : un autre
    /// profil du même nom peut porter la session d'un autre compte. Sans profil, la ligne
    /// propose d'en créer un.
    static func profil(nom: String,
                       dataDir: String,
                       chrome: EtatChrome,
                       rattachements: [String: String]) -> String? {
        let rattaches = rattachements.reduce(into: [String: Int]()) { $0[$1.value, default: 0] += 1 }
        if let rattache = rattachements[RattachementsChrome.normaliser(dataDir)] {
            guard chrome.dossiersPresents.contains(rattache), rattaches[rattache] == 1 else { return nil }
            return rattache
        }
        guard let parNom = chrome.profilsParNom[nom], chrome.dossiersPresents.contains(parNom),
              rattaches[parNom] == nil else { return nil }
        return parNom
    }

    /// Ce que Chrome a sur ce Mac. Un `Local State` absent veut dire que Chrome n'a jamais
    /// tourné ; présent mais illisible, ou un dossier qui ne s'énumère pas, rendent l'état
    /// illisible — rien ne se crée alors sur la foi d'un inventaire faux.
    static func etatChrome() -> EtatChrome {
        let localState: Data?
        var lisible = true
        do {
            localState = try LectureFichier.lire(fichierLocalState, tailleMaximale: 16 << 20)
        } catch .absent {
            localState = nil
        } catch {
            localState = nil
            lisible = false
        }
        var etat = EtatChrome.lire(localState: localState, entreesDossierChrome: dossiersDeProfil())
        etat.lisible = etat.lisible && lisible
        return etat
    }

    /// Les entrées du dossier de Chrome qui sont de vrais dossiers — ni fichier, ni lien.
    /// `[]` si Chrome n'a jamais créé son dossier, `nil` si l'énumération échoue.
    private static func dossiersDeProfil() -> [String]? {
        let racine = dossierChrome.path
        let entrees: [String]
        do {
            entrees = try FileManager.default.contentsOfDirectory(atPath: racine)
        } catch let erreur as CocoaError where erreur.code == .fileReadNoSuchFile {
            return []
        } catch {
            return nil
        }
        return entrees.filter { estDossierReel("\(racine)/\($0)") }
    }

    static func estDossierReel(_ chemin: String) -> Bool {
        var etat = stat()
        return lstat(chemin, &etat) == 0 && etat.st_mode & S_IFMT == S_IFDIR
    }

    static func profilsChrome() -> [String: String] {
        guard let donnees = try? Data(contentsOf: fichierLocalState) else { return [:] }
        return profilsChrome(donneesLocalState: donnees)
    }

    static func dataDirsLances() -> Set<String> {
        guard let sortie = sortieProcessus() else { return [] }
        return dataDirsLances(sortiePs: sortie)
    }

    /// `pgrep -f "…/Claude$"` rate les instances qui portent des arguments, or les
    /// lanceurs de compte en portent toujours un. La ligne de commande complète est
    /// la seule lecture fiable.
    private static func sortieProcessus() -> String? {
        let processus = Process()
        processus.executableURL = URL(fileURLWithPath: "/bin/ps")
        processus.arguments = ["-axo", "command"]
        let tube = Pipe()
        processus.standardOutput = tube
        processus.standardError = FileHandle.nullDevice
        guard (try? processus.run()) != nil else { return nil }
        let donnees = tube.fileHandleForReading.readDataToEndOfFile()
        processus.waitUntilExit()
        return String(data: donnees, encoding: .utf8)
    }

    // MARK: - Analyses pures

    /// Le script réel est multi-ligne, l'argument posé après une continuation `\`.
    /// La recherche porte donc sur tout le contenu, sans ancre de début de ligne.
    static func dataDir(dansLauncher script: String, accueil: String) -> String? {
        guard let borne = script.range(of: marqueurDataDir) else { return nil }
        var suite = script[borne.upperBound...]
        if suite.first == "\"" { suite = suite.dropFirst() }
        let valeur = String(suite.prefix(while: { $0 != "\"" && $0 != "\n" }))
            .trimmingCharacters(in: .whitespaces)
        guard !valeur.isEmpty else { return nil }
        return developper(valeur, accueil: accueil)
    }

    /// La variable de configuration que le lanceur pose — `--env NOM=…` d'`open`, `export NOM=…`,
    /// `env NOM=…` ou une affectation en tête de commande. Les lignes de commentaire ne comptent
    /// pas ; deux valeurs différentes, ou une valeur qui ne se résout pas, rendent `.illisible`.
    static func configuration(dansLauncher script: String, fournisseur: Fournisseur,
                              accueil: String) -> ConfigurationLanceur {
        let nom: String
        switch fournisseur {
        case .claude: nom = "CLAUDE_CONFIG_DIR"
        case .chatgpt: nom = "CODEX_HOME"
        default: return .absente
        }
        var valeurs: [String?] = []
        for ligne in script.split(whereSeparator: \.isNewline) {
            let texte = Substring(ligne)
            guard !texte.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("#") else { continue }
            var reste = texte
            while let trouve = reste.range(of: nom + "=") {
                let avant = trouve.lowerBound == texte.startIndex ? nil : texte[texte.index(before: trouve.lowerBound)]
                reste = texte[trouve.upperBound...]
                guard avant == nil || avant == " " || avant == "\t" || avant == "\"" || avant == "'" else { continue }
                valeurs.append(valeurAffectee(texte[trouve.upperBound...], citation: avant)
                    // Entre apostrophes, le shell ne développe pas `$HOME` : ce chemin-là n'est pas résolu.
                    .flatMap { $0.contains("$") && (avant == "'" || texte[trouve.upperBound...].first == "'") ? "$" : $0 })
            }
        }
        guard let premiere = valeurs.first else { return .absente }
        guard let brute = premiere, valeurs.allSatisfy({ $0 == brute }) else { return .illisible }
        var chemin = developper(brute, accueil: accueil)
        if chemin.count > 1, chemin.hasSuffix("/") { chemin.removeLast() }
        // ⛔ Pas de `standardizingPath`, qui retire `/private` : le chemin reste celui du lanceur.
        let composants = chemin.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard DossiersCompte.cheminResolu(chemin), !brute.contains("\\"),
              !composants.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return .illisible }
        return .posee(chemin)
    }

    /// La valeur d'une affectation de shell, citée ou non. `nil` si la citation ne se ferme pas.
    private static func valeurAffectee(_ suite: Substring, citation: Character?) -> String? {
        if let citation = citation == "\"" || citation == "'" ? citation : nil {
            return suite.firstIndex(of: citation).map { String(suite[..<$0]) }
        }
        if let ouvrante = suite.first, ouvrante == "\"" || ouvrante == "'" {
            let interieur = suite.dropFirst()
            return interieur.firstIndex(of: ouvrante).map { String(interieur[..<$0]) }
        }
        return String(suite.prefix(while: { $0 != " " && $0 != "\t" && $0 != ";" }))
    }

    /// Le fournisseur se lit sur l'application que le script ouvre, jamais sur le nom
    /// du bundle : filtrer sur « Claude » ferait entrer Quotum dans sa propre liste.
    static func fournisseur(dansLauncher script: String) -> Fournisseur? {
        if let borne = script.range(of: "-a \"") {
            let cible = String(script[borne.upperBound...].prefix(while: { $0 != "\"" && $0 != "\n" }))
            if !cible.isEmpty { return fournisseur(deLApplication: cible) }
        }
        return fournisseur(deLApplication: script)
    }

    private static func fournisseur(deLApplication chemin: String) -> Fournisseur? {
        let normalise = Texte.normaliser(chemin)
        if normalise.contains("chatgpt") || normalise.contains("openai") { return .chatgpt }
        if normalise.contains("claude") { return .claude }
        return nil
    }

    static func profilsChrome(donneesLocalState: Data) -> [String: String] {
        guard let racine = try? JSONSerialization.jsonObject(with: donneesLocalState) as? [String: Any],
              let profil = racine["profile"] as? [String: Any],
              let cache = profil["info_cache"] as? [String: Any] else { return [:] }
        var sortie: [String: String] = [:]
        for (dossier, valeur) in cache {
            if let details = valeur as? [String: Any], let nom = details["name"] as? String {
                sortie[nom] = dossier
            }
        }
        return sortie
    }

    /// Un data dir contient des espaces (« Application Support ») mais jamais « --» :
    /// couper à l'option suivante isole le chemin même sur les processus auxiliaires,
    /// qui ajoutent leurs propres arguments après celui-ci.
    ///
    /// ⛔ Le chemin complet seul, jamais son dernier composant : un dossier homonyme sur un
    /// autre volume ferait passer pour ouvert un compte qui ne l'est pas.
    static func dataDirsLances(sortiePs: String) -> Set<String> {
        var sortie: Set<String> = []
        for ligne in sortiePs.split(separator: "\n") {
            var reste = Substring(ligne)
            while let borne = reste.range(of: marqueurDataDir) {
                let suite = reste[borne.upperBound...]
                let valeur = suite.range(of: " --").map { String(suite[..<$0.lowerBound]) } ?? String(suite)
                let coupe = valeur.trimmingCharacters(in: .whitespaces)
                if coupe.hasPrefix("/") { sortie.insert(RattachementsChrome.normaliser(coupe)) }
                reste = suite
            }
        }
        return sortie
    }

    static func developper(_ chemin: String, accueil: String) -> String {
        if chemin.hasPrefix("$HOME/") { return accueil + chemin.dropFirst(5) }
        if chemin == "$HOME" { return accueil }
        if chemin.hasPrefix("${HOME}/") { return accueil + chemin.dropFirst(7) }
        if chemin.hasPrefix("~/") { return accueil + chemin.dropFirst(1) }
        return chemin
    }
}
