import CryptoKit
import Foundation
import Synchronization

/// Où le CLI `codex` range sa connexion : la clé `cli_auth_credentials_store` de premier niveau de
/// `<CODEX_HOME>/config.toml`. Valeurs et défaut relevés dans openai/codex (`file` par défaut).
enum ModeStockageCodex: Sendable, Equatable {
    /// `file`, ou la clé absente : `auth.json` seul.
    case fichier
    /// `keyring` : le Trousseau seul ; un `auth.json` resté d'avant n'est plus celui du CLI.
    case trousseau
    /// `auto` : le Trousseau d'abord, puis `auth.json` si l'élément manque ou ne se lit pas.
    case auto
    /// `ephemeral` : la connexion ne vit qu'en mémoire du CLI, rien n'est rangé.
    case ephemere
}

/// Ce que la lecture de `config.toml` établit.
enum LectureModeCodex: Sendable, Equatable {
    case mode(ModeStockageCodex)
    /// Une valeur que le CLI ne connaît pas : il refuserait lui-même cette configuration.
    case valeurInconnue
    /// Fichier présent mais illisible, trop grand, ou d'une forme que la lecture ne tranche pas.
    case illisible
    /// `keyring` ou `auto` avec `secret_auth_storage` activé : le CLI range alors sa connexion dans
    /// son stockage chiffré, et l'élément direct qui resterait d'avant n'est plus le sien.
    case trousseauChiffre
}

/// Ce qui empêche Quotum de lire la connexion de Codex là où le CLI la range. Rien n'en est
/// déduit du compte : ni absence de connexion, ni quota.
enum EmpechementCodex: Sendable, Equatable {
    /// L'invite du Trousseau a été refusée, ou reste suspendue depuis un refus.
    case accesRefuse
    /// Le stockage chiffré du CLI (`secret_auth_storage`), que Quotum ne lit pas.
    case connexionChiffree
    /// `config.toml` ne se lit pas avec certitude : Quotum ne sait pas où le CLI range sa connexion.
    case modeIndetermine

    var cause: Cause {
        switch self {
        case .accesRefuse: .accesTrousseauRefuse
        case .connexionChiffree: .connexionCodexChiffree
        case .modeIndetermine: .connexionCodexIndeterminee
        }
    }
}

/// Ce que `security` a rendu pour l'élément `Codex Auth` d'un `CODEX_HOME`.
enum SecretTrousseauCodex: Sendable, Equatable {
    case donnees(Data)
    /// Code 44 : l'élément n'existe pas.
    case absent
    /// Invite refusée, délai dépassé, utilitaire injoignable — ou lecture suspendue par un refus
    /// antérieur. Rien n'est établi du compte.
    case refuse
}

/// Les éléments `Codex Auth` dont l'accès a été refusé, par compte `cli|…`, en mémoire seulement.
/// ⛔ Seul le bouton « Rafraîchir » du panneau les lève : le minuteur, l'ouverture du panneau ou une
/// URL ramèneraient sinon l'invite du Trousseau à chaque tour, après un refus explicite.
final class SuspensionsTrousseauCodex: Sendable {
    private let comptes = Mutex<Set<String>>([])

    static let partagees = SuspensionsTrousseauCodex()

    func estSuspendu(_ compte: String) -> Bool { comptes.withLock { $0.contains(compte) } }
    func suspendre(_ compte: String) { _ = comptes.withLock { $0.insert(compte) } }
    func lever() { comptes.withLock { $0.removeAll() } }
}

/// Ce que la lecture du Trousseau de Codex appelle. ⛔ Sans valeur par défaut : un test dit quel
/// lanceur il emploie et quelles suspensions il observe.
struct AccesTrousseauCodex: Sendable {
    let lanceur: LanceurProcessus
    let suspensions: SuspensionsTrousseauCodex
    /// La file des lectures de `config.toml` et d'`auth.json`.
    var file = FileHorsFil.systeme

    static let systeme = AccesTrousseauCodex(lanceur: Trousseau.lanceurSysteme, suspensions: .partagees)
}

