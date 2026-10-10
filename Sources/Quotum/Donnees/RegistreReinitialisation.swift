import Foundation
import Observation

/// Qui a le droit de dépenser une réinitialisation, sur quel compte, à cet instant.
///
/// ⛔ Cette garde ne peut pas vivre dans une vue. Le popover reconstruit tout son contenu
/// à chaque ouverture : la conduite qui tenait la garde est abandonnée alors que sa tâche
/// reste en vol, et la conduite neuve repart de zéro. Deux confirmations, deux appels,
/// deux crédits — et un crédit dépensé est perdu. Le registre, lui, survit aux vues, et c'est
/// tout ce qu'on lui demande. Le tiroir du panneau et le mode automatique partagent le
/// même : sans quoi l'un doublerait l'autre.
///
/// Trois mémoires, qui ne durent pas autant :
/// - **en vol**, en mémoire seulement : une demande ne survit pas à l'app qui l'a émise ;
/// - **consignations**, sur disque, écrites **avant** l'envoi par `acquerir`, sous un
///   verrou de fichier : une demande en vol quand l'app quitte laisse sa trace, et une
///   seconde instance de l'app — deux copies installées — relit cette trace avant la
///   sienne au lieu de se fier à ce qu'elle avait chargé au lancement ;
/// - **annonces**, sur disque aussi, dans une file à part : ce que le mode automatique
///   doit encore dire. ⛔ Une consignation se remplace à l'épisode suivant et se purge au
///   bout d'un mois ; une annonce rangée dedans disparaissait avec elle, sans avoir été
///   faite. La file, elle, ne perd une annonce qu'une fois la notification prise.
///
/// `init(fichier: nil)` reste accessible plutôt que d'imposer le singleton : les suites
/// Swift Testing s'exécutent en parallèle, et un registre commun ferait qu'un test en
/// bloque un autre.
///
/// Observable pour `panne` et les demandes en vol : une écriture qui échoue pendant que les
/// réglages ou le tiroir sont ouverts doit s'y voir sans attendre qu'ils se reconstruisent.
@MainActor
@Observable
final class RegistreReinitialisation {
    static let partage = RegistreReinitialisation(fichier: fichierParDefaut)

    /// Au-delà, une consignation ne protège plus rien : son échéance est passée depuis
    /// longtemps, et un épisode neuf en porte forcément une autre.
    static let conservation: TimeInterval = 30 * 24 * 3600

    /// ⛔ Après une demande, le compte reste fermé ce temps-là, quelle que soit
    /// l'échéance. C'est ce qui couvre une réponse perdue, un relevé qui ne publie pas
    /// d'échéance, et le geste repris avant que le relevé suivant ait vu le quota rouvert.
    /// Une réinitialisation rouvre une fenêtre de plusieurs heures : la resaturer en une
    /// demi-heure n'arrive pas, et le prix d'un refus à tort est une attente.
    static let delaiDeGrace: TimeInterval = 30 * 60

    /// La marge couvre l'arrondi à la seconde du fichier : relue après un relancement,
    /// l'échéance d'un même épisode ne doit pas passer pour plus récente. Deux épisodes
    /// réels sont séparés par la durée d'une fenêtre, pas par une minute.
    nonisolated static let margeEcheance: TimeInterval = 60

    /// Ce que la lecture admet. Un registre plus gros ne se relirait plus, et désarmerait tout.
    static let tailleMaximale = 1 << 20

    /// ⛔ Une dépense n'est consignée que si le fichier reste sous la moitié de ce que la
    /// lecture admet. Aucune annonce ne se retire pour faire de la place, et chacune peut
    /// encore recevoir son issue, qui pèse moins qu'elle : la moitié restante les absorbe
    /// toutes.
    static let tailleAdmiseALaDepense = tailleMaximale / 2

    /// Un nom d'affichage, pas un texte : au-delà, il ne ferait que grossir le registre.
    static let longueurNom = 200

