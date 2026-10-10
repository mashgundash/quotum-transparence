import Foundation

/// Ce que `~/.claude.json` dit du compte sur lequel Claude Code est connecté. C'est
/// la seule façon de nommer le porteur du jeton du Trousseau sans appeler le réseau :
/// sans elle, un `/api/oauth/profile` muet laisse le relevé anonyme, et le seul
/// pourcentage exact du panneau s'affiche sur une ligne à part.
///
/// Tout y est facultatif. Le fichier est écrit par Claude Code, pas par une API
/// documentée : une clé peut valoir `null` — `seatTier` l'est sur cette machine —
/// disparaître, ou changer de type d'une version à l'autre. Une identité dont rien
/// n'est exploitable n'existe pas : elle vaut `nil`, jamais une coquille vide.
struct IdentiteClaudeCode: Sendable, Equatable {
    /// Clé d'appariement fiable : deux comptes peuvent partager un courriel sans être
    /// la même organisation, jamais cet identifiant.
    var organisationIdentifiant: String?
    var courriel: String?
    var organisation: String?

    var estVide: Bool {
        organisationIdentifiant == nil && courriel == nil && organisation == nil
    }
}

/// Lecture de `~/.claude.json`. Le fichier ne porte aucun jeton — seulement l'identité
/// du dernier `/login` —, et rien n'y est écrit : l'app n'a pas à toucher la
/// configuration de Claude Code.
enum FichierClaudeCode {
    static let nom = ".claude.json"

    static var fichier: URL {
        fichier(environnement: ProcessInfo.processInfo.environment,
                accueil: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// `CLAUDE_CONFIG_DIR` déplace tout le dossier de configuration de Claude Code,
    /// ce fichier compris. L'ignorer ferait lire l'identité d'une autre installation
    /// que celle dont le Trousseau porte le jeton.
    static func fichier(environnement: [String: String], accueil: URL) -> URL {
        let declare = environnement["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !declare.isEmpty else { return accueil.appendingPathComponent(nom) }
        return URL(fileURLWithPath: (declare as NSString).expandingTildeInPath,
                   isDirectory: true).appendingPathComponent(nom)
    }

    /// Un fichier absent est le cas ordinaire — Claude Code n'est pas installé, ou
    /// personne ne s'y est connecté —, pas une panne. La lecture sort du fil principal
    /// comme celle des proxies : le panneau doit rester dessinable pendant ce temps.
    ///
    /// Le fichier grossit avec l'historique des projets (quelques Mo relevés) : la borne
    /// laisse une large marge, sans laisser un fichier démesuré ou spécial occuper la lecture.
    static let tailleMaximale = 32 << 20

    static func lire(depuis url: URL? = nil) async -> IdentiteClaudeCode? {
        let cible = url ?? fichier
        return await HorsFil.executer {
            guard let donnees = try? LectureFichier.lire(cible, tailleMaximale: tailleMaximale) else { return nil }
            let identite = decoder(donnees)
            if identite == nil {
                Journal.donnees.notice("Identité Claude Code : fichier présent, rien d'exploitable")
            }
            return identite
        }
    }

    // MARK: - Analyse pure

    private struct Contenu: Decodable {
        struct CompteOAuth: Decodable {
            var identifiantOrganisation: String?
            var courriel: String?
            var nomOrganisation: String?

            enum CodingKeys: String, CodingKey {
                case identifiantOrganisation = "organizationUuid"
                case courriel = "emailAddress"
                case nomOrganisation = "organizationName"
            }

            /// Chaque clé est lue pour elle seule : une valeur qui change de type
            /// emporterait sinon les deux autres avec elle, et le format n'est
            /// garanti par personne.
            init(from decodeur: Decoder) throws {
                let boite = try decodeur.container(keyedBy: CodingKeys.self)
                identifiantOrganisation = (try? boite.decodeIfPresent(String.self,
                                                                      forKey: .identifiantOrganisation)) ?? nil
                courriel = (try? boite.decodeIfPresent(String.self, forKey: .courriel)) ?? nil
                nomOrganisation = (try? boite.decodeIfPresent(String.self, forKey: .nomOrganisation)) ?? nil
            }
        }

        var compte: CompteOAuth?

        enum CodingKeys: String, CodingKey {
            case compte = "oauthAccount"
        }
    }

    static func decoder(_ donnees: Data) -> IdentiteClaudeCode? {
        guard let contenu = try? JSONDecoder().decode(Contenu.self, from: donnees),
              let compte = contenu.compte else { return nil }
        let identite = IdentiteClaudeCode(organisationIdentifiant: nonVide(compte.identifiantOrganisation),
                                          courriel: nonVide(compte.courriel),
                                          organisation: nonVide(compte.nomOrganisation))
        return identite.estVide ? nil : identite
    }

    private static func nonVide(_ valeur: String?) -> String? {
        guard let coupe = valeur?.trimmingCharacters(in: .whitespacesAndNewlines), !coupe.isEmpty else {
            return nil
        }
        return coupe
    }
}