/// La connexion de Codex quand son CLI la range au Trousseau. Résolution identique à celle du CLI,
/// sans repli inventé : `file` ne touche jamais au Trousseau, `keyring` jamais au fichier.
///
/// ⛔ Lecture seulement, par `Trousseau.executerLecture`, seule invocation de `security` du dépôt ;
/// aucun secret gardé ni journalisé.
enum TrousseauCodex {
    static let service = "Codex Auth"
    static let prefixeCompte = "cli|"
    static let cleMode = "cli_auth_credentials_store"
    static let nomConfiguration = "config.toml"
    static let tailleMaximaleConfiguration = 256 * 1024
    /// La fonctionnalité du CLI qui range la connexion dans son stockage chiffré : celle de
    /// `[features]` seulement, la seule que le CLI applique.
    static let cleStockageChiffre = "secret_auth_storage"
    /// L'ancien sélecteur de profil : le CLI refuse désormais toute configuration qui le porte.
    static let cleProfil = "profile"

    // MARK: - Compte de l'élément

    /// `cli|` puis les 16 premiers chiffres hexadécimaux, en minuscules, du SHA-256 du chemin
    /// canonique de `CODEX_HOME`.
    static func compte(cheminCanonique: String) -> String {
        let empreinte = SHA256.hash(data: Data(cheminCanonique.utf8))
        let hexa = empreinte.map { String(format: "%02x", $0) }.joined()
        return prefixeCompte + hexa.prefix(16)
    }

    static func compte(codexHome: URL) -> String {
        compte(cheminCanonique: cheminCanonique(codexHome.path))
    }

    /// `realpath(3)`, comme le CLI ; à défaut, le chemin tel quel. ⚠️ Jamais
    /// `resolvingSymlinksInPath()`, qui retire `/private` et donnerait un autre compte que le CLI.
    static func cheminCanonique(_ chemin: String) -> String {
        guard let resolu = realpath(chemin, nil) else { return chemin }
        defer { free(resolu) }
        return String(cString: resolu)
    }

    // MARK: - Mode de stockage

    /// `cheminSansLien` suit celui de l'`auth.json` du même dossier : refusé là où ce fichier l'est.
    static func mode(codexHome: URL, cheminSansLien: Bool) -> LectureModeCodex {
        let fichier = codexHome.appendingPathComponent(nomConfiguration, isDirectory: false)
        do {
            return analyserMode(try LectureFichier.lire(fichier, tailleMaximale: tailleMaximaleConfiguration,
                                                        cheminSansLien: cheminSansLien))
        } catch .absent {
            return .mode(.fichier)
        } catch {
            Journal.donnees.notice("Codex : config.toml illisible (\(String(describing: error)))")
            return .illisible
        }
    }

    /// La clé de premier niveau seulement, lue sur le document TOML entier : une forme que cette
    /// lecture ne sait pas trancher — syntaxe hors de TOML 1.0, clé répétée, clé devenue table,
    /// valeur qui n'est pas une chaîne, clé `profile` que le CLI refuse — rend `.illisible`, jamais
    /// un mode deviné.
    static func analyserMode(_ donnees: Data) -> LectureModeCodex {
        guard let texte = String(data: donnees, encoding: .utf8),
              let document = DocumentTOML.analyser(texte) else { return .illisible }
        guard !document.tables.contains(where: { $0.first == cleMode }),
              !document.valeurs.contains(where: { $0.chemin.first == cleMode && $0.chemin.count > 1 }) else {
            return .illisible
        }
        guard !document.tables.contains(where: { $0.first == cleProfil }),
              !document.valeurs.contains(where: { $0.chemin.first == cleProfil }) else { return .illisible }
        let declarees = document.valeurs.filter { $0.chemin == [cleMode] }
        guard declarees.count <= 1 else { return .illisible }
        guard let declaree = declarees.first else { return .mode(.fichier) }
        guard case .chaine(let valeur) = declaree.valeur else { return .illisible }
        switch valeur {
        case "file": return .mode(.fichier)
        case "keyring", "auto": return stockageAuTrousseau(document, mode: valeur == "auto" ? .auto : .trousseau)
        case "ephemeral": return .mode(.ephemere)
        default: return .valeurInconnue
        }
    }

    /// Le CLI ne compose ses fonctionnalités qu'à partir de `[features]` : celles de
    /// `[profiles.<nom>.features]` n'y entrent jamais. Leur type est vérifié quand même, parce
    /// qu'un booléen manquant là fait refuser le fichier entier au CLI.
    private static func stockageAuTrousseau(_ document: DocumentTOML, mode: ModeStockageCodex) -> LectureModeCodex {
        let premierNiveau = document.valeurs.filter { $0.chemin == ["features", cleStockageChiffre] }
        let profils = document.valeurs.filter { entree in
            let chemin = entree.chemin
            return chemin.count == 4 && chemin[0] == "profiles" && chemin[2] == "features" && chemin[3] == cleStockageChiffre
        }
        guard premierNiveau.count <= 1, Set(profils.map(\.chemin)).count == profils.count else { return .illisible }
        for reglage in premierNiveau + profils {
            guard case .booleen = reglage.valeur else { return .illisible }
        }
        guard case .booleen(true)? = premierNiveau.first?.valeur else { return .mode(mode) }
        return .trousseauChiffre
    }

