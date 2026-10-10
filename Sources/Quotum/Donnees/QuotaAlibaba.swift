import CoreFoundation
import Foundation

/// La console Bailian que `bl` interroge : le Token Plan international et celui de Chine
/// continentale sont deux comptes distincts, servis par deux consoles.
enum ConsoleBailian: Sendable, Equatable, CaseIterable {
    case internationale
    case chine

    var region: String {
        switch self {
        case .internationale: "ap-southeast-1"
        case .chine: "cn-beijing"
        }
    }

    var site: String {
        switch self {
        case .internationale: "international"
        case .chine: "domestic"
        }
    }
}

struct MesureAlibaba: Sendable, Equatable {
    /// Jamais vide : une sortie sans fenêtre fait un `ReleveAlibaba.aucuneFenetre`.
    var quota: Quota
    /// L'heure de la lecture : la sortie de `bl` ne date pas sa mesure.
    var mesureA: Date
}

/// Pourquoi une sortie lisible ne donne aucune fenêtre.
enum SansFenetreAlibaba: Sendable, Equatable {
    /// Aucune part consommée publiée : un pool de crédits d'équipe, ou une forme inconnue.
    /// ⛔ Un solde n'est pas une fenêtre : sans dotation **et** échéance, rien ne se dessine.
    case aucunePart
    /// Des parts publiées, aucune n'est un rapport lisible entre 0 et 1.
    case partIllisible
    /// Des parts lisibles, aucune avec son échéance.
    case sansEcheance
}

enum ReleveAlibaba: Sendable, Equatable {
    case releve(MesureAlibaba)
    case aucuneFenetre(SansFenetreAlibaba)
    /// La console répond que la session de `bl` est absente ou expirée.
    case reconnexionNecessaire
    /// Rien d'établi : délai dépassé, lancement refusé, sortie tronquée ou illisible, code de
    /// sortie non nul, réponse marquée en échec.
    case indetermine
    /// `bl` n'est à aucun des emplacements connus.
    case absent
}

/// Relevé du Token Plan d'Alibaba Cloud Model Studio par le CLI officiel Bailian (`bl`),
/// lancé en lecture seule par un `LanceurCLI` injecté.
///
/// ⛔ Aucun repli : ni cookie de navigateur, ni appel direct à la console. Si `bl` ne dit
/// rien de lisible, la ligne n'a pas de mesure.
enum QuotaAlibaba {
    static func arguments(console: ConsoleBailian) -> [String] {
        ["usage", "token-plan",
         "--console-region", console.region,
         "--console-site", console.site,
         "--output", "json"]
    }

    /// Les emplacements où les installations officielles posent `bl` : `~/.local/bin` pour
    /// le script `install.sh` (lien vers `~/.local/share/bailian-cli/versions/<v>/bl`), puis
    /// les préfixes npm de Homebrew et du paquet Node officiel pour `npm i -g bailian-cli`.
    /// Liste fermée, chemins absolus, essayés dans cet ordre.
    static func emplacements(accueil: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [accueil.appendingPathComponent(".local/bin/bl"),
         URL(fileURLWithPath: "/opt/homebrew/bin/bl"),
         URL(fileURLWithPath: "/usr/local/bin/bl")]
    }

    /// ⚠️ `bl` est un nom court que d'autres outils portent. Le lanceur vérifie que le chemin
    /// réel, liens résolus, vient de l'une de ces deux installations avant d'exécuter.
    static let installationsAttendues = ["/.local/share/bailian-cli/versions/", "/node_modules/bailian-cli/"]

    static func binaireReconnu(cheminReel: String) -> Bool {
        cheminReel.hasPrefix("/") && installationsAttendues.contains(where: cheminReel.contains)
    }

    static func relever(console: ConsoleBailian,
                        lanceur: LanceurCLI,
                        emplacements: [URL],
                        maintenant: @Sendable () -> Date = { Date() }) async -> ReleveAlibaba {
        let arguments = arguments(console: console)
        for binaire in emplacements {
            let resultat = await lanceur(binaire, arguments)
            if resultat.issue == .introuvable { continue }
            return conclure(resultat, maintenant: maintenant())
        }
        return .absent
    }

    static func conclure(_ resultat: ResultatCLI, maintenant: Date) -> ReleveAlibaba {
        switch resultat.issue {
        case .introuvable:
            return .absent
        case .delaiDepasse:
            Journal.donnees.notice("Alibaba : bl n'a pas répondu dans le délai")
            return .indetermine
        case .refusee:
            Journal.donnees.notice("Alibaba : lancement de bl refusé")
            return .indetermine
        case .terminee(let code):
            guard !resultat.tronquee else {
                Journal.donnees.notice("Alibaba : sortie de bl tronquée")
                return .indetermine
            }
            guard code == 0 else {
                Journal.donnees.notice("Alibaba : bl a terminé avec le code \(code)")
                return .indetermine
            }
            return decoder(resultat.sortie, maintenant: maintenant)
        }
    }

    // MARK: - Analyse pure

    private struct Cles {
        let part: String
        let echeance: String
        let sorte: Fenetre.Sorte
        let libelle: String
    }

    private static var cles: [Cles] {
        [Cles(part: "per5HourPercentage", echeance: "per5HourResetTime",
              sorte: .cinqHeures, libelle: Fenetre.libelleCinqHeures),
         Cles(part: "per1WeekPercentage", echeance: "per1WeekResetTime",
              sorte: .septJours, libelle: Fenetre.libelleSeptJours),
         Cles(part: "per1MonthPercentage", echeance: "per1MonthResetTime",
              sorte: .mois, libelle: Fenetre.libelleMois)]
    }

    /// La console emballe parfois sa réponse dans des chaînes JSON imbriquées.
    private static let profondeurMax = 12

