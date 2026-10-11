import Foundation
import Security

/// Un outil qu'on suit par une clé d'API que l'utilisateur colle lui-même. Une clé par outil et
/// par Mac ; la valeur brute est le compte de l'élément du Trousseau.
enum OutilCle: String, Sendable, CaseIterable {
    case zai
    case minimax

    /// Des marques, qui ne se traduisent pas.
    var nom: String {
        switch self {
        case .zai: "Z.ai"
        case .minimax: "MiniMax"
        }
    }
}

/// La région du compte, qui désigne l'hôte qui reçoit la clé. ⛔ Liste fermée : une valeur
/// inconnue n'envoie rien plutôt que de composer un hôte.
enum RegionCleOutil: String, Sendable, Codable, CaseIterable {
    case internationale
    case chine
}

/// Ce que la saisie a de faux. La clé n'y figure jamais.
enum RefusCleOutil: Error, Sendable, Equatable {
    case vide
    case longueur
    /// Hors de l'ASCII imprimable, ou une espace au milieu : la clé part dans un en-tête, où un
    /// caractère de contrôle ouvrirait un second en-tête.
    case caracteres
}

/// Une clé collée qui a passé la garde. ⛔ Sa description ne montre jamais la valeur : une
/// interpolation dans un journal n'en écrit rien.
struct CleOutil: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    static let longueurMinimale = 20
    static let longueurMaximale = 512

    let valeur: String

    private init(valeur: String) { self.valeur = valeur }

    var description: String { "clé masquée" }
    var debugDescription: String { description }

    /// Les blancs qui entourent un collage se retirent ; tout le reste se refuse, rien ne se
    /// corrige en silence.
    static func valider(_ brute: String) -> Result<CleOutil, RefusCleOutil> {
        let cle = brute.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cle.isEmpty else { return .failure(.vide) }
        guard cle.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            return .failure(.caracteres)
        }
        guard (longueurMinimale...longueurMaximale).contains(cle.utf8.count) else { return .failure(.longueur) }
        return .success(CleOutil(valeur: cle))
    }
}

/// Ce qui accompagne la clé au Trousseau, sans être secret : la région, et la génération tirée
/// à chaque enregistrement — c'est elle qui dit qu'une réponse a été demandée avec la clé
/// encore en place.
struct AttributCleOutil: Codable, Sendable, Equatable {
    static let versionCourante = 1

    let version: Int
    let region: RegionCleOutil
    let generation: UUID

    init(region: RegionCleOutil, generation: UUID) {
        version = Self.versionCourante
        self.region = region
        self.generation = generation
    }

    func encoder() -> Data? {
        let encodeur = JSONEncoder()
        encodeur.outputFormatting = .sortedKeys
        return try? encodeur.encode(self)
    }

    /// ⛔ Un attribut retouché — autre version, région hors de la liste — ne fait pas
    /// d'enregistrement : la région finirait par choisir l'hôte d'une requête.
    static func decoder(_ donnees: Data) -> AttributCleOutil? {
        guard let lu = try? JSONDecoder().decode(AttributCleOutil.self, from: donnees),
              lu.version == versionCourante else { return nil }
        return lu
    }
}

/// Ce que le Trousseau a dit d'une clé d'outil.
enum LectureCleOutil<Valeur: Sendable & Equatable>: Sendable, Equatable {
    case absente
    /// Trousseau verrouillé, accès refusé, contenu qui ne passe plus la garde : rien n'est établi.
    case empechee
    case presente(Valeur)
}

/// Les clés collées de Z.ai et MiniMax, chacune dans un élément du Trousseau propre à Quotum :
/// le secret dans la donnée de l'élément, la région et la génération dans `kSecAttrGeneric`,
/// qui se lit sans demander d'autorisation.
///
/// ⛔ Jamais dans les préférences, qui se lisent en clair par `defaults read`. Les quatre accès
/// arrivent par paramètre, **sans valeur par défaut** : un test qui oublierait de les fournir ne
/// compile pas, au lieu d'écrire dans le Trousseau de la machine qui le lance.
struct MagasinClesOutil: Sendable {
    static let service = "app.quotum.mac.cle-outil"