    // MARK: - Lecture

    /// L'élément `Codex Auth` de ce `CODEX_HOME`. Un refus — sortie hors 0 et 44, délai — suspend
    /// la lecture de cet élément, et une lecture suspendue ne lance plus `security`.
    static func lireSecret(codexHome: URL, acces: AccesTrousseauCodex) async -> SecretTrousseauCodex {
        let compte = compte(codexHome: codexHome)
        guard !acces.suspensions.estSuspendu(compte) else { return .refuse }
        let brute = await Trousseau.executerLecture(service: service, comptes: [compte], sujet: "Codex",
                                                    lanceur: acces.lanceur)
        guard !brute.interrompue, let resultat = brute.resultats.first else {
            acces.suspensions.suspendre(compte)
            Journal.donnees.notice("Codex : Trousseau injoignable, lecture suspendue jusqu'au prochain « Rafraîchir »")
            return .refuse
        }
        if resultat.reussi { return .donnees(Data(resultat.sortie.utf8)) }
        if resultat.code == Trousseau.codeAbsent { return .absent }
        acces.suspensions.suspendre(compte)
        Journal.donnees.notice("Codex : accès au Trousseau refusé (code \(resultat.code)), lecture suspendue")
        return .refuse
    }

    /// La connexion du `CODEX_HOME` de `fichier`, lue là où le CLI la lit. `autorise` est lu avant
    /// `config.toml`, puis relu après chaque attente, juste avant d'ouvrir le Trousseau ou le fichier
    /// — pour `auth.json`, dans le travail même de la file : faux, rien n'est ouvert et la lecture
    /// rend `.empechee`, qui n'établit rien.
    static func jeton(fichier: URL, cheminSansLien: Bool, acces: AccesTrousseauCodex,
                      autorise: @escaping @Sendable () -> Bool) async -> LectureCodex {
        guard autorise() else { return .empechee }
        let codexHome = fichier.deletingLastPathComponent()
        let mode = await acces.file.executer { mode(codexHome: codexHome, cheminSansLien: cheminSansLien) }
        let lireFichier: @Sendable () async -> LectureCodex = {
            await acces.file.executer {
                guard autorise() else { return .empechee }
                return IdentifiantsCodex.lire(fichier, cheminSansLien: cheminSansLien)
            }
        }
        let lireElement: @Sendable () async -> SecretTrousseauCodex? = {
            guard autorise() else { return nil }
            return await lireSecret(codexHome: codexHome, acces: acces)
        }
        switch mode {
        case .mode(.fichier):
            return await lireFichier()
        case .mode(.trousseau):
            guard let secret = await lireElement() else { return .empechee }
            return classer(secret)
        case .mode(.auto):
            // Le CLI garde tout élément présent, clé d'API comprise, et ne lit le fichier qu'en son
            // absence. ⛔ Un refus ou un contenu que Quotum ne lit pas n'établit pas cette absence :
            // le CLI, lui, ouvre son élément, et le fichier peut être celui d'un autre compte.
            guard let secret = await lireElement() else { return .empechee }
            guard secret == .absent else { return classer(secret) }
            return await lireFichier()
        case .mode(.ephemere):
            return .absent
        case .trousseauChiffre:
            return .horsDePortee(.connexionChiffree)
        case .valeurInconnue, .illisible:
            return .horsDePortee(.modeIndetermine)
        }
    }

    static func classer(_ secret: SecretTrousseauCodex) -> LectureCodex {
        switch secret {
        case .donnees(let donnees): IdentifiantsCodex.classer(donnees)
        case .absent: .absent
        case .refuse: .horsDePortee(.accesRefuse)
        }
    }
}

/// Un document TOML 1.0 réduit à ce que la résolution du mode doit savoir : le chemin complet de
/// chaque valeur et de chaque en-tête de table. ⛔ Tout document que TOML 1.0 refuse rend `nil`,
/// où que soit la faute — syntaxe, nombre ou date hors grammaire, clé répétée, table redéfinie ou
/// prolongée : le CLI refuse alors le fichier entier, et rien de ce qu'il porte ne vaut.
struct DocumentTOML: Equatable {
    enum Valeur: Equatable {
        case chaine(String)
        case booleen(Bool)
        /// Nombre, date, tableau ou table en ligne : la forme suffit, le contenu ne sert pas.
        case autre
    }

