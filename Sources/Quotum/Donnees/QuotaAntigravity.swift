import Foundation

struct MesureAntigravity: Sendable, Equatable {
    var quota: Quota
    var mesureA: Date
}

/// Ce que le CLI d'Antigravity a pu établir.
///
/// ⚠️ Le rapport ne nomme **aucun compte** ni aucune formule : c'est celui de la session du
/// CLI sur ce Mac, un seul par Mac.
enum ReleveAntigravity: Sendable, Equatable {
    case releve(MesureAntigravity)
    /// Aucun `agy` dans les dossiers d'installation connus.
    case aucun
    /// Un `agy` est là, mais sa version est illisible ou antérieure à celle qui sait répondre
    /// à `/usage` hors session interactive : on ne lui envoie rien.
    case versionNonAdmise
    /// Le binaire trouvé ne passe pas la vérification du lanceur (propriétaire, droits,
    /// lien qui sort des dossiers admis).
    case binaireRefuse
    /// Délai dépassé, code non nul, sortie tronquée ou rapport illisible.
    case indetermine
}

/// Relevé du quota d'Antigravity par son CLI officiel, `agy`.
///
/// ⛔ **La seule voie retenue est le CLI lui-même**, qui s'authentifie seul avec ce qu'il a
/// rangé : Quotum ne lit aucun jeton, aucun identifiant OAuth, aucune ligne de commande de
/// processus. Les autres voies connues — se faire passer pour le client d'Antigravity, lire
/// un jeton CSRF dans `ps` — sont écartées.
///
/// ⛔ **Avant `1.1.11`, `agy -p` pouvait transmettre au modèle une commande à barre oblique
/// qu'il ne savait pas traiter** — donc consommer du quota pour le mesurer. La version est lue
/// d'abord, et rien n'est lancé sur une version illisible ou plus ancienne.
///
/// ⚠️ Aucune réponse réelle n'a été observée : `agy` n'est pas installé sur la machine de
/// développement. La forme du rapport vient de sources tierces (schéma relevé dans un client
/// libre) et de la documentation du mode sans interface.
enum QuotaAntigravity {
    static let nomBinaire = "agy"

    /// Première version dont le mode `-p` traite `/usage` lui-même.
    static let versionMinimale = Version(majeure: 1, mineure: 1, correctif: 11)

    static let argumentsVersion = ["--version"]
    /// `--print-timeout` sous le délai du lanceur : le CLI s'arrête de lui-même avant d'être tué.
    static let argumentsUsage = ["-p", "/usage", "--output-format", "json", "--print-timeout", "8s"]

    static let dureeCinqHeures: TimeInterval = 18_000
    static let dureeSemaine: TimeInterval = 604_800

    /// Les noms de réserve sont des noms de marques : ils ne se traduisent pas.
    static let reserveGemini = "Gemini"
    static let reserveClaudeGPT = "Claude + GPT"