    /// Statut de `SecItemCopyMatching` et, s'il a abouti, l'attribut générique.
    let lireAttribut: @Sendable (_ compte: String) -> (statut: OSStatus, donnees: Data?)
    /// Statut de `SecItemCopyMatching` et, s'il a abouti, la donnée secrète.
    let lireSecret: @Sendable (_ compte: String) -> (statut: OSStatus, donnees: Data?)
    /// Pose ou remplace l'élément entier ; rend le statut final.
    let ecrire: @Sendable (_ compte: String, _ libelle: String, _ secret: Data, _ attribut: Data) -> OSStatus
    let supprimer: @Sendable (_ compte: String) -> OSStatus

    static let systeme = MagasinClesOutil(
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
        ecrire: { compte, libelle, secret, attribut in
            var element = cible(compte)
            element[kSecAttrLabel as String] = libelle
            element[kSecAttrGeneric as String] = attribut
            element[kSecValueData as String] = secret
            let ajout = SecItemAdd(element as CFDictionary, nil)
            guard ajout == errSecDuplicateItem else { return ajout }
            let modifications: [String: Any] = [kSecAttrLabel as String: libelle,
                                                kSecAttrGeneric as String: attribut,
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

    static func libelle(_ outil: OutilCle) -> String {
        Mots.dit("Quotum — clé %1$@", outil.nom)
    }

    static func classerAttribut(_ lecture: (statut: OSStatus, donnees: Data?)) -> LectureCleOutil<AttributCleOutil> {
        switch lecture.statut {
        case errSecSuccess:
            guard let donnees = lecture.donnees, let attribut = AttributCleOutil.decoder(donnees) else {
                Journal.donnees.notice("Clé d'outil : attribut illisible ou hors liste")
                return .empechee
            }
            return .presente(attribut)
        case errSecItemNotFound: return .absente
        default: return .empechee
        }
    }

    /// La clé relue repasse la garde de la saisie : un élément retouché hors de Quotum ne
    /// glisse pas un retour à la ligne dans l'en-tête d'une requête.
    static func classerSecret(_ lecture: (statut: OSStatus, donnees: Data?)) -> LectureCleOutil<CleOutil> {
        switch lecture.statut {
        case errSecSuccess:
            guard let donnees = lecture.donnees,
                  let texte = String(data: donnees, encoding: .utf8),
                  case .success(let cle) = CleOutil.valider(texte),
                  cle.valeur == texte else {
                Journal.donnees.notice("Clé d'outil : secret illisible ou mal formé")
                return .empechee
            }
            return .presente(cle)
        case errSecItemNotFound: return .absente
        default: return .empechee
        }
    }

    func attribut(_ outil: OutilCle) async -> LectureCleOutil<AttributCleOutil> {
        let lire = lireAttribut
        return await HorsFil.executer { Self.classerAttribut(lire(outil.rawValue)) }
    }

    /// `autorise` se relit dans le travail même, juste avant l'accès au Trousseau : une révocation
    /// faite pendant que le travail attendait sa file ne laisse pas lire le secret. `nil` : rien n'a
    /// été lu.
    func secret(_ outil: OutilCle, si autorise: @escaping @Sendable () -> Bool) async -> LectureCleOutil<CleOutil>? {
        let lire = lireSecret
        return await HorsFil.executer {
            guard autorise() else { return nil }
            return Self.classerSecret(lire(outil.rawValue))
        }
    }

    /// Une génération neuve à chaque enregistrement, rendue quand l'élément est en place ;
    /// `nil` si le Trousseau a refusé.
    func enregistrer(_ outil: OutilCle, cle: CleOutil, region: RegionCleOutil) async -> UUID? {
        let attribut = AttributCleOutil(region: region, generation: UUID())
        guard let donnees = attribut.encoder() else { return nil }
        let ecrire = self.ecrire
        let libelle = Self.libelle(outil)
        let statut = await HorsFil.executer { ecrire(outil.rawValue, libelle, Data(cle.valeur.utf8), donnees) }
        return statut == errSecSuccess ? attribut.generation : nil
    }

    /// Un élément déjà absent est un retrait réussi : c'est l'état voulu.
    func retirer(_ outil: OutilCle) async -> Bool {
        let supprimer = self.supprimer
        return await HorsFil.executer {
            let statut = supprimer(outil.rawValue)
            return statut == errSecSuccess || statut == errSecItemNotFound
        }
    }
}
