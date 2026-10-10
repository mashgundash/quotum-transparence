import Foundation

struct ResultatProcessus: Sendable, Equatable {
    let code: Int32
    let sortie: String
    let erreur: String

    var reussi: Bool { code == 0 }
}

enum ErreurProcessus: Error, Sendable, Equatable {
    case lancementImpossible(executable: String, raison: String)
    case delaiDepasse(TimeInterval)
}

/// Lancement d'un utilitaire système. Point de passage unique : les actions du
/// panneau, le LaunchAgent et tout futur lecteur de `ps` s'appuient dessus plutôt
/// que de réécrire chacun leur `Process`.
enum Processus {
    static let delaiParDefaut: TimeInterval = 15

    /// Les arguments passent par un tableau, jamais par une chaîne confiée à un
    /// shell : un nom de compte ne peut donc pas devenir une commande.
    @discardableResult
    static func executer(_ executable: String,
                         _ arguments: [String] = [],
                         delai: TimeInterval = delaiParDefaut) async throws -> ResultatProcessus {
        let execution = Execution(executable: executable, arguments: arguments)
        try execution.lancer()

        let veilleur = Task {
            try await Task.sleep(for: .seconds(delai))
            execution.interrompre()
        }
        defer { veilleur.cancel() }

        let fin = await execution.attendre()
        if fin.interrompu { throw ErreurProcessus.delaiDepasse(delai) }
        return fin.resultat
    }

    /// Variante synchrone, réservée aux commandes qui rendent quelques lignes et dont
    /// l'appelant ne peut pas être asynchrone — `Demarrage` est piloté depuis un
    /// `onChange` SwiftUI. La sortie n'est lue qu'après la fin du processus : correct
    /// tant qu'elle tient dans les 64 Ko du tube, ce que `launchctl` ne dépasse pas.
    @discardableResult
    static func executerCourt(_ executable: String, _ arguments: [String] = []) -> ResultatProcessus {
        let processus = Process()
        processus.executableURL = URL(fileURLWithPath: executable)
        processus.arguments = arguments
        processus.standardInput = FileHandle.nullDevice
        let tubeSortie = Pipe()
        let tubeErreur = Pipe()
        processus.standardOutput = tubeSortie
        processus.standardError = tubeErreur

        do { try processus.run() } catch {
            return ResultatProcessus(code: -1, sortie: "", erreur: error.localizedDescription)
        }
        let sortie = tubeSortie.fileHandleForReading.readDataToEndOfFile()
        let erreur = tubeErreur.fileHandleForReading.readDataToEndOfFile()
        processus.waitUntilExit()

        return ResultatProcessus(code: processus.terminationStatus,
                                 sortie: Self.texte(sortie),
                                 erreur: Self.texte(erreur))
    }

    static func texte(_ donnees: Data) -> String {
        guard let brut = String(data: donnees, encoding: .utf8) else { return "" }
        return brut.trimmingCharacters(in: .newlines)
    }
}

/// Le gestionnaire de lecture des tubes, celui de fin de processus et la tâche de
/// délai vivent dans trois domaines de concurrence distincts et touchent le même
/// état — d'où le verrou explicite plutôt qu'un acteur, que `Process` ne peut pas
/// franchir.
///
/// Les tubes sont lus *pendant* l'exécution, pas après : `ps -axo command` dépasse
/// couramment les 64 Ko qu'un tube retient — attendre la
/// fin du processus avant de lire le fait dormir pour toujours.
private final class Execution: @unchecked Sendable {
    struct Fin: Sendable {
        let resultat: ResultatProcessus
        let interrompu: Bool
    }

    private let verrou = NSLock()
    private let processus = Process()
    private let tubeSortie = Pipe()
    private let tubeErreur = Pipe()

    private var sortie = Data()
    private var erreur = Data()
    private var code: Int32 = -1
    private var interrompu = false
    /// Sortie close, erreur close, processus terminé.
    private var attendus = 3
    private var reprise: CheckedContinuation<Fin, Never>?

    init(executable: String, arguments: [String]) {
        processus.executableURL = URL(fileURLWithPath: executable)
        processus.arguments = arguments
        processus.standardOutput = tubeSortie
        processus.standardError = tubeErreur
        processus.standardInput = FileHandle.nullDevice
    }

    func lancer() throws {
        tubeSortie.fileHandleForReading.readabilityHandler = { [weak self] poignee in
            self?.accumuler(poignee, versSortie: true)
        }
        tubeErreur.fileHandleForReading.readabilityHandler = { [weak self] poignee in
            self?.accumuler(poignee, versSortie: false)
        }
        processus.terminationHandler = { [weak self] termine in
            self?.enregistrerFin(code: termine.terminationStatus)
        }

        do {
            try processus.run()
        } catch {
            tubeSortie.fileHandleForReading.readabilityHandler = nil
            tubeErreur.fileHandleForReading.readabilityHandler = nil
            processus.terminationHandler = nil
            throw ErreurProcessus.lancementImpossible(
                executable: processus.executableURL?.path ?? executableDemande,
                raison: error.localizedDescription)
        }
    }

    func attendre() async -> Fin {
        await withCheckedContinuation { suite in
            var immediate: Fin?
            verrou.lock()
            if attendus == 0 { immediate = finCourante() } else { reprise = suite }
            verrou.unlock()
            if let immediate { suite.resume(returning: immediate) }
        }
    }

    func interrompre() {
        verrou.lock()
        interrompu = true
        verrou.unlock()
        if processus.isRunning { processus.terminate() }
    }

    private var executableDemande: String { processus.executableURL?.path ?? "?" }

    private func accumuler(_ poignee: FileHandle, versSortie: Bool) {
        let donnees = poignee.availableData
        guard donnees.isEmpty else {
            verrou.lock()
            if versSortie { sortie.append(donnees) } else { erreur.append(donnees) }
            verrou.unlock()
            return
        }
        poignee.readabilityHandler = nil
        franchirEtape {}
    }

    private func enregistrerFin(code: Int32) {
        franchirEtape { self.code = code }
    }

    private func franchirEtape(_ mutation: () -> Void) {
        var aReprendre: (CheckedContinuation<Fin, Never>, Fin)?
        verrou.lock()
        mutation()
        attendus -= 1
        if attendus == 0, let suite = reprise {
            reprise = nil
            aReprendre = (suite, finCourante())
        }
        verrou.unlock()
        if let aReprendre { aReprendre.0.resume(returning: aReprendre.1) }
    }

    /// À n'appeler que le verrou tenu.
    private func finCourante() -> Fin {
        Fin(resultat: ResultatProcessus(code: code,
                                        sortie: Processus.texte(sortie),
                                        erreur: Processus.texte(erreur)),
            interrompu: interrompu)
    }
}