    static var fichierParDefaut: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Quotum", isDirectory: true)
            .appendingPathComponent("reinitialisations.json")
    }

    /// L'identité d'un compte pour le registre : l'`account_id` d'OpenAI, jamais
    /// l'identifiant de présentation d'une rangée. Deux rangées successives peuvent
    /// désigner le même compte ; elles doivent partager la même réservation.
    nonisolated static func cle(compte: String) -> String {
        "chatgpt:" + compte.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Celle d'une rangée : le compte mesuré d'abord, le compte déclaré ensuite, la
    /// rangée elle-même faute de mieux.
    nonisolated static func cle(pour ligne: Ligne) -> String {
        guard let compte = compteDe(ligne) else { return "ligne:" + ligne.id }
        return cle(compte: compte)
    }

    nonisolated static func compteDe(_ ligne: Ligne) -> String? {
        [ligne.etat.epuisementReleve?.compte, ligne.compte.organisationIdentifiant]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    enum Acquisition: Equatable {
        /// La trace est sur disque : l'envoi peut partir.
        case acquise(Consigne)
        /// Une demande est déjà partie sur cet épisode, ici ou dans une autre instance.
        case dejaTraitee
        /// La trace n'a pas pu s'écrire, ou le registre n'est plus lisible : rien ne part.
        case impossible
    }

    struct Consigne: Codable, Equatable, Sendable {
        var retour: Date?
        var consigneA: Date
    }

    /// Une dépense du mode automatique qui reste à dire.
    struct Annonce: Codable, Equatable, Sendable {
        /// L'identifiant de la demande envoyée, qui est aussi celui de sa notification.
        var operation: String
        var cle: String
        /// Le nom sous lequel la rangée s'affichait au déclenchement : au relancement, il n'y
        /// a pas encore de rangée pour le dire, et une notification sans nom ne dit pas quel
        /// compteur aller vérifier.
        var nom: String
        /// Ce que la demande a donné, une fois connu. Absente, l'app a quitté pendant
        /// l'envoi : la demande est peut-être partie, et on ne sait pas ce qu'elle a donné.
        var issue: IssueReinitialisation?
        /// L'heure de la consignation, posée par `acquerir`. Une annonce plus jeune que la
        /// durée d'une demande peut encore être entre les mains de la copie de l'app qui
        /// l'a écrite : une autre ne doit pas la dire interrompue.
        var inscriteA: Date?
    }

    /// Pourquoi le registre ne prouve plus rien, et le fichier en cause : le remède n'est
    /// pas le même, et un conseil commun ferait retirer un journal intact.
    enum Panne: Equatable, Sendable {
        /// Le fichier est là mais ne se relit pas : le réparer, ou le retirer en perdant
        /// ses traces.
        case contenuIllisible(URL)
        /// Le système a refusé de lire ou d'écrire — droits, espace disque, dossier occupé.
        /// Le journal peut être intact.
        case accesRefuse(URL)
        /// Le fichier de verrou ne s'ouvre pas, ou ne prend aucun verrou. Il ne contient rien.
        case verrouInaccessible(URL)

        var fichier: URL {
            switch self {
            case .contenuIllisible(let url), .accesRefuse(let url), .verrouInaccessible(let url): url
            }
        }
    }

    enum ReleveAnnonces: Equatable {
        case lues([Annonce])
        /// Une autre instance tient le verrou : rien n'est établi, il faut relire plus tard.
        case verrouTenu
        /// Le registre ne se lit plus : sa panne se signale dans les réglages et le tiroir.
        case inutilisable
    }

    enum Ecriture: Equatable {
        case faite
        /// Une autre instance a gardé le verrou tout le temps des reprises : rien n'est
        /// écrit, il faut réessayer plus tard.
        case verrouTenu
        /// Le registre est en panne : rien ne s'y écrira plus avant le prochain lancement.
        case inutilisable
    }

    private var enVol: Set<String> = []
    @ObservationIgnored private var consignes: [String: Consigne] = [:]
    @ObservationIgnored private var annonces: [Annonce] = []
    private let fichier: URL?
    var emplacement: URL? { fichier }
    /// ⛔ Posée dès qu'une lecture ou une écriture du fichier a échoué. Plus rien ne se
    /// dépense jusqu'au prochain lancement : on ne saurait plus prouver qu'on n'a pas
    /// déjà dépensé sur l'épisode. La première panne reste : c'est elle qui a tout arrêté.
    private(set) var panne: Panne?
    var fiable: Bool { panne == nil }
    /// Une demande a été réservée et n'est pas revenue. Si elle a passé sa dernière garde,
    /// elle est partie, et une panne survenue depuis ne la rappelle pas.
    var demandeEnCours: Bool { !enVol.isEmpty }
    /// La pause entre deux tentatives sur un verrou tenu ailleurs. Injectable pour qu'un test
    /// constate la contention sans dépendre de l'horloge ni d'un fil principal libre.
    private let patienter: @MainActor () async -> Void

    init(fichier: URL? = nil, maintenant: Date = .now,
         patienter: @escaping @MainActor () async -> Void = { try? await Task.sleep(for: .milliseconds(10)) }) {
        self.fichier = fichier
        self.patienter = patienter
        guard let fichier, let lu = lire(fichier) else { return }
        consignes = Self.purger(lu.consignes, maintenant: maintenant)
        annonces = lu.annonces
    }

    /// Rend `false` quand une demande est déjà partie pour ce compte — l'appelant
    /// n'envoie alors rien.
    @discardableResult
    func reserver(_ cle: String) -> Bool {
        guard !enVol.contains(cle) else { return false }
        enVol.insert(cle)
        return true
    }

    func liberer(_ cle: String) {
        enVol.remove(cle)
    }

    func estEnVol(_ cle: String) -> Bool {
        enVol.contains(cle)
    }

    /// Une demande est déjà partie sur cet épisode, sur un plus récent, ou depuis moins
    /// que le délai de grâce. Une échéance plus ancienne vient d'une mesure en retard,
    /// pas d'un épisode neuf.
    func dejaTraite(_ cle: String, retour: Date?, maintenant: Date = .now) -> Bool {
        guard let consigne = consignes[cle] else { return false }
        return Self.couvre(consigne, retour: retour, maintenant: maintenant)
    }

    private static func couvre(_ consigne: Consigne, retour: Date?, maintenant: Date) -> Bool {
        // Une consignation datée du futur — horloge reculée depuis — ferme aussi.
        if maintenant.timeIntervalSince(consigne.consigneA) < delaiDeGrace { return true }
        guard let retour, let traite = consigne.retour else { return false }
        return retour <= traite.addingTimeInterval(margeEcheance)
    }

    /// ⛔ À appeler **avant** l'envoi, par les deux chemins. Sous verrou, le fichier est
    /// relu puis réécrit : la vérification et la trace sont un seul geste, pour cette
    /// instance comme pour une autre.
    ///
    /// `annonce` : ce que le mode automatique devra dire de cette dépense. Elle entre dans
    /// la file par la même écriture que la consignation — le geste manuel, lui, a quelqu'un
    /// devant l'écran.
    func acquerir(_ cle: String, retour: Date?, maintenant: Date = .now,
                  annonce: Annonce? = nil) async -> Acquisition {
        // À la seconde, comme le fichier les rend : `annuler` compare par égalité ce qu'il
        // a posé à ce qu'il relit.
        let consigne = Consigne(retour: retour.map(Self.seconde), consigneA: Self.seconde(maintenant))
        let resultat = await transactionReprise { consignes, annonces -> Acquisition in
            if let existante = consignes[cle], Self.couvre(existante, retour: retour, maintenant: maintenant) {
                return .dejaTraitee
            }
            var suivantes = Self.purger(consignes, maintenant: maintenant)
            suivantes[cle] = consigne
            var file = annonces
            if var annonce {
                annonce.nom = Self.borner(annonce.nom)
                annonce.inscriteA = consigne.consigneA
                file.append(annonce)
            }
            guard let taille = try? Self.encoder(suivantes, file).count,
                  taille <= Self.tailleAdmiseALaDepense else {
                Journal.donnees.error("Réinitialisation : registre trop volumineux, dépense refusée")
                return .impossible
            }
            (consignes, annonces) = (suivantes, file)
            return .acquise(consigne)
        }
        guard case .faite(let acquisition) = resultat else { return .impossible }
        return acquisition
    }

    /// Retire une consignation quand il est **établi** que rien n'est parti — jeton d'un
    /// autre compte, session absente, conditions tombées avant l'envoi. Sans quoi l'épisode
    /// resterait condamné alors qu'aucun crédit n'a été dépensé.
    ///
    /// Ne retire que la consignation posée par cette demande-là : si une autre l'a
    /// remplacée entre-temps, elle reste.
    func annuler(_ cle: String, _ consigne: Consigne) async {
        _ = await transactionReprise { consignes, _ in
            if consignes[cle] == consigne { consignes.removeValue(forKey: cle) }
        }
    }

    /// Ce qu'une demande automatique a donné, écrit avant de le notifier : une app qui
    /// quitte ensuite redira l'issue au relancement, et non une dépense « peut-être » faite.
    ///
    /// Une seule écriture pour deux choses qui ne durent pas autant : la consignation est
    /// levée quand rien n'est parti — l'épisode n'est pas condamné —, l'annonce reste
    /// jusqu'à ce que la notification soit prise. `.abandonnee` n'a rien à dire : son
    /// annonce part avec.
    @discardableResult
    func conclure(_ operation: String, issue: IssueReinitialisation, cle: String,
                  consigne: Consigne) async -> Ecriture {
        let resultat = await transactionReprise { consignes, annonces in
            if issue.rienNEstParti, consignes[cle] == consigne { consignes.removeValue(forKey: cle) }
            guard let rang = annonces.firstIndex(where: { $0.operation == operation }) else { return }
            if issue == .abandonnee {
                annonces.remove(at: rang)
            } else {
                annonces[rang].issue = issue
            }
        }
        return Self.ecriture(resultat)
    }

    /// Retire l'annonce une fois la notification prise par le système. La consignation,
    /// elle, reste : c'est elle qui ferme l'épisode.
    @discardableResult
    func solder(_ operation: String) async -> Ecriture {
        Self.ecriture(await transactionReprise { _, annonces in annonces.removeAll { $0.operation == operation } })
    }

    /// Les annonces qui restent à faire, relues sur le disque, dans l'ordre où elles sont
    /// entrées dans la file. ⚠️ Un verrou tenu ailleurs n'est pas une file vide : il dit
    /// seulement qu'on n'a pas pu la lire.
    func annoncesEnAttente() async -> ReleveAnnonces {
        switch await transactionReprise({ _, annonces in annonces }) {
        case .faite(let lues): .lues(lues)
        case .verrouTenu: .verrouTenu
        case .impossible: .inutilisable
        }
    }

    private static func ecriture<T>(_ transaction: Transaction<T>) -> Ecriture {
        switch transaction {
        case .faite: .faite
        case .verrouTenu: .verrouTenu
        case .impossible: .inutilisable
        }
    }

    private static func seconde(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// Compté en scalaires, pas en caractères : un seul caractère peut en porter des milliers.
    private static func borner(_ nom: String) -> String {
        var borne = String.UnicodeScalarView()
        borne.append(contentsOf: nom.unicodeScalars.prefix(longueurNom))
        return String(borne)
    }

    /// Les annonces n'y passent jamais : une consignation d'un mois peut porter une dépense
    /// qu'on n'a pas encore réussi à dire.
    private static func purger(_ lues: [String: Consigne], maintenant: Date) -> [String: Consigne] {
        lues.filter { maintenant.timeIntervalSince($0.value.retour ?? $0.value.consigneA) < conservation }
    }

    private enum Transaction<T> {
        case faite(T)
        case verrouTenu
        case impossible
    }

    /// Sous verrou : relit le disque, applique `changer`, réécrit si quelque chose a changé.
    /// Une seule tentative, qui rend la contention aussitôt.
    /// ⛔ Un registre en panne ne se touche plus : ce qui le rend illisible est peut-être la
    /// seule trace d'une dépense, et le réécrire l'effacerait.
    private func transaction<T>(_ changer: (inout [String: Consigne], inout [Annonce]) -> T)
        -> Transaction<T> {
        guard fiable else { return .impossible }
        guard let fichier else {
            let resultat = changer(&consignes, &annonces)
            return .faite(resultat)
        }
        return sousVerrou(fichier) { () -> Transaction<T> in
            guard let lu = lire(fichier) else { return .impossible }
            var (suivantes, file) = (lu.consignes, lu.annonces)
            let resultat = changer(&suivantes, &file)
            if suivantes != lu.consignes || file != lu.annonces {
                guard ecrire(suivantes, file, dans: fichier) else { return .impossible }
            }
            (consignes, annonces) = (suivantes, file)
            return .faite(resultat)
        }
    }

    /// L'autre instance ne tient le verrou que le temps d'une lecture et d'une écriture : on
    /// réessaie une seconde durant. ⛔ L'attente est une suspension, jamais un sommeil — tout
    /// ceci tourne sur le fil principal, qui dessine le panneau.
    private func transactionReprise<T>(_ changer: (inout [String: Consigne], inout [Annonce]) -> T)
        async -> Transaction<T> {
        var essais = 1
        while true {
            let resultat = transaction(changer)
            guard case .verrouTenu = resultat, essais < 100 else { return resultat }
            essais += 1
            await patienter()
        }
    }

    /// Le fichier. Sans annonce en attente, il garde la forme d'avant la file — un simple
    /// dictionnaire des consignations.
    private struct Contenu: Codable {
        var consignes: [String: Consigne]
        var annonces: [Annonce]
    }

    /// `nil` : fichier présent mais illisible, refusé par le système, ou pas un fichier
    /// ordinaire — la panne est posée. L'absence, elle, est un premier lancement.
    private func lire(_ fichier: URL) -> (consignes: [String: Consigne], annonces: [Annonce])? {
        let donnees: Data
        do {
            donnees = try LectureFichier.lire(fichier, tailleMaximale: Self.tailleMaximale)
        } catch {
            switch error {
            case .absent:
                return ([:], [])
            case .systeme(let code):
                Journal.donnees.error("Réinitialisation : registre inaccessible (errno \(code))")
                signaler(.accesRefuse(fichier))
            case .pasUnFichierOrdinaire, .tropGrand:
                Journal.donnees.error("Réinitialisation : registre illisible (\(String(describing: error)))")
                signaler(.contenuIllisible(fichier))
            }
            return nil
        }
        do {
            return try Self.decoder(donnees)
        } catch {
            Journal.donnees.error("Réinitialisation : registre illisible (\(String(describing: error)))")
            signaler(.contenuIllisible(fichier))
            return nil
        }
    }

    private static func decoder(_ donnees: Data) throws -> (consignes: [String: Consigne], annonces: [Annonce]) {
        let decodeur = JSONDecoder.registre
        if let contenu = try? decodeur.decode(Contenu.self, from: donnees) {
            return (contenu.consignes, contenu.annonces)
        }
        return (try decodeur.decode([String: Consigne].self, from: donnees), [])
    }

    private static func encoder(_ suivantes: [String: Consigne], _ file: [Annonce]) throws -> Data {
        file.isEmpty
            ? try JSONEncoder.registre.encode(suivantes)
            : try JSONEncoder.registre.encode(Contenu(consignes: suivantes, annonces: file))
    }

    private func ecrire(_ suivantes: [String: Consigne], _ file: [Annonce], dans fichier: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: fichier.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Self.encoder(suivantes, file).write(to: fichier, options: .atomic)
            return true
        } catch {
            Journal.donnees.error("Réinitialisation : consignation impossible (\(error))")
            signaler(.accesRefuse(fichier))
            return false
        }
    }

    private func signaler(_ nouvelle: Panne) {
        if panne == nil { panne = nouvelle }
    }

    /// Le verrou est un fichier voisin, jamais le registre lui-même : l'écriture atomique
    /// remplace le registre par un autre inode, qui ne porterait plus le verrou.
    private func sousVerrou<T>(_ fichier: URL, _ travail: () -> Transaction<T>) -> Transaction<T> {
        let chemin = fichier.appendingPathExtension("verrou")
        let dossier = chemin.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        } catch {
            Journal.donnees.error("Réinitialisation : dossier du registre impossible (\(error))")
            signaler(.accesRefuse(dossier))
            return .impossible
        }
        switch Self.prendreVerrou(chemin) {
        case .pris(let descripteur):
            defer {
                flock(descripteur, LOCK_UN)
                close(descripteur)
            }
            return travail()
        case .tenuAilleurs:
            return .verrouTenu
        case .panne(let panne):
            signaler(panne)
            return .impossible
        }
    }

    enum PriseVerrou: Equatable {
        /// Le verrou est posé sur ce descripteur, à lâcher puis fermer.
        case pris(Int32)
        case tenuAilleurs
        case panne(Panne)
    }

    /// Une seule tentative, qui ne bloque jamais.
    ///
    /// ⛔ Seul `EWOULDBLOCK` dit qu'une autre copie tient le verrou. Toute autre erreur — un
    /// système de fichiers sans verrou, un tube nommé à la place du fichier — ne se lèvera
    /// pas en attendant : la prendre pour une contention ferait reprendre sans fin, sans
    /// que rien ne le dise.
    nonisolated static func prendreVerrou(_ chemin: URL,
                                          poser: (Int32, Int32) -> Int32 = flock) -> PriseVerrou {
        // Non bloquant : un tube nommé posé là figerait l'ouverture elle-même.
        let descripteur = open(chemin.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descripteur >= 0 else {
            let code = errno
            Journal.donnees.error("Réinitialisation : verrou inaccessible (errno \(code))")
            // Un verrou qui n'existe pas encore et ne peut pas être créé désigne le dossier :
            // c'est lui qu'il faut ouvrir, il n'y a aucun fichier de verrou à retirer.
            var etat = stat()
            return .panne(lstat(chemin.path, &etat) == 0
                          ? .verrouInaccessible(chemin) : .accesRefuse(chemin.deletingLastPathComponent()))
        }
        while poser(descripteur, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            close(descripteur)
            guard code == EWOULDBLOCK else {
                Journal.donnees.error("Réinitialisation : verrou impossible à poser (errno \(code))")
                return .panne(.verrouInaccessible(chemin))
            }
            return .tenuAilleurs
        }
        var etat = stat()
        guard fstat(descripteur, &etat) == 0, etat.st_mode & S_IFMT == S_IFREG else {
            flock(descripteur, LOCK_UN)
            close(descripteur)
            Journal.donnees.error("Réinitialisation : le verrou n'est pas un fichier ordinaire")
            return .panne(.verrouInaccessible(chemin))
        }
        return .pris(descripteur)
    }
}

private extension JSONEncoder {
    static var registre: JSONEncoder {
        let encodeur = JSONEncoder()
        encodeur.dateEncodingStrategy = .iso8601
        encodeur.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encodeur
    }
}

private extension JSONDecoder {
    static var registre: JSONDecoder {
        let decodeur = JSONDecoder()
        decodeur.dateDecodingStrategy = .iso8601
        return decodeur
    }
}