    struct Entree: Equatable {
        var chemin: [String]
        var valeur: Valeur
    }

    /// Le segment que porte tout ce qui vit dans un tableau : il ne se confond avec aucune clé.
    static let element = "\u{0}[]"

    private(set) var valeurs: [Entree] = []
    /// Les en-têtes `[a.b]` et `[[a.b]]`, ces derniers suivis du segment `element`.
    private(set) var tables: [[String]] = []

    static func analyser(_ texte: String) -> DocumentTOML? {
        var lecteur = Lecteur(Array(texte.unicodeScalars))
        return lecteur.document()
    }

    /// Ce qu'un chemin désigne déjà, pour refuser une seconde définition.
    private final class Noeud {
        enum Sorte { case table, tableauDeTables, valeur }
        let sorte: Sorte
        var enfants: [String: Noeud] = [:]
        var elements: [Noeud] = []
        /// Défini par un en-tête `[a]` : un second en-tête le redéfinirait.
        var explicite = false
        /// Défini par une clé pointée : aucun en-tête ne peut le rouvrir.
        var pointee = false
        /// Table en ligne : close à son accolade fermante, rien ne s'y ajoute ensuite.
        var figee = false

        init(_ sorte: Sorte) { self.sorte = sorte }
    }

    private struct Lecteur {
        let car: [Unicode.Scalar]
        var i = 0
        var doc = DocumentTOML()
        let racine = Noeud(.table)

        init(_ car: [Unicode.Scalar]) { self.car = car }

        var fin: Bool { i >= car.count }
        /// `texte` se lit à partir de `decalage` caractères après la position courante.
        func voit(_ texte: String, _ decalage: Int = 0) -> Bool {
            for (rang, c) in texte.unicodeScalars.enumerated() {
                let j = i + decalage + rang
                guard j < car.count, car[j] == c else { return false }
            }
            return true
        }

        mutating func document() -> DocumentTOML? {
            var courant: [String] = []
            var section = racine
            while true {
                sauterBlancs()
                if fin { return doc }
                if voit("#") { guard commentaire() else { return nil }; continue }
                if finDeLigne() { continue }
                if voit("[") {
                    let tableau = voit("[", 1)
                    i += tableau ? 2 : 1
                    sauterBlancs()
                    guard let cle = cle() else { return nil }
                    sauterBlancs()
                    guard voit(tableau ? "]]" : "]") else { return nil }
                    i += tableau ? 2 : 1
                    guard let ouverte = tableau ? ajouterElement(cle) : ouvrirTable(cle) else { return nil }
                    section = ouverte
                    courant = tableau ? cle + [DocumentTOML.element] : cle
                    doc.tables.append(courant)
                } else {
                    guard paire(sous: courant, dans: section) else { return nil }
                }
                sauterBlancs()
                if voit("#") { guard commentaire() else { return nil } }
                guard fin || finDeLigne() else { return nil }
            }
        }

        mutating func paire(sous prefixe: [String], dans table: Noeud) -> Bool {
            guard let cle = cle() else { return false }
            sauterBlancs()
            guard voit("=") else { return false }
            i += 1
            sauterBlancs()
            guard let nom = cle.last, let parent = Self.parentDeCle(cle, dans: table),
                  parent.enfants[nom] == nil else { return false }
            return valeur(chemin: prefixe + cle, place: (parent, nom))
        }

        /// Une clé pointée ne traverse que les tables qu'une clé pointée a créées : jamais une table
        /// d'en-tête, ni une table en ligne, ni une valeur.
        static func parentDeCle(_ cle: [String], dans table: Noeud) -> Noeud? {
            var noeud = table
            for segment in cle.dropLast() {
                if let existant = noeud.enfants[segment] {
                    guard existant.sorte == .table, existant.pointee, !existant.figee else { return nil }
                    noeud = existant
                } else {
                    let creee = Noeud(.table)
                    creee.pointee = true
                    noeud.enfants[segment] = creee
                    noeud = creee
                }
            }
            return noeud
        }

