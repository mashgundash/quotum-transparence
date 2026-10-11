import Foundation
import Sparkle

/// Les mises à jour de l'application, portées par Sparkle.
///
/// Une seule ligne suffit à tout mettre en route — `MiseAJour.demarrer()` — et elle
/// fait deux choses que rien d'autre ne fait :
///
/// 1. elle remet le LaunchAgent d'accord avec le bundle courant. C'est ici que ça se
///    passe parce que c'est ici qu'on sait que le bundle peut changer de place : une
///    mise à jour le remplace, et le chemin inscrit à l'activation désigne alors une
///    application qui n'existe plus ;
/// 2. elle arme l'updater — mais **seulement** si le bundle porte une adresse de flux
///    exploitable. Sans elle, Sparkle interrompt l'application au démarrage, et une
///    adresse fantaisiste chercherait ses mises à jour dans le vide sans le dire.
@MainActor
enum MiseAJour {
    /// Écrite par `build.sh` dans l'Info.plist, et lue par Sparkle lui-même. Absente
    /// tant que le domaine du produit n'existe pas.
    static let cleFlux = "SUFeedURL"

    static func demarrer() {
        Demarrage.reconcilier()

        guard verificateur == nil,
              adresseDeFlux(Bundle.main.object(forInfoDictionaryKey: cleFlux) as? String) != nil
        else { return }

        verificateur = SPUStandardUpdaterController(startingUpdater: true,
                                                    updaterDelegate: nil,
                                                    userDriverDelegate: rappelsDoux)
    }

    /// Retenu ici : Sparkle ne garde son délégué que faiblement.
    static let rappelsDoux = RappelsDoux(pastille: .partagee)

    /// Faux sans updater armé — copie sans flux —, et pendant que Sparkle télécharge déjà
    /// en arrière-plan. Relu à chaque ouverture du menu, jamais figé à sa construction.
    static var peutVerifier: Bool { verificateur?.peutVerifier ?? false }

    /// La même réponse, suivie : rappelée tout de suite, puis à chaque changement, tant que le
    /// jeton rendu est retenu. Sans updater armé, rien ne changera : un seul rappel, à faux.
    static func suivrePeutVerifier(_ rappel: @escaping @MainActor (Bool) -> Void) -> AnyObject? {
        guard let verificateur else {
            rappel(false)
            return nil
        }
        return verificateur.suivrePeutVerifier(rappel)
    }

    /// La vérification demandée à la main, depuis le menu du clic droit.
    ///
    /// Sparkle ne veut être appelé que lorsqu'il peut vérifier : l'état peut changer entre
    /// l'ouverture du menu, qui a grisé ou non l'élément, et le clic.
    static func verifier() {
        guard let verificateur, verificateur.peutVerifier else { return }
        verificateur.verifier()
    }

    /// L'adresse de flux retenue, ou `nil` si rien d'exploitable n'est inscrit.
    ///
    /// Le filtre est volontairement strict et ferme par défaut : une adresse de flux se
    /// grave dans chaque copie vendue et ne se corrige jamais à distance. `https` est
    /// exigé — la signature EdDSA authentifie la livraison, pas le flux qui l'annonce,
    /// et un flux en clair se détourne.
    static func adresseDeFlux(_ brute: String?) -> URL? {
        guard let brute else { return nil }
        let nettoyee = brute.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nettoyee.isEmpty,
              let adresse = URL(string: nettoyee),
              adresse.scheme?.lowercased() == "https",
              let hote = adresse.host(), !hote.isEmpty
        else { return nil }
        return adresse
    }

    /// Le contrôleur de Sparkle. Relâché, il emporte son updater avec lui : plus rien ne
    /// vérifierait. Posé à la main par les tests seulement.
    static var verificateur: (any VerificateurMisesAJour)?
}

/// Ce que le menu demande à Sparkle : s'il peut vérifier, et de le faire.
@MainActor
protocol VerificateurMisesAJour: AnyObject {
    var peutVerifier: Bool { get }
    func verifier()
    func suivrePeutVerifier(_ rappel: @escaping @MainActor (Bool) -> Void) -> AnyObject
}

extension SPUStandardUpdaterController: VerificateurMisesAJour {
    var peutVerifier: Bool { updater.canCheckForUpdates }

    func verifier() { checkForUpdates(nil) }

    // `canCheckForUpdates` est observable par KVO, selon l'en-tête de Sparkle.
    func suivrePeutVerifier(_ rappel: @escaping @MainActor (Bool) -> Void) -> AnyObject {
        updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { _, changement in
            guard let peut = changement.newValue else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { rappel(peut) } }
        }
    }
}

