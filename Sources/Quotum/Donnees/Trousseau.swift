import Foundation

/// Le jeton OAuth posé par le dernier `/login` de Claude Code. Il sert à un appel et
/// n'est ni copié sur disque, ni journalisé, ni conservé au-delà du rafraîchissement.
struct JetonClaudeCode: Sendable {
    let valeur: String
    let expireA: Date?
}

/// Ce qu'une lecture du Trousseau a établi. Un refus de lecture et une absence de
/// jeton se ressemblaient — les deux rendaient `nil` — et une seule des deux dit
/// quelque chose du compte : l'absence. Les confondre faisait disparaître une demande
/// de reconnexion sur une simple autorisation refusée, sans que rien ne l'ait réglée.
enum LectureTrousseau: Sendable {
    case jeton(JetonClaudeCode)
    /// `security` a répondu que l'élément n'existe pas : cette machine n'a pas de
    /// session Claude Code. C'est la seule conclusion que porte une lecture sans jeton.
    case absent
    /// Lecture empêchée — autorisation refusée, utilitaire injoignable, délai dépassé,
    /// élément lu mais inexploitable. Rien n'est établi : le jeton peut être là, intact.
    case empechee
}

/// Ce qu'une salve de lectures du Trousseau a rapporté. Les deux champs ne se
/// déduisent pas l'un de l'autre, et c'est tout l'intérêt : un jeton obtenu à la
/// première tentative reste bon quand la suivante atteint le délai — le cas du
/// Trousseau verrouillé, celui-là même pour lequel le délai existe —, mais
/// l'absence, elle, n'est plus établie : le jeton peut être derrière la tentative
/// qui manque.
struct LectureBrute: Sendable {
    /// Les tentatives qui ont abouti, dans l'ordre des comptes candidats.
    var resultats: [ResultatProcessus] = []
    /// Une tentative n'a pas abouti — délai dépassé, utilitaire injoignable, ou
    /// service vide. Ce qui précède reste valable ; ce qui manque n'établit rien.
    var interrompue = false
}

/// Ce qui exécute une tentative. Paramétrable pour une seule raison : la garde qui
/// conserve un jeton déjà lu quand la tentative suivante n'aboutit pas ne s'éprouve
/// pas autrement — aucune tentative réelle ne tombe en panne à la demande.
typealias LanceurProcessus =
    @Sendable (_ executable: String, _ arguments: [String], _ delai: TimeInterval) async throws
        -> ResultatProcessus

enum Trousseau {
    static let serviceClaudeCode = "Claude Code-credentials"

    private static let utilitaire = "/usr/bin/security"
    /// Sortie de `security` quand l'élément n'existe pas — mesuré, pas déduit.
    static let codeAbsent: Int32 = 44
    /// Une demande d'autorisation attend un humain, d'où une borne large ; elle
    /// existe surtout pour qu'il y en ait une, là où le framework bloquait sans fin.
    private static let delai: TimeInterval = 60

    /// Le Trousseau peut ouvrir une fenêtre d'autorisation, d'où l'appel asynchrone :
    /// le panneau doit rester dessinable pendant qu'elle attend une réponse.
    static func jetonClaudeCode() async -> LectureTrousseau {
        await lire(service: serviceClaudeCode)
    }

    /// Lecture par l'utilitaire `security`, et non par `SecItemCopyMatching` : il
    /// figure déjà parmi les applications de confiance de l'élément, alors que l'app
    /// n'y entre que par son `cdhash`. Signée en ad-hoc, elle change d'identité à
    /// chaque build, et le Trousseau redemande alors l'autorisation — treize fois en
    /// quarante-quatre heures, mesuré le 2026-09-17.
    ///
    /// Le secret ne transite que par la sortie standard : `find-generic-password` ne
    /// reçoit que le service et le compte en argument. C'est l'écriture d'un jeton,
    /// que cette app ne fait jamais, qui l'exposerait dans la table des processus.
    /// **La seule invocation de `security` du dépôt.** Warp range lui aussi son jeton au
    /// Trousseau, et la tentation était d'y recopier cette procédure : une copie ne reçoit
    /// pas les gardes ajoutés après coup — ni celui du service vide, ni le délai, ni le
    /// code 44 — et rien ne signale laquelle des deux fait autorité.
    ///
    /// Rend les résultats bruts, un par compte candidat, à charge de l'appelant de les
    /// classer : le décodage du secret diffère d'un fournisseur à l'autre, pas l'appel.
    static let lanceurSysteme: LanceurProcessus = { try await Processus.executer($0, $1, delai: $2) }