        /// Un en-tête traverse toute table encore ouverte, et le dernier élément d'un tableau de tables.
        func parentDEnTete(_ cle: [String]) -> Noeud? {
            var noeud = racine
            for segment in cle.dropLast() {
                guard let existant = noeud.enfants[segment] else {
                    let implicite = Noeud(.table)
                    noeud.enfants[segment] = implicite
                    noeud = implicite
                    continue
                }
                switch existant.sorte {
                case .table:
                    guard !existant.figee else { return nil }
                    noeud = existant
                case .tableauDeTables:
                    guard let dernier = existant.elements.last else { return nil }
                    noeud = dernier
                case .valeur:
                    return nil
                }
            }
            return noeud
        }

        /// `[a.b]` : seule une table créée en passant par un autre en-tête peut encore être définie.
        func ouvrirTable(_ cle: [String]) -> Noeud? {
            guard let nom = cle.last, let parent = parentDEnTete(cle) else { return nil }
            if let existant = parent.enfants[nom] {
                guard existant.sorte == .table, !existant.figee, !existant.explicite, !existant.pointee else {
                    return nil
                }
                existant.explicite = true
                return existant
            }
            let table = Noeud(.table)
            table.explicite = true
            parent.enfants[nom] = table
            return table
        }

        /// `[[a.b]]` : un élément de plus, seulement dans un tableau qu'un autre `[[a.b]]` a créé.
        func ajouterElement(_ cle: [String]) -> Noeud? {
            guard let nom = cle.last, let parent = parentDEnTete(cle) else { return nil }
            let element = Noeud(.table)
            element.explicite = true
            if let existant = parent.enfants[nom] {
                guard existant.sorte == .tableauDeTables else { return nil }
                existant.elements.append(element)
                return element
            }
            let tableau = Noeud(.tableauDeTables)
            tableau.elements = [element]
            parent.enfants[nom] = tableau
            return element
        }

        mutating func sauterBlancs() {
            while !fin, car[i] == " " || car[i] == "\t" { i += 1 }
        }

        mutating func finDeLigne() -> Bool {
            if voit("\n") { i += 1; return true }
            if voit("\r"), voit("\n", 1) { i += 2; return true }
            return false
        }

        mutating func commentaire() -> Bool {
            i += 1
            while !fin, car[i] != "\n" {
                if car[i] == "\r", voit("\n", 1) { break }
                guard Self.permis(car[i]) else { return false }
                i += 1
            }
            return true
        }

        /// Hors tabulation, aucun caractère de contrôle n'est admis dans une chaîne ou un commentaire.
        static func permis(_ c: Unicode.Scalar) -> Bool {
            c == "\t" || !(c.value < 0x20 || c.value == 0x7F)
        }

        mutating func cle() -> [String]? {
            var segments: [String] = []
            while true {
                sauterBlancs()
                guard let segment = cleSimple() else { return nil }
                segments.append(segment)
                sauterBlancs()
                guard voit(".") else { return segments }
                i += 1
            }
        }

        mutating func cleSimple() -> String? {
            if voit("\"") { return voit("\"\"\"") ? nil : chaineBase() }
            if voit("'") { return voit("'''") ? nil : chaineLitterale() }
            var nue = String.UnicodeScalarView()
            while !fin, Self.nue(car[i]) { nue.append(car[i]); i += 1 }
            return nue.isEmpty ? nil : String(nue)
        }

        static func nue(_ c: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c) || c == "_" || c == "-"
        }

        /// `place` : là où la valeur se range ; `nil` dans un tableau, où rien ne la nomme.
        mutating func valeur(chemin: [String], place: (Noeud, String)?) -> Bool {
            guard !fin else { return false }
            if voit("{") {
                let table = Noeud(.table)
                if let place { place.0.enfants[place.1] = table }
                guard tableEnLigne(chemin: chemin, table: table) else { return false }
                table.figee = true
                return enregistrer(chemin, .autre)
            }
            if let place { place.0.enfants[place.1] = Noeud(.valeur) }
            if voit("\"\"\"") { return enregistrer(chemin, chaineBaseMultiligne().map(Valeur.chaine)) }
            if voit("\"") { return enregistrer(chemin, chaineBase().map(Valeur.chaine)) }
            if voit("'''") { return enregistrer(chemin, chaineLitteraleMultiligne().map(Valeur.chaine)) }
            if voit("'") { return enregistrer(chemin, chaineLitterale().map(Valeur.chaine)) }
            if voit("[") { return tableau(chemin: chemin) && enregistrer(chemin, .autre) }
            if voit("true"), delimite(4) { i += 4; return enregistrer(chemin, .booleen(true)) }
            if voit("false"), delimite(5) { i += 5; return enregistrer(chemin, .booleen(false)) }
            return scalaireNu() && enregistrer(chemin, .autre)
        }

