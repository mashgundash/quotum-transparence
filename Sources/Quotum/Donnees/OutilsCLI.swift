import Foundation

/// Le branchement réel des quatre outils mesurés par leur CLI officiel — Antigravity
/// (`agy`), Doubao (`arkcli`), Alibaba Model Studio (`bl`) et Amp (`amp`).
///
/// ⛔ **Un seul lanceur pour les quatre** (`lanceur`), une seule liste de racines et une seule
/// liste de `node` : chaque lecteur ne fait que désigner son binaire. Ce qui est lancé l'est en
/// lecture seule — la commande d'affichage du quota, avec des arguments fixes — et jamais
/// trouvé par le `PATH` : seuls les emplacements fermés que chaque lecteur déclare sont essayés.
enum OutilsCLI {
    /// Sous quelles racines un binaire, ou le `node` d'un script npm, peut vivre une fois ses
    /// liens résolus : l'installeur natif (`~/.local`), celui d'Amp (`~/.amp`), Homebrew sur
    /// Apple Silicon (`/opt/homebrew`) et sur Intel, comme le paquet Node officiel (`/usr/local`).
    static func racines(accueil: URL) -> [URL] {
        [accueil.appendingPathComponent(".local", isDirectory: true),
         accueil.appendingPathComponent(".amp", isDirectory: true),
         URL(fileURLWithPath: "/opt/homebrew", isDirectory: true),
         URL(fileURLWithPath: "/usr/local", isDirectory: true)]
    }

    /// Les `node` qu'un script `#!/usr/bin/env node` peut recevoir, dans cet ordre : Homebrew
    /// (Apple Silicon puis Intel, qui est aussi le préfixe du paquet officiel de nodejs.org),
    /// puis une installation dans `~/.local`. ⚠️ Ni nvm ni Volta : leurs chemins dépendent d'une
    /// version ou d'un relais qu'aucune liste fermée ne fixe.
    static func interpretesNode(accueil: URL) -> [URL] {
        [URL(fileURLWithPath: "/opt/homebrew/bin/node"),
         URL(fileURLWithPath: "/usr/local/bin/node"),
         accueil.appendingPathComponent(".local/bin/node")]
    }

    static func lanceur(accueil: URL) -> LanceurCLISysteme {
        LanceurCLISysteme(racinesAutorisees: racines(accueil: accueil),
                          interpretesNode: interpretesNode(accueil: accueil))
    }

    // MARK: - Les quatre relevés réels

    private static var accueil: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func releverAntigravity() async -> ReleveAntigravity {
        let accueil = accueil
        let binaire = await HorsFil.executer { QuotaAntigravity.localiser(home: accueil) }
        return await QuotaAntigravity.relever(binaire: binaire, lanceur: lanceur(accueil: accueil).lanceur)
    }

    static func releverDoubao() async -> ReleveDoubao {
        await QuotaDoubao.relever(lanceur: lanceur(accueil: accueil)
                                    .lanceur(reconnaissant: QuotaDoubao.binaireReconnu(cheminReel:)),
                                  emplacements: QuotaDoubao.emplacements(accueil: accueil))
    }

    /// Le Token Plan international et celui de Chine continentale sont deux comptes, servis par
    /// deux consoles. L'international d'abord ; la console chinoise n'est interrogée que si le
    /// premier n'a rien mesuré, et sa réponse ne remplace la première que si elle mesure.
    static func releverAlibaba() async -> ReleveAlibaba {
        let lanceur = lanceur(accueil: accueil).lanceur(reconnaissant: QuotaAlibaba.binaireReconnu(cheminReel:))
        let emplacements = QuotaAlibaba.emplacements(accueil: accueil)
        let international = await QuotaAlibaba.relever(console: .internationale, lanceur: lanceur,
                                                       emplacements: emplacements)
        switch international {
        case .releve, .absent:
            return international
        case .aucuneFenetre, .reconnexionNecessaire, .indetermine:
            let chine = await QuotaAlibaba.relever(console: .chine, lanceur: lanceur, emplacements: emplacements)
            if case .releve = chine { return chine }
            return international
        }
    }

    static func releverAmp() async -> ReleveAmp {
        let accueil = accueil
        let racines = racines(accueil: accueil).compactMap { LanceurCLISysteme.cheminReel($0.path) }
        return await QuotaAmp.relever(maison: accueil,
                                      estExecutable: { url in
                                          if case .valide = LanceurCLISysteme.verifier(url, racines: racines) {
                                              return true
                                          }
                                          return false
                                      },
                                      lanceur: lanceur(accueil: accueil).lanceur)
    }
}