    static func decoder(_ donnees: Data, maintenant: Date) -> ReleveAlibaba {
        guard let brut = try? JSONSerialization.jsonObject(with: donnees),
              brut is [String: Any] else { return .indetermine }
        let arbre = deplier(brut, profondeur: 0)

        if marqueEchec(arbre, profondeur: 0) {
            return demandeConnexion(arbre, profondeur: 0) ? .reconnexionNecessaire : .indetermine
        }
        guard let usage = premierObjet(arbre, profondeur: 0, contenantUneDe: Set(cles.map(\.part))) else {
            return .aucuneFenetre(.aucunePart)
        }

        var fenetres: [Fenetre] = []
        var partLisible = false
        for cle in cles {
            guard let points = rapport(usage[cle.part]).map({ $0 * 100 }) else { continue }
            partLisible = true
            // ⛔ Dotation et échéance, ou rien : une part sans date de recharge ne dit pas
            // quand le compte redevient utilisable.
            guard let echeance = millisecondes(usage[cle.echeance]),
                  let fenetre = Fenetre(libelle: cle.libelle, sorte: cle.sorte,
                                        utilisation: points, seRechargeA: echeance) else { continue }
            fenetres.append(fenetre)
        }
        guard !fenetres.isEmpty else { return .aucuneFenetre(partLisible ? .sansEcheance : .partIllisible) }
        return .releve(MesureAlibaba(quota: Quota(fenetres), mesureA: maintenant))
    }

    /// Un rapport consommé, entre 0 et 1. ⛔ Une valeur hors de ces bornes n'est pas
    /// ramenée dedans : rien ne dit si c'est un pourcentage ou une erreur.
    private static func rapport(_ valeur: Any?) -> Double? {
        guard let nombre = nombre(valeur), (0...1).contains(nombre) else { return nil }
        return nombre
    }

    /// Un epoch en **millisecondes**, seule unité publiée. Une valeur sous 1e11 serait une
    /// date de 1973 : elle n'est pas relue en secondes, elle est écartée.
    private static func millisecondes(_ valeur: Any?) -> Date? {
        guard let nombre = nombre(valeur), nombre >= 1e11 else { return nil }
        return Date(timeIntervalSince1970: nombre / 1000)
    }

    /// Un nombre JSON fini ; jamais un booléen, que `NSNumber` confondrait avec 0 ou 1.
    private static func nombre(_ valeur: Any?) -> Double? {
        guard let nombre = valeur as? NSNumber,
              CFGetTypeID(nombre) != CFBooleanGetTypeID() else { return nil }
        let double = nombre.doubleValue
        return double.isFinite ? double : nil
    }

    private static func deplier(_ valeur: Any, profondeur: Int) -> Any {
        guard profondeur < profondeurMax else { return valeur }
        if let texte = valeur as? String {
            let coupe = texte.trimmingCharacters(in: .whitespacesAndNewlines)
            guard coupe.hasPrefix("{") || coupe.hasPrefix("["),
                  let imbrique = try? JSONSerialization.jsonObject(with: Data(coupe.utf8)) else { return valeur }
            return deplier(imbrique, profondeur: profondeur + 1)
        }
        if let objet = valeur as? [String: Any] {
            return objet.mapValues { deplier($0, profondeur: profondeur + 1) }
        }
        if let tableau = valeur as? [Any] {
            return tableau.map { deplier($0, profondeur: profondeur + 1) }
        }
        return valeur
    }

    /// Parcours en profondeur, clés triées : le même document donne toujours le même objet.
    private static func premierObjet(_ valeur: Any, profondeur: Int,
                                     contenantUneDe cles: Set<String>) -> [String: Any]? {
        guard profondeur < profondeurMax * 2 else { return nil }
        if let objet = valeur as? [String: Any] {
            if !cles.isDisjoint(with: objet.keys) { return objet }
            for (_, enfant) in objet.sorted(by: { $0.key < $1.key }) {
                if let trouve = premierObjet(enfant, profondeur: profondeur + 1, contenantUneDe: cles) {
                    return trouve
                }
            }
        } else if let tableau = valeur as? [Any] {
            for element in tableau {
                if let trouve = premierObjet(element, profondeur: profondeur + 1, contenantUneDe: cles) {
                    return trouve
                }
            }
        }
        return nil
    }

    private static func enfants(_ valeur: Any) -> [Any] {
        if let objet = valeur as? [String: Any] { return Array(objet.values) }
        if let tableau = valeur as? [Any] { return tableau }
        return []
    }

    /// `success` ou `successResponse` à faux, à n'importe quel niveau : la passerelle de la
    /// console peut répondre en succès dehors et en échec dedans.
    private static func marqueEchec(_ valeur: Any, profondeur: Int) -> Bool {
        guard profondeur < profondeurMax * 2 else { return false }
        if let objet = valeur as? [String: Any] {
            for cle in ["success", "successResponse", "Success"] {
                if let drapeau = objet[cle] as? NSNumber,
                   CFGetTypeID(drapeau) == CFBooleanGetTypeID(), !drapeau.boolValue { return true }
            }
        }
        return enfants(valeur).contains { marqueEchec($0, profondeur: profondeur + 1) }
    }

    /// Le code d'erreur de la console pour une session absente.
    static let codesSansSession: Set<String> = ["ConsoleNeedLogin"]

    private static func demandeConnexion(_ valeur: Any, profondeur: Int) -> Bool {
        guard profondeur < profondeurMax * 2 else { return false }
        if let objet = valeur as? [String: Any] {
            for cle in ["code", "errorCode", "Code"] {
                if let code = objet[cle] as? String, codesSansSession.contains(code) { return true }
            }
        }
        return enfants(valeur).contains { demandeConnexion($0, profondeur: profondeur + 1) }
    }
}