        mutating func enregistrer(_ chemin: [String], _ valeur: Valeur?) -> Bool {
            guard let valeur else { return false }
            doc.valeurs.append(Entree(chemin: chemin, valeur: valeur))
            return true
        }

        func delimite(_ longueur: Int) -> Bool {
            guard i + longueur < car.count else { return true }
            return " \t\r\n,]}#".unicodeScalars.contains(car[i + longueur])
        }

        /// Nombre, date ou heure, validé par la grammaire de TOML 1.0. Une date suivie d'une heure
        /// séparée par une espace reste une seule valeur.
        mutating func scalaireNu() -> Bool {
            let debut = i
            func caractere(_ c: Unicode.Scalar) -> Bool {
                Self.nue(c) || c == "+" || c == "." || c == ":"
            }
            while !fin, caractere(car[i]) { i += 1 }
            if i - debut == 10, voit(" "), i + 1 < car.count, ("0"..."9").contains(car[i + 1]),
               car[debut + 4] == "-", car[debut + 7] == "-" {
                i += 1
                while !fin, caractere(car[i]) { i += 1 }
            }
            guard i > debut else { return false }
            return ScalaireTOML.valide(car[debut..<i].map { UInt8(truncatingIfNeeded: $0.value) })
        }

        mutating func tableau(chemin: [String]) -> Bool {
            i += 1
            while true {
                guard sauterDansTableau() else { return false }
                if voit("]") { i += 1; return true }
                guard valeur(chemin: chemin + [DocumentTOML.element], place: nil) else { return false }
                guard sauterDansTableau() else { return false }
                if voit(",") { i += 1; continue }
                guard voit("]") else { return false }
                i += 1
                return true
            }
        }

        mutating func sauterDansTableau() -> Bool {
            while true {
                sauterBlancs()
                if fin { return false }
                if voit("#") { guard commentaire() else { return false }; continue }
                if finDeLigne() { continue }
                return true
            }
        }

        /// TOML 1.0 : une table en ligne tient sur une ligne, sans virgule finale.
        mutating func tableEnLigne(chemin: [String], table: Noeud) -> Bool {
            i += 1
            sauterBlancs()
            if voit("}") { i += 1; return true }
            while true {
                guard paire(sous: chemin, dans: table) else { return false }
                sauterBlancs()
                if voit("}") { i += 1; return true }
                guard voit(",") else { return false }
                i += 1
                sauterBlancs()
            }
        }

        mutating func chaineBase() -> String? {
            i += 1
            var sortie = String.UnicodeScalarView()
            while !fin {
                let c = car[i]
                if c == "\"" { i += 1; return String(sortie) }
                if c == "\\" {
                    guard let echappe = echappement() else { return nil }
                    sortie.append(echappe)
                    continue
                }
                guard Self.permis(c) else { return nil }
                sortie.append(c)
                i += 1
            }
            return nil
        }

        mutating func chaineBaseMultiligne() -> String? {
            i += 3
            _ = finDeLigne()
            var sortie = String.UnicodeScalarView()
            while !fin {
                if voit("\"\"\"") {
                    var guillemets = 0
                    while voit("\"", guillemets) { guillemets += 1 }
                    guard guillemets <= 5 else { return nil }
                    for _ in 0..<(guillemets - 3) { sortie.append("\"") }
                    i += guillemets
                    return String(sortie)
                }
                if voit("\\") {
                    if let saut = finDeLigneEchappee() {
                        i = saut
                        continue
                    }
                    guard let echappe = echappement() else { return nil }
                    sortie.append(echappe)
                    continue
                }
                if finDeLigne() { sortie.append("\n"); continue }
                guard Self.permis(car[i]) else { return nil }
                sortie.append(car[i])
                i += 1
            }
            return nil
        }

        /// `\` suivi de blancs puis d'un saut de ligne : la suite reprend au premier caractère
        /// qui n'est ni un blanc ni un saut de ligne.
        func finDeLigneEchappee() -> Int? {
            var j = i + 1
            while j < car.count, car[j] == " " || car[j] == "\t" { j += 1 }
            guard j < car.count, car[j] == "\n" || (car[j] == "\r" && j + 1 < car.count && car[j + 1] == "\n") else {
                return nil
            }
            while j < car.count, [" ", "\t", "\n", "\r"].contains(car[j]) { j += 1 }
            return j
        }

