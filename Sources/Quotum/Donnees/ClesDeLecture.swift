import Foundation
import Security

/// Une source de dépense qu'on suit par une **clé de lecture** : une clé que l'utilisateur crée
/// et colle lui-même, qui lit la dépense et le plafond sans pouvoir générer de tokens.
/// Une par source et par Mac.
enum SourceCleLecture: String, Sendable, CaseIterable {
    case anthropicEntreprise = "anthropic-entreprise"
    case awsBedrock = "aws-bedrock"
    case azureOpenAI = "azure-openai"

    /// Hors de l'espace `fournisseur:souche` de `Fusion` : aucune ligne découverte ne peut le
    /// reprendre, et les réglages d'affichage du compte s'y ancrent.
    var identifiantCompte: String { "cle-lecture:\(rawValue)" }

    init?(identifiantCompte: String) {
        guard let source = Self.allCases.first(where: { $0.identifiantCompte == identifiantCompte }) else { return nil }
        self = source
    }

    /// L'outil dont la ligne rejoint le groupe. `nil` : un nuage, qui n'est pas un outil
    /// installé — il a son propre groupe, après ceux des outils, et aucune tuile.
    var outil: Fournisseur? {
        switch self {
        case .anthropicEntreprise: .claude
        case .awsBedrock, .azureOpenAI: nil
        }
    }

    /// Le `fournisseur` qu'un `Compte` exige. ⛔ Pour un nuage, ce n'est qu'un porteur : le
    /// groupe, le nom, les actions et le texte de la dépense passent par `Compte.groupe` et
    /// `sourceCleLecture`, jamais par lui.
    var porteur: Fournisseur { outil ?? .claude }

    /// Le nom du groupe d'un nuage : des marques, qui ne se traduisent pas.
    var nomGroupe: String {
        switch self {
        case .anthropicEntreprise: Fournisseur.claude.libelle
        case .awsBedrock: "AWS Bedrock"
        case .azureOpenAI: "Azure OpenAI"
        }
    }

    /// Le nom du mécanisme sur la rangée. `nil` : celui de l'outil (« Crédits » chez Claude).
    var nomDepense: String? {
        switch self {
        case .anthropicEntreprise: nil
        case .awsBedrock, .azureOpenAI: Mots.dit("Dépense")
        }
    }
}

/// Ce que le Trousseau a dit d'un élément de clé de lecture.
enum LectureElementCle: Sendable, Equatable {
    case absent
    /// Trousseau verrouillé, accès refusé, élément illisible : rien n'est établi.
    case empeche
    case present(Data)
}

/// Les clés de lecture, chacune dans un élément du Trousseau propre à Quotum : le secret dans
/// la donnée de l'élément, ce qui l'accompagne sans être secret dans `kSecAttrGeneric`.
///
/// ⛔ Jamais dans les préférences, qui se lisent en clair par `defaults read`. Et les trois
/// accès arrivent par paramètre, **sans valeur par défaut** : un test qui oublierait de les
/// fournir ne compile pas, au lieu d'écrire dans le Trousseau de la machine qui le lance.
///
/// Les attributs se lisent sans demander d'autorisation, à la différence de la donnée : la
/// feuille et la ligne du panneau savent qu'une clé existe sans jamais toucher au secret, que
/// seul le moment d'une requête lit.
struct MagasinClesLecture: Sendable {
    static let service = "app.quotum.mac.cle-lecture"

    /// Statut de `SecItemCopyMatching` et, s'il a abouti, l'attribut générique.
    let lireAttribut: @Sendable (_ compte: String) -> (statut: OSStatus, donnees: Data?)
    /// Statut de `SecItemCopyMatching` et, s'il a abouti, la donnée secrète.
    let lireSecret: @Sendable (_ compte: String) -> (statut: OSStatus, donnees: Data?)
    /// Pose ou remplace l'élément entier ; rend le statut final.
    let ecrire: @Sendable (_ compte: String, _ secret: Data, _ attribut: Data) -> OSStatus
    let supprimer: @Sendable (_ compte: String) -> OSStatus

    static let systeme = MagasinClesLecture(
        lireAttribut: { compte in
            var resultat: CFTypeRef?
            let statut = SecItemCopyMatching(requete(compte, [kSecReturnAttributes as String: true]) as CFDictionary,
                                             &resultat)
            return (statut, (resultat as? [String: Any])?[kSecAttrGeneric as String] as? Data)
        },
        lireSecret: { compte in
            var resultat: CFTypeRef?
            let statut = SecItemCopyMatching(requete(compte, [kSecReturnData as String: true]) as CFDictionary,
                                             &resultat)
            return (statut, resultat as? Data)
        },
        ecrire: { compte, secret, attribut in
            var element = cible(compte)
            element[kSecAttrLabel as String] = Mots.dit("Quotum — clé de lecture")
            element[kSecAttrGeneric as String] = attribut
            element[kSecValueData as String] = secret
            let ajout = SecItemAdd(element as CFDictionary, nil)
            guard ajout == errSecDuplicateItem else { return ajout }
            let modifications: [String: Any] = [kSecAttrGeneric as String: attribut,
                                                kSecValueData as String: secret]
            return SecItemUpdate(cible(compte) as CFDictionary, modifications as CFDictionary)
        },
        supprimer: { compte in
            SecItemDelete(cible(compte) as CFDictionary)
        })

    private static func cible(_ compte: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: compte]
    }

    private static func requete(_ compte: String, _ retour: [String: Any]) -> [String: Any] {
        cible(compte).merging([kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }.merging(retour) { $1 }
    }

    static func classer(_ lecture: (statut: OSStatus, donnees: Data?)) -> LectureElementCle {
        switch lecture.statut {
        case errSecSuccess: lecture.donnees.map { .present($0) } ?? .empeche
        case errSecItemNotFound: .absent
        default: .empeche
        }
    }

    func attribut(_ source: SourceCleLecture) async -> LectureElementCle {
        let lire = lireAttribut
        return await HorsFil.executer { Self.classer(lire(source.rawValue)) }
    }

    func secret(_ source: SourceCleLecture) async -> LectureElementCle {
        let lire = lireSecret
        return await HorsFil.executer { Self.classer(lire(source.rawValue)) }
    }

    func enregistrer(_ source: SourceCleLecture, secret: Data, attribut: Data) async -> Bool {
        let ecrire = self.ecrire
        return await HorsFil.executer { ecrire(source.rawValue, secret, attribut) == errSecSuccess }
    }

    /// Un élément déjà absent est un retrait réussi : c'est l'état voulu.
    func retirer(_ source: SourceCleLecture) async -> Bool {
        let supprimer = self.supprimer
        return await HorsFil.executer {
            let statut = supprimer(source.rawValue)
            return statut == errSecSuccess || statut == errSecItemNotFound
        }
    }
}
