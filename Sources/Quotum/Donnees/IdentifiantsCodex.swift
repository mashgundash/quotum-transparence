import Foundation

/// Le jeton OAuth posé par le dernier `codex login`. Il sert à un appel et n'est ni
/// copié sur disque, ni journalisé, ni conservé au-delà du relevé.
struct JetonCodex: Sendable {
    let valeur: String
    /// Identifiant du compte ChatGPT **déclaré** par `auth.json` — un UUID. Mesuré le
    /// 2026-09-17 : `/backend-api/wham/usage` rend `account_id` vide quand l'en-tête
    /// `ChatGPT-Account-Id` manque, et la réponse ne dit alors plus à quel compte elle
    /// appartient. Il sert à cet en-tête ; ⛔ il ne prouve rien du jeton, et n'autorise
    /// aucune lecture ni dépense ciblée — c'est `compteProuve` qui le fait.
    let compteIdentifiant: String?
    /// Le compte que les jetons eux-mêmes nomment, dans leurs revendications.
    let compteProuve: PreuveCompteCodex

    /// ⚠️ `.absente` par défaut : un jeton construit sans preuve n'ouvre aucune lecture
    /// ciblée ni aucune dépense, au lieu de passer en silence.
    init(valeur: String, compteIdentifiant: String?, compteProuve: PreuveCompteCodex = .absente) {
        self.valeur = valeur
        self.compteIdentifiant = compteIdentifiant
        self.compteProuve = compteProuve
    }

    /// La seule règle qui autorise une action ciblée sur un compte — lire sa réserve, ou
    /// dépenser une de ses réinitialisations. ⛔ Sans compte attendu, sans preuve, ou avec
    /// des preuves qui se contredisent, la réponse est non : se tromper de compte ici
    /// débiterait l'un pour l'autre, sans retour.
    func estDuCompte(_ attendu: String?) -> Bool {
        guard let attendu = attendu?.trimmingCharacters(in: .whitespacesAndNewlines), !attendu.isEmpty,
              case .prouve(let compte) = compteProuve else { return false }
        return compte == attendu.lowercased()
    }
}

/// Ce que les jetons d'`auth.json` disent eux-mêmes de leur compte.
///
/// `account_id` n'est qu'une déclaration posée à côté du jeton : un fichier recopié, ou
/// réécrit à moitié par un `codex login`, peut l'apparier au jeton d'un autre compte. Les
/// revendications du jeton d'accès et de l'`id_token`, elles, viennent du même émetteur
/// que le jeton envoyé. ⚠️ Leur signature n'est pas vérifiée — Quotum n'a pas la clé de
/// l'émetteur, et le serveur la vérifie de toute façon : il s'agit de relier le jeton à un
/// compte, pas de l'authentifier.
enum PreuveCompteCodex: Sendable, Equatable {
    /// Le compte nommé, en minuscules ; toutes les sources présentes s'accordent.
    case prouve(String)
    /// Le jeton d'accès ne nomme pas son compte — quoi qu'en dise l'`id_token`.
    case absente
    /// Deux sources — jeton d'accès, `id_token`, déclaration — nomment des comptes
    /// différents, ou l'une est présente mais illisible.
    case contradictoire
}

/// Ce qu'une lecture d'`auth.json` a établi — même partition que `LectureTrousseau`,
/// pour la même raison : un fichier illisible et un poste sans session Codex se
/// ressemblaient, et un seul des deux dit quelque chose du compte.
enum LectureCodex: Sendable {
    case jeton(JetonCodex), jetonPersonnel(JetonPersonnelCodex)
    /// Aucun fichier, ou un fichier lisible sans jeton ChatGPT — un poste branché sur
    /// une clé d'API en est là. Il n'y a rien à relever, et rien à reconnecter.
    case absent
    /// Lecture empêchée — droits refusés, fichier illisible, contenu inexploitable.
    /// Rien n'est établi : le jeton peut être là, intact.
    case empechee
}