        mutating func echappement() -> Unicode.Scalar? {
            i += 1
            guard !fin else { return nil }
            let c = car[i]
            i += 1
            switch c {
            case "b": return "\u{8}"
            case "t": return "\t"
            case "n": return "\n"
            case "f": return "\u{C}"
            case "r": return "\r"
            case "\"": return "\""
            case "\\": return "\\"
            case "u": return hexadecimal(4)
            case "U": return hexadecimal(8)
            default: return nil
            }
        }

        mutating func hexadecimal(_ longueur: Int) -> Unicode.Scalar? {
            guard i + longueur <= car.count else { return nil }
            let chiffres = String(String.UnicodeScalarView(car[i..<(i + longueur)]))
            guard chiffres.unicodeScalars.allSatisfy({ $0.properties.isASCIIHexDigit }),
                  let valeur = UInt32(chiffres, radix: 16), let scalaire = Unicode.Scalar(valeur) else { return nil }
            i += longueur
            return scalaire
        }

        mutating func chaineLitterale() -> String? {
            i += 1
            var sortie = String.UnicodeScalarView()
            while !fin {
                let c = car[i]
                if c == "'" { i += 1; return String(sortie) }
                guard Self.permis(c) else { return nil }
                sortie.append(c)
                i += 1
            }
            return nil
        }

        mutating func chaineLitteraleMultiligne() -> String? {
            i += 3
            _ = finDeLigne()
            var sortie = String.UnicodeScalarView()
            while !fin {
                if voit("'''") {
                    var apostrophes = 0
                    while voit("'", apostrophes) { apostrophes += 1 }
                    guard apostrophes <= 5 else { return nil }
                    for _ in 0..<(apostrophes - 3) { sortie.append("'") }
                    i += apostrophes
                    return String(sortie)
                }
                if finDeLigne() { sortie.append("\n"); continue }
                guard Self.permis(car[i]) else { return nil }
                sortie.append(car[i])
                i += 1
            }
            return nil
        }
    }
}

/// La grammaire TOML 1.0 d'un nombre, d'une date ou d'une heure, sur les octets ASCII de la valeur.
enum ScalaireTOML {
    static func valide(_ o: [UInt8]) -> Bool {
        entier(o) || flottant(o) || dateHeure(o)
    }

    static func chiffre(_ c: UInt8, base: Int) -> Bool {
        switch base {
        case 2: c == 0x30 || c == 0x31
        case 8: (0x30...0x37).contains(c)
        case 16: (0x30...0x39).contains(c) || (0x41...0x46).contains(c) || (0x61...0x66).contains(c)
        default: (0x30...0x39).contains(c)
        }
    }

    /// Des chiffres, un `_` seulement entre deux chiffres.
    static func groupes(_ o: ArraySlice<UInt8>, base: Int) -> Bool {
        guard let premier = o.first, let dernier = o.last,
              chiffre(premier, base: base), chiffre(dernier, base: base) else { return false }
        var precedentSouligne = false
        for c in o {
            if c == UInt8(ascii: "_") {
                guard !precedentSouligne else { return false }
                precedentSouligne = true
            } else {
                guard chiffre(c, base: base) else { return false }
                precedentSouligne = false
            }
        }
        return true
    }

    static func sansSoulignes(_ o: ArraySlice<UInt8>) -> String {
        String(decoding: o.filter { $0 != UInt8(ascii: "_") }, as: UTF8.self)
    }

    /// Partie entière décimale : pas de zéro en tête, sauf le zéro seul.
    static func decimal(_ o: ArraySlice<UInt8>) -> Bool {
        groupes(o, base: 10) && (o.first != UInt8(ascii: "0") || o.count == 1)
    }

    static func sansSigne(_ o: [UInt8]) -> ArraySlice<UInt8> {
        guard let premier = o.first, premier == UInt8(ascii: "+") || premier == UInt8(ascii: "-") else { return o[...] }
        return o.dropFirst()
    }

    /// Bornée à un entier signé de 64 bits, comme le CLI.
    static func entier(_ o: [UInt8]) -> Bool {
        if o.count > 2, o[0] == UInt8(ascii: "0") {
            let base: Int? = switch o[1] {
            case UInt8(ascii: "x"): 16
            case UInt8(ascii: "o"): 8
            case UInt8(ascii: "b"): 2
            default: nil
            }
            if let base {
                let corps = o.dropFirst(2)
                return groupes(corps, base: base) && Int64(sansSoulignes(corps), radix: base) != nil
            }
        }
        let corps = sansSigne(o)
        guard decimal(corps) else { return false }
        let signe = o.first == UInt8(ascii: "-") ? "-" : ""
        return Int64(signe + sansSoulignes(corps)) != nil
    }

