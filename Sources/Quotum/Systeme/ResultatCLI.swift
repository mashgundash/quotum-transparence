import Foundation

/// Ce qu'a rendu une commande d'affichage de quota d'un CLI officiel.
struct ResultatCLI: Sendable, Equatable {
    enum Issue: Sendable, Equatable {
        case terminee(code: Int32)
        case delaiDepasse
        case introuvable
        case refusee
    }

    var issue: Issue
    /// Sortie standard, bornée par le lanceur ; `tronquee` dit qu'elle a été coupée.
    var sortie: Data
    var tronquee: Bool
}

/// Lance un binaire désigné par son chemin absolu, avec des arguments fixes, sans shell.
/// ⛔ Aucune valeur par défaut : un lecteur sous test ne peut pas exécuter le vrai binaire.
typealias LanceurCLI = @Sendable (_ binaire: URL, _ arguments: [String]) async -> ResultatCLI