/// Les identifiants que le CLI `codex` dépose sur le disque. Pendant de `Trousseau`
/// côté Claude, à ceci près que la source est un fichier et non le Trousseau : la
/// lecture n'ouvre aucune fenêtre d'autorisation, mais elle reste hors du fil
/// principal — le panneau doit se dessiner pendant que le disque répond.
enum IdentifiantsCodex {
    /// `CODEX_HOME` déplace tout le dossier de Codex, `auth.json` compris. Le lire ici
    /// plutôt que de figer `~/.codex` évite de relever le quota d'un autre profil que
    /// celui dont le CLI se sert réellement.
    static func fichier(environnement: [String: String] = ProcessInfo.processInfo.environment,
                        accueil: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let declare = environnement["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let declare, !declare.isEmpty else {
            return accueil.appendingPathComponent(".codex/auth.json")
        }
        return URL(fileURLWithPath: (declare as NSString).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    static func jeton(fichier url: URL? = nil, cheminSansLien: Bool = false) async -> LectureCodex {
        let cible = url ?? fichier()
        return await HorsFil.executer { lire(cible, cheminSansLien: cheminSansLien) }
    }

    /// ⚠️ Jamais `Data(contentsOf:)` ici : un tube nommé à ce chemin la ferait attendre
    /// sans fin, et la réinitialisation qui attend ce jeton retiendrait sa réservation.
    static func lire(_ url: URL, cheminSansLien: Bool = false) -> LectureCodex {
        do {
            return classer(try LectureFichier.lire(url, cheminSansLien: cheminSansLien))
        } catch .absent {
            Journal.donnees.debug("Codex : aucun auth.json sur cette machine")
            return .absent
        } catch {
            Journal.donnees.notice("Codex : auth.json illisible (\(String(describing: error)))")
            return .empechee
        }
    }

    /// Ce qu'un contenu d'`auth.json` établit. Un JSON valide sans jeton ChatGPT
    /// conclut — ce poste n'a pas de session, il est sur une clé d'API ou déconnecté ;
    /// un contenu illisible ne conclut rien, et le prendre pour une absence ferait
    /// disparaître en silence la seule mesure directe de ce fournisseur.
    static func classer(_ donnees: Data) -> LectureCodex {
        guard let enveloppe = try? JSONDecoder().decode(Enveloppe.self, from: donnees) else {
            Journal.donnees.notice("Codex : auth.json lu mais inexploitable")
            return .empechee
        }
        let brut = enveloppe.jetons?.acces?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !brut.isEmpty else { return sansConnexionOAuth(enveloppe) }
        let declare = nonVide(enveloppe.jetons?.compte)
        return .jeton(JetonCodex(valeur: brut,
                                 compteIdentifiant: declare,
                                 compteProuve: preuve(acces: brut, idToken: enveloppe.jetons?.idToken,
                                                      declare: declare)))
    }

    /// Le jeton d'accès, celui qui part, doit nommer son compte : un `id_token` voisin peut venir
    /// d'un autre `codex login`. L'`id_token` et `account_id`, s'ils existent, nomment ce compte-là
    /// aussi. Une source présente mais illisible ne se tait pas : elle rend la preuve contradictoire.
    static func preuve(acces: String, idToken: Souple<String>?, declare: String?) -> PreuveCompteCodex {
        var sources = [revendication(acces)]
        if let idToken {
            sources.append(idToken.valeur.map(revendication) ?? .illisible)
        }
        var comptes = Set<String>()
        for source in sources {
            switch source {
            case .aucune: continue
            case .illisible: return .contradictoire
            case .compte(let compte): comptes.insert(compte)
            }
        }
        guard let compte = comptes.first, case .compte = sources[0] else { return .absente }
        guard comptes.count == 1, declare.map({ $0.lowercased() == compte }) ?? true else { return .contradictoire }
        return .prouve(compte)
    }

    enum Revendication: Equatable {
        /// Pas un JWT, ou un JWT qui ne nomme aucun compte.
        case aucune
        case compte(String)
        /// Un JWT dont la charge ne se lit pas, ou dont le compte n'est pas une chaîne.
        case illisible
    }

    /// `chatgpt_account_id`, sous l'espace de noms où OpenAI le range — une clé qui a la forme
    /// d'une adresse, jamais jointe —, ou à la racine de la charge. ⚠️ Lu **sans vérifier la signature** — voir
    /// `PreuveCompteCodex`.
    static func revendication(_ jeton: String) -> Revendication {
        let segments = jeton.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return .aucune }
        guard let charge = IdentifiantsCursor.base64url(String(segments[1])),
              let objet = (try? JSONSerialization.jsonObject(with: charge)) as? [String: Any]
        else { return .illisible }
        let espace = objet["https://api.openai.com/auth"] as? [String: Any]
        guard let brut = espace?["chatgpt_account_id"] ?? objet["chatgpt_account_id"],
              !(brut is NSNull) else { return .aucune }
        guard let texte = brut as? String, let compte = nonVide(texte) else { return .illisible }
        return .compte(compte.lowercased())
    }

    /// La connexion OAuth l'emporte : c'est elle que le CLI emploie quand les deux sont là. Sans
    /// elle, un jeton personnel se mesure ; sans l'un ni l'autre, rien n'est à relever.
    private static func sansConnexionOAuth(_ enveloppe: Enveloppe) -> LectureCodex {
        guard let personnel = nonVide(enveloppe.personnel?.valeur) ?? nonVide(enveloppe.personnelCamel?.valeur) else {
            return .absent
        }
        return .jetonPersonnel(JetonPersonnelCodex(valeur: personnel))
    }

    private struct Enveloppe: Decodable {
        struct Jetons: Decodable {
            var acces: String?
            var compte: String?
            var idToken: Souple<String>?

            enum CodingKeys: String, CodingKey {
                case acces = "access_token"
                case compte = "account_id"
                case idToken = "id_token"
            }
        }

        var jetons: Jetons?
        /// Décodés à part (`Souple`) : un jeton personnel d'un autre type ne rend pas tout le
        /// fichier illisible.
        var personnel: Souple<String>?
        var personnelCamel: Souple<String>?

        enum CodingKeys: String, CodingKey {
            case jetons = "tokens"
            case personnel = "personal_access_token"
            case personnelCamel = "personalAccessToken"
        }
    }

    private static func nonVide(_ valeur: String?) -> String? {
        guard let coupe = valeur?.trimmingCharacters(in: .whitespacesAndNewlines), !coupe.isEmpty else {
            return nil
        }
        return coupe
    }
}