    /// Où les installeurs posent `agy` : l'installeur natif, puis Homebrew (Apple Silicon, Intel).
    static func dossiersRecherche(home: URL) -> [URL] {
        [home.appendingPathComponent(".local/bin", isDirectory: true),
         URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
         URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)]
    }

    /// Sous quelles racines le binaire réel peut vivre : un cask Homebrew pose dans `bin` un
    /// lien vers `Caskroom`, sous le même préfixe.
    static func racinesAutorisees(home: URL) -> [URL] {
        [home.appendingPathComponent(".local", isDirectory: true),
         URL(fileURLWithPath: "/opt/homebrew", isDirectory: true),
         URL(fileURLWithPath: "/usr/local", isDirectory: true)]
    }

    static func localiser(home: URL) -> URL? {
        LanceurCLISysteme.localiser(nom: nomBinaire,
                                    dans: dossiersRecherche(home: home),
                                    racines: racinesAutorisees(home: home))
    }

    /// `binaire` vient de `localiser` ; `lanceur` est injecté, sans valeur par défaut, pour
    /// qu'un test ne puisse pas lancer le vrai CLI.
    static func relever(binaire: URL?, lanceur: LanceurCLI) async -> ReleveAntigravity {
        guard let binaire else { return .aucun }

        let version = await lanceur(binaire, argumentsVersion)
        switch version.issue {
        case .introuvable: return .aucun
        case .refusee: return .binaireRefuse
        case .delaiDepasse: return .indetermine
        case .terminee(let code):
            guard code == 0, !version.tronquee,
                  let lue = Version(sortie: version.sortie),
                  lue >= versionMinimale else { return .versionNonAdmise }
        }

        let usage = await lanceur(binaire, argumentsUsage)
        let mesureA = Date()
        switch usage.issue {
        case .introuvable: return .aucun
        case .refusee: return .binaireRefuse
        case .delaiDepasse: return .indetermine
        case .terminee(let code):
            guard code == 0, !usage.tronquee, let quota = decoderRapport(usage.sortie) else {
                Journal.donnees.notice("Quota Antigravity : rapport de agy inexploitable (code \(code))")
                return .indetermine
            }
            return .releve(MesureAntigravity(quota: quota, mesureA: mesureA))
        }
    }

    // MARK: - Version

    struct Version: Sendable, Equatable, Comparable {
        var majeure: Int
        var mineure: Int
        var correctif: Int

        init(majeure: Int, mineure: Int, correctif: Int) {
            self.majeure = majeure
            self.mineure = mineure
            self.correctif = correctif
        }

        /// Seule la forme nue `x.y.z` est admise : tout autre texte est une version qu'on ne
        /// sait pas lire, donc refusée.
        init?(sortie: Data) {
            guard let texte = String(data: sortie, encoding: .utf8) else { return nil }
            let coupe = texte.trimmingCharacters(in: .whitespacesAndNewlines)
            let parties = coupe.split(separator: ".", omittingEmptySubsequences: false)
            guard parties.count == 3,
                  parties.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
                  let a = Int(parties[0]), let b = Int(parties[1]), let c = Int(parties[2]) else { return nil }
            self.init(majeure: a, mineure: b, correctif: c)
        }

        static func < (g: Version, d: Version) -> Bool {
            (g.majeure, g.mineure, g.correctif) < (d.majeure, d.mineure, d.correctif)
        }
    }

    // MARK: - Rapport

    /// Le rapport est un objet JSON unique : `status` doit valoir `SUCCESS` et
    /// `command.name` `usage`. Sous `command.data.groups[]`, chaque groupe (une famille de
    /// modèles) porte ses `buckets[]` : `id`, `name`, `window`, `remaining_fraction` (ou
    /// `remaining.remaining_fraction`), `reset_time`, `disabled`.
    ///
    /// ⚠️ Ce sont des **restants** entre 0 et 1, inversés ici en consommé. Un restant fini
    /// hors de ces bornes se borne avec la fenêtre ; un restant absent, illisible ou dont
    /// l'inversion n'est pas finie ne fait aucune fenêtre.
    ///
    /// Les fenêtres posées sont les 5 h puis les hebdomadaires, Gemini avant Claude + GPT.
    /// Une famille ou une cadence qu'on ne sait pas classer est laissée de côté plutôt que
    /// nommée au hasard. Aucune fenêtre lisible : `nil`.
    static func decoderRapport(_ donnees: Data) -> Quota? {
        guard let rapport = decoderObjet(donnees),
              rapport.status == "SUCCESS",
              rapport.command?.name == "usage",
              let groupes = rapport.command?.data?.groups else { return nil }

        var trouvees: [Cle: Fenetre] = [:]
        for groupe in groupes {
            for seau in groupe.buckets ?? [] {
                guard seau.disabled != true,
                      let famille = famille(seau: seau, groupe: groupe),
                      let cadence = cadence(seau: seau),
                      let restant = seau.restant else { continue }
                let cle = Cle(famille: famille, cadence: cadence)
                guard trouvees[cle] == nil,
                      let fenetre = fenetre(restant: restant,
                                            cadence: cadence,
                                            famille: famille,
                                            retour: seau.reset_time?.date) else { continue }
                trouvees[cle] = fenetre
            }
        }

        let ordre: [Cle] = [Cle(famille: .gemini, cadence: .cinqHeures),
                            Cle(famille: .claudeGPT, cadence: .cinqHeures),
                            Cle(famille: .gemini, cadence: .semaine),
                            Cle(famille: .claudeGPT, cadence: .semaine)]
        let fenetres = ordre.compactMap { trouvees[$0] }
        return fenetres.isEmpty ? nil : Quota(fenetres)
    }

    /// La documentation annonce une seule ligne ; si un avertissement la précède, seule la
    /// dernière ligne qui commence par `{` est tentée.
    private static func decoderObjet(_ donnees: Data) -> Rapport? {
        let decodeur = JSONDecoder()
        if let rapport = try? decodeur.decode(Rapport.self, from: donnees) { return rapport }
        guard let texte = String(data: donnees, encoding: .utf8),
              let ligne = texte.split(whereSeparator: \.isNewline)
                  .last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }) else { return nil }
        return try? decodeur.decode(Rapport.self, from: Data(ligne.utf8))
    }

    private static func fenetre(restant: Double, cadence: Cadence, famille: Famille, retour: Date?) -> Fenetre? {
        let consomme = (1 - restant) * 100
        let reserve = famille == .gemini ? reserveGemini : reserveClaudeGPT
        switch cadence {
        case .cinqHeures:
            return Fenetre(libelle: Fenetre.libelleCinqHeures, sorte: .cinqHeures, utilisation: consomme,
                           seRechargeA: retour, duree: dureeCinqHeures, reserve: reserve)
        case .semaine:
            return Fenetre(libelle: Fenetre.libelleSeptJours, sorte: .septJours, utilisation: consomme,
                           seRechargeA: retour, duree: dureeSemaine, reserve: reserve)
        }
    }

    private enum Famille: Hashable { case gemini, claudeGPT }
    private enum Cadence: Hashable { case cinqHeures, semaine }
    private struct Cle: Hashable { var famille: Famille; var cadence: Cadence }

    /// L'identifiant du seau d'abord (`gemini-…`, `3p-…`), le nom du groupe ensuite.
    private static func famille(seau: Seau, groupe: Groupe) -> Famille? {
        let id = (seau.id ?? seau.bucket_id ?? "").lowercased()
        if id.contains("gemini") { return .gemini }
        if id.hasPrefix("3p") || id.contains("third-party") { return .claudeGPT }
        let nom = (groupe.name ?? groupe.display_name ?? "").lowercased()
        if nom.contains("gemini") { return .gemini }
        if nom.contains("claude") || nom.contains("gpt") { return .claudeGPT }
        return nil
    }

    /// Le champ `window` s'il est publié, sinon le suffixe de l'identifiant.
    private static func cadence(seau: Seau) -> Cadence? {
        let brut: String
        if let fenetre = seau.window?.trimmingCharacters(in: .whitespacesAndNewlines), !fenetre.isEmpty {
            brut = fenetre
        } else if let id = seau.id ?? seau.bucket_id {
            brut = String(id.split(separator: "-").last ?? "")
        } else {
            return nil
        }
        switch brut.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "5h", "5-hour", "five-hour", "five hour", "session": return .cinqHeures
        case "weekly", "week", "7d": return .semaine
        default: return nil
        }
    }

    // MARK: - Schéma

    private struct Rapport: Decodable {
        var status: String?
        var command: Commande?
    }

    private struct Commande: Decodable {
        var name: String?
        var data: Donnees?
    }

    private struct Donnees: Decodable {
        var groups: [Groupe]?
    }

    private struct Groupe: Decodable {
        var name: String?
        var display_name: String?
        var buckets: [Seau]?

        /// Un seau illisible ne coûte que lui-même.
        init(from decodeur: Decoder) throws {
            let conteneur = try decodeur.container(keyedBy: CodingKeys.self)
            name = try? conteneur.decodeIfPresent(String.self, forKey: .name)
            display_name = try? conteneur.decodeIfPresent(String.self, forKey: .display_name)
            buckets = (try? conteneur.decodeIfPresent([Souple<Seau>].self, forKey: .buckets))?
                .compactMap(\.valeur)
        }

        private enum CodingKeys: String, CodingKey { case name, display_name, buckets }
    }

    private struct Seau: Decodable {
        var id: String?
        var bucket_id: String?
        var window: String?
        var disabled: Bool?
        var remaining_fraction: Souple<Nombre>?
        var remaining: Souple<Restant>?
        var reset_time: Horodatage?

        var restant: Double? {
            remaining_fraction?.valeur?.valeur ?? remaining?.valeur?.remaining_fraction?.valeur
        }
    }

    private struct Restant: Decodable {
        var remaining_fraction: Nombre?
    }

    /// Un nombre JSON, ou un nombre écrit en chaîne ; jamais une valeur non finie.
    private struct Nombre: Decodable {
        let valeur: Double?

        init(from decodeur: Decoder) throws {
            let conteneur = try decodeur.singleValueContainer()
            if let nombre = try? conteneur.decode(Double.self) {
                valeur = nombre.isFinite ? nombre : nil
            } else if let texte = try? conteneur.decode(String.self),
                      let nombre = Double(texte.trimmingCharacters(in: .whitespaces)),
                      nombre.isFinite {
                valeur = nombre
            } else {
                valeur = nil
            }
        }
    }
}