    static func executerLecture(service: String,
                                comptes: [String?],
                                sujet: String,
                                lanceur: LanceurProcessus = lanceurSysteme) async -> LectureBrute {
        // `security -s ""` sort en code 0 et imprime le secret d'un autre élément :
        // sans ce garde, un service vide rendrait le mot de passe d'autrui classé
        // en `.jeton`. Mesuré, pas supposé.
        guard !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return LectureBrute(interrompue: true)
        }
        var brute = LectureBrute()
        for compte in comptes {
            var arguments = ["find-generic-password", "-s", service]
            if let compte { arguments += ["-a", compte] }
            arguments.append("-w")
            do {
                brute.resultats.append(try await lanceur(utilitaire, arguments, delai))
            } catch {
                // Un second essai buterait sur la même panne, en repayant le délai.
                Journal.donnees.notice("\(sujet) : \(utilitaire) inexploitable (\(error))")
                brute.interrompue = true
                return brute
            }
        }
        return brute
    }

    static func lire(service: String) async -> LectureTrousseau {
        // Claude Code pose le nom d'utilisateur en compte ; la seconde tentative,
        // sans compte, survit à un changement de cette convention.
        conclure(await executerLecture(service: service,
                                       comptes: [NSUserName(), nil],
                                       sujet: "Trousseau"),
                 service: service)
    }

    /// Ce qu'une salve rapportée établit. Un jeton l'emporte où qu'il se trouve, et
    /// une tentative qui n'a pas abouti ensuite ne le retire pas. Sans jeton, en
    /// revanche, la moindre tentative manquante retire sa conclusion à la boucle : le
    /// jeton se trouve peut-être derrière elle, et conclure à l'absence réclamerait
    /// une reconnexion sur une session que rien n'a infirmée.
    static func conclure(_ brute: LectureBrute, service: String) -> LectureTrousseau {
        var empechee = brute.interrompue

        for resultat in brute.resultats {
            switch classer(resultat) {
            case .jeton(let jeton):
                return .jeton(jeton)
            case .empechee:
                // Le code, jamais la sortie : c'est elle qui porte le secret.
                if resultat.reussi {
                    Journal.donnees.notice("Trousseau : élément lu mais inexploitable")
                } else {
                    Journal.donnees.notice("Trousseau : lecture refusée (code \(resultat.code))")
                }
                empechee = true
            case .absent:
                continue
            }
        }

        guard !empechee else { return .empechee }
        Journal.donnees.notice("Trousseau : aucun jeton pour « \(service) »")
        return .absent
    }

    /// Ce qu'une tentative de `security` établit. Le code 44 est le seul qui conclue —
    /// l'élément n'existe pas ; tous les autres disent qu'on n'a pas pu lire, pas qu'il
    /// n'y a rien à lire. Une sortie qui ne rend aucun jeton ne conclut rien non plus :
    /// l'élément est là, c'est son contenu qui échappe.
    static func classer(_ resultat: ResultatProcessus) -> LectureTrousseau {
        guard resultat.reussi else {
            return resultat.code == codeAbsent ? .absent : .empechee
        }
        guard let jeton = decoder(Data(resultat.sortie.utf8)) else { return .empechee }
        return .jeton(jeton)
    }

    private struct Enveloppe: Decodable {
        struct OAuth: Decodable {
            var accessToken: String?
            var expiresAt: Horodatage?
        }

        var claudeAiOauth: OAuth?
        var accessToken: String?
        var expiresAt: Horodatage?
    }

    static func decoder(_ donnees: Data) -> JetonClaudeCode? {
        if let enveloppe = try? JSONDecoder().decode(Enveloppe.self, from: donnees) {
            let oauth = enveloppe.claudeAiOauth
            if let brut = oauth?.accessToken ?? enveloppe.accessToken {
                let valeur = brut.trimmingCharacters(in: .whitespacesAndNewlines)
                if !valeur.isEmpty {
                    return JetonClaudeCode(valeur: valeur,
                                           expireA: (oauth?.expiresAt ?? enveloppe.expiresAt)?.date)
                }
            }
            return nil
        }
        // Certains outils déposent le jeton nu plutôt qu'une enveloppe JSON.
        guard let texte = String(data: donnees, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !texte.isEmpty,
              !texte.contains(where: { $0.isWhitespace }) else { return nil }
        return JetonClaudeCode(valeur: texte, expireA: nil)
    }
}