    static func flottant(_ o: [UInt8]) -> Bool {
        let corps = sansSigne(o)
        let texte = String(decoding: corps, as: UTF8.self)
        if texte == "inf" || texte == "nan" { return true }
        let estPoint = { (c: UInt8) in c == UInt8(ascii: ".") }
        let estExposant = { (c: UInt8) in c == UInt8(ascii: "e") || c == UInt8(ascii: "E") }
        guard let finEntier = corps.firstIndex(where: { estPoint($0) || estExposant($0) }),
              decimal(corps[corps.startIndex..<finEntier]) else { return false }
        var reste = corps[finEntier...]
        if let premier = reste.first, estPoint(premier) {
            let fraction = reste.dropFirst()
            let finFraction = fraction.firstIndex(where: estExposant) ?? fraction.endIndex
            guard groupes(fraction[fraction.startIndex..<finFraction], base: 10) else { return false }
            reste = fraction[finFraction...]
        }
        if let premier = reste.first {
            guard estExposant(premier) else { return false }
            var exposant = reste.dropFirst()
            if let signe = exposant.first, signe == UInt8(ascii: "+") || signe == UInt8(ascii: "-") {
                exposant = exposant.dropFirst()
            }
            guard groupes(exposant, base: 10) else { return false }
        }
        guard let valeur = Double(sansSoulignes(o[...])) else { return false }
        return valeur.isFinite
    }

    static func nombre(_ o: ArraySlice<UInt8>) -> Int? {
        guard !o.isEmpty, o.allSatisfy({ chiffre($0, base: 10) }) else { return nil }
        return Int(String(decoding: o, as: UTF8.self))
    }

    /// `AAAA-MM-JJ`, jour compris dans son mois, 29 février des années bissextiles seulement.
    static func date(_ o: ArraySlice<UInt8>) -> Bool {
        let o = Array(o)
        guard o.count == 10, o[4] == UInt8(ascii: "-"), o[7] == UInt8(ascii: "-"),
              let annee = nombre(o[0..<4]), let mois = nombre(o[5..<7]), let jour = nombre(o[8..<10]),
              (1...12).contains(mois) else { return false }
        let bissextile = annee % 4 == 0 && (annee % 100 != 0 || annee % 400 == 0)
        let jours = [31, bissextile ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][mois - 1]
        return (1...jours).contains(jour)
    }

    /// `HH:MM:SS`, fraction facultative ; la seconde 60 est celle d'une seconde intercalaire.
    static func heure(_ o: ArraySlice<UInt8>) -> Bool {
        let o = Array(o)
        guard o.count >= 8, o[2] == UInt8(ascii: ":"), o[5] == UInt8(ascii: ":"),
              let h = nombre(o[0..<2]), let m = nombre(o[3..<5]), let s = nombre(o[6..<8]),
              h <= 23, m <= 59, s <= 60 else { return false }
        guard o.count > 8 else { return true }
        return o[8] == UInt8(ascii: ".") && nombre(o[9...]) != nil
    }

    static func decalage(_ o: ArraySlice<UInt8>) -> Bool {
        let o = Array(o)
        if o == [UInt8(ascii: "Z")] || o == [UInt8(ascii: "z")] { return true }
        guard o.count == 6, o[0] == UInt8(ascii: "+") || o[0] == UInt8(ascii: "-"), o[3] == UInt8(ascii: ":"),
              let h = nombre(o[1..<3]), let m = nombre(o[4..<6]) else { return false }
        return h <= 23 && m <= 59
    }

    static func dateHeure(_ o: [UInt8]) -> Bool {
        if date(o[...]) || heure(o[...]) { return true }
        guard o.count > 11, date(o[0..<10]),
              [UInt8(ascii: "T"), UInt8(ascii: "t"), UInt8(ascii: " ")].contains(o[10]) else { return false }
        let reste = o[11...]
        if let dernier = reste.last, dernier == UInt8(ascii: "Z") || dernier == UInt8(ascii: "z") {
            return heure(reste.dropLast())
        }
        if reste.count > 6 {
            let debutDecalage = reste.endIndex - 6
            let signe = reste[debutDecalage]
            if signe == UInt8(ascii: "+") || signe == UInt8(ascii: "-") {
                return heure(reste[reste.startIndex..<debutDecalage]) && decalage(reste[debutDecalage...])
            }
        }
        return heure(reste)
    }
}
