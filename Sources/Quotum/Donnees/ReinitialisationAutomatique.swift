import Foundation

/// Ce qui exécute le réglage « Rouvrir un quota épuisé sans demander ». Sans lui le
/// réglage n'était lu que par l'interrupteur qui l'écrit : armé, rien ne se serait jamais
/// produit.
///
/// Les conditions de déclenchement ne sont pas réécrites ici : c'est
/// `ArmementReinitialisation` qui les tient, pour le tiroir comme pour l'automatisme.
/// Deux jeux de règles finiraient par diverger, et l'automatisme dépenserait un crédit là
/// où l'invite, elle, refuse de le proposer.
///
/// ⛔ Personne ne regarde l'écran pendant qu'il dépense. D'où, en plus de l'armement :
/// un épisode identifié par son échéance et consigné sur disque **avant** l'envoi, un
/// compte nommé que l'exécuteur doit retrouver dans `auth.json`, le consentement de
/// mesure et le réglage relus au dernier moment, et une notification autorisée — la
/// dépense se dit toujours, ou elle n'a pas lieu.
///
/// ⛔ `partage` câble le registre du parc. Un registre à part ferait de l'automatisme le
/// seul doubleur que la garde manuelle ne voit pas : deux appels sur le même épuisement.
@MainActor
final class ServiceReinitialisationAutomatique {
    static let partage = ServiceReinitialisationAutomatique(
        executer: appelReel,
        registre: .partage,
        reglagesCourants: { MagasinReglages.shared.valeur },
        autorisation: { await ServiceNotifications.partage.autorisationActuelle() },
        notifier: { await ServiceNotifications.partage.deposer($0) },
        dejaDelivrees: { await ServiceNotifications.partage.identifiantsDelivres() })

    /// Entre deux relectures d'une file d'annonces que le verrou d'une autre copie de l'app
    /// a empêché de lire.
    static let delaiReprise: TimeInterval = 60

    /// ⛔ Deux copies de l'app peuvent tourner ensemble — deux bundles installés, ou
    /// `open -n` —, et elles partagent la file. Une annonce plus jeune que ce délai est
    /// peut-être celle d'une demande que l'autre copie mène encore : lecture du jeton, envoi
    /// sous un délai de garde de dix secondes, dépôt de la notification. La dire interrompue affirmerait qu'on
    /// n'a pas pu prévenir, pendant que l'autre s'apprête à le faire. Passé ce délai,
    /// l'autre a fini, ou a quitté : l'annonce est en souffrance.
    static let delaiEnVol: TimeInterval = 5 * 60

    /// ⛔ Le second argument est le compte mesuré. Si la connexion relue a changé depuis
    /// le relevé, c'est la seule chose qui empêche de débiter un compte pour un autre, puis
    /// de l'annoncer sous le nom du premier. Le troisième est l'auth.json de la rangée, le
    /// quatrième la dernière garde, que l'exécuteur relit juste avant le POST.
    typealias Executeur = @Sendable (UUID, String, URL, @escaping @Sendable () async -> Bool) async
        -> IssueReinitialisation

    static let appelReel: Executeur = { demande, compteAttendu, fichier, avantEnvoi in
        await ReinitialisationCodex.consommerAvecJetonLocal(demandeIdentifiant: demande,
                                                            compteAttendu: compteAttendu,
                                                            fichier: fichier,
                                                            avantEnvoi: avantEnvoi)
    }

    private let executer: Executeur
    private let registre: RegistreReinitialisation
    private let reglagesCourants: @MainActor () -> Reglages
    private let autorisation: @MainActor () async -> AutorisationAlertes
    /// `true` quand le système a pris la notification. Tant qu'il ne l'a pas dit, l'annonce
    /// reste en attente sur le disque.
    private let notifier: @MainActor (Alerte) async -> Bool
    /// Les identifiants des notifications encore affichées dans le centre de notifications.
    private let dejaDelivrees: @MainActor () async -> Set<String>
    private let horloge: @MainActor () -> Date
    private let attendre: @MainActor (TimeInterval) async -> Void
    /// Les demandes dont une tâche de cette instance tient l'annonce : en vol, ou en train
    /// d'être redites. Leur annonce est dans la file, mais elle n'est pas en souffrance.
    private var operationsEnMain: Set<String> = []
    /// Par compte, le dernier essai qui s'est arrêté sans rien envoyer. La trace disque est
    /// levée — l'épisode n'est pas condamné —, mais la cause, une session sur un autre
    /// compte le plus souvent, ne se corrige pas d'elle-même en cinq minutes : sans ce
    /// rythme, une notification repartirait à chaque tour du minuteur.
    private var essaisSansEnvoi: [String: Date] = [:]

    init(executer: @escaping Executeur,
         registre: RegistreReinitialisation,
         reglagesCourants: @escaping @MainActor () -> Reglages,
         autorisation: @escaping @MainActor () async -> AutorisationAlertes,
         notifier: @escaping @MainActor (Alerte) async -> Bool,
         dejaDelivrees: @escaping @MainActor () async -> Set<String>,
         horloge: @escaping @MainActor () -> Date = { .now },
         attendre: @escaping @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.executer = executer
        self.registre = registre
        self.reglagesCourants = reglagesCourants
        self.autorisation = autorisation
        self.notifier = notifier
        self.dejaDelivrees = dejaDelivrees
        self.horloge = horloge
        self.attendre = attendre
    }

    /// ⛔ `etablies` lit l'état établi **courant** de l'inventaire, sans valeur par défaut : la
    /// dernière garde le relit juste avant le POST. Une publication déjà faite mais pas encore
    /// livrée à cette méthode arrête l'envoi.
    func evaluer(lignes: [Ligne], etablies: @escaping @MainActor () -> [Ligne], reglages: Reglages,
                 maintenant: Date = .now) {
        guard Self.autorise(reglages), registre.fiable else { return }
        for ligne in lignes {
            guard let episode = ArmementReinitialisation.episodeSansSurveillance(
                      ligne, delais: reglages.delaisReinitialisation, maintenant: maintenant),
                  let compte = episode.compte, let fichier = episode.fichier
            else { continue }
            // ⛔ Le même épuisement revient à chaque tour du minuteur, avec une date de
            // relevé neuve mais la même échéance : c'est elle qui dit qu'il a déjà été
            // traité. Simple filtre : l'acquisition, sous verrou, reste l'autorité.
            guard !registre.dejaTraite(episode.cle, retour: episode.echeance, maintenant: maintenant)
            else { continue }
            if let essai = essaisSansEnvoi[episode.cle],
               maintenant.timeIntervalSince(essai) < RegistreReinitialisation.delaiDeGrace { continue }
            declencher(episode, compte: compte, fichier: fichier, nom: reglages.nomAffiche(de: ligne),
                       etablies: etablies)
        }
    }

    /// ⛔ Relire le consentement ici plutôt que se fier à l'état des lignes : un relevé
    /// lancé avant son retrait publie encore un épuisement, et le jeton qu'on lirait
    /// appartient à un fournisseur que l'utilisateur vient de fermer.
    private static func autorise(_ reglages: Reglages) -> Bool {
        reglages.reinitialisationAutomatique && reglages.consentementMesure[.chatgpt]
    }

    /// Tout ce qui a été vérifié avant une attente, revérifié après. ⛔ Le registre compris :
    /// une panne survenue pendant la lecture du jeton n'arrête sinon que les demandes
    /// suivantes, et l'avertissement affirmerait que rien ne sera dépensé.
    ///
    /// ⛔ Le délai aussi est relu : un délai allongé pendant la lecture du jeton peut faire
    /// tomber l'épisode sous le nouveau seuil, et l'automatisme ne dépense pas là où il se
    /// tairait désormais.
    ///
    /// ⛔ Et l'état établi courant : une mesure arrivée pendant l'attente qui dit le compte
    /// rouvert, le retire, ou le rattache à un autre fichier, arrête l'envoi.
    private func tientEncore(_ episode: ArmementReinitialisation.Instantane,
                             _ etablies: @MainActor () -> [Ligne]) -> Bool {
        let reglages = reglagesCourants()
        let maintenant = horloge()
        guard Self.autorise(reglages), episode.estValable(a: maintenant), registre.fiable,
              let echeance = episode.echeance else { return false }
        let toujoursArme = etablies().contains { ligne in
            guard let courant = ArmementReinitialisation.episodeSansSurveillance(
                ligne, delais: reglages.delaisReinitialisation, maintenant: maintenant) else { return false }
            return courant.cle == episode.cle && courant.compte == episode.compte
                && courant.fichier == episode.fichier && courant.echeance == episode.echeance
        }
        return toujoursArme && echeance.timeIntervalSince(maintenant) >= reglages.delaisReinitialisation.automatique
    }

    /// Le nom est résolu **avant** l'appel : c'est celui que la rangée affichait au moment
    /// du déclenchement, et la notification qui suivra doit nommer le même compte.
    private func declencher(_ episode: ArmementReinitialisation.Instantane, compte: String, fichier: URL,
                            nom: String, etablies: @escaping @MainActor () -> [Ligne]) {
        guard registre.reserver(episode.cle) else { return }
        // L'identifiant de la demande est aussi celui de son annonce et de sa notification.
        let demande = UUID()
        let operation = demande.uuidString
        operationsEnMain.insert(operation)
        Task { [self] in
            defer {
                registre.liberer(episode.cle)
                operationsEnMain.remove(operation)
            }
            guard await autorisation() == .accordee else {
                Journal.donnees.notice("Réinitialisation automatique retenue : notifications non autorisées")
                return
            }
            // ⛔ L'annonce entre dans la file par l'écriture qui consigne l'épisode, donc avant
            // l'envoi : une app qui quitte pendant le POST — dix secondes au plus — la laisse
            // sur le disque aussi.
            let annonce = RegistreReinitialisation.Annonce(operation: operation, cle: episode.cle, nom: nom)
            guard tientEncore(episode, etablies),
                  case .acquise(let consigne) = await registre.acquerir(episode.cle, retour: episode.echeance,
                                                                        maintenant: horloge(), annonce: annonce)
            else { return }
            let issue = await executer(demande, compte, fichier) { [self] in
                await MainActor.run { tientEncore(episode, etablies) }
            }
            if issue.rienNEstParti { essaisSansEnvoi[episode.cle] = horloge() }
            // ⛔ Tant que l'issue n'est pas écrite, le disque dit « peut-être dépensée », et
            // une consignation levée pour rien condamnerait l'épisode. Un verrou tenu
            // ailleurs se reprend ; seule une panne fait renoncer.
            let notee = await reprendre { await registre.conclure(operation, issue: issue, cle: episode.cle,
                                                                  consigne: consigne) }
            // Rien n'est parti et rien n'a changé pour l'utilisateur : se taire. Toute autre
            // issue — y compris un compte discordant — se dit.
            guard issue != .abandonnee else { return }
            // ⛔ Soldée seulement une fois la notification prise par le système : une app qui
            // quitte avant, ou une notification refusée, laisse l'annonce au relancement.
            let prise = await notifier(.reinitialisationAutomatique(operation: operation, nom: nom, issue: issue))
            if notee, prise {
                await reprendre { await registre.solder(operation) }
            }
        }
    }

    /// Une écriture que le verrou d'une autre copie a empêchée se reprend, comme la relecture
    /// des annonces : seule une panne du registre y met fin.
    @discardableResult
    private func reprendre(_ ecrire: () async -> RegistreReinitialisation.Ecriture) async -> Bool {
        while !Task.isCancelled {
            switch await ecrire() {
            case .faite:
                return true
            case .inutilisable:
                return false
            case .verrouTenu:
                Journal.donnees.notice("Réinitialisation : écriture reportée, verrou tenu ailleurs")
                await attendre(Self.delaiReprise)
            }
        }
        return false
    }

    /// ⛔ À appeler au lancement. Une annonce restée dans la file dit que la notification
    /// n'a jamais été prise — l'app a quitté avant, ou le système l'a refusée. Elle se dit
    /// maintenant, dans l'ordre où les demandes sont parties, et ne quitte la file qu'une
    /// fois la notification prise — sinon elle attend le lancement suivant.
    ///
    /// ⚠️ Un verrou tenu par une autre copie de l'app n'est pas une file vide : la lecture
    /// est reprise jusqu'à ce qu'elle aboutisse. Seul un registre en panne y met fin, et sa
    /// panne se voit dans les réglages. Une annonce assez jeune pour appartenir à une
    /// demande que l'autre copie mène encore attend, elle, d'avoir passé `delaiEnVol`.
    ///
    /// Ni le réglage ni le consentement ne sont relus : une dépense faite quand ils étaient
    /// armés se dit encore après qu'on les a retirés.
    @discardableResult
    func annoncerLesEnvoisInterrompus() -> Task<Void, Never> {
        Task { [self] in
            while !Task.isCancelled {
                switch await registre.annoncesEnAttente() {
                case .lues(let annonces):
                    let maintenant = horloge()
                    let horsDeMain = annonces.filter { !operationsEnMain.contains($0.operation) }
                    await redire(horsDeMain.filter { !Self.peutEtreEnVol($0, maintenant: maintenant) })
                    let enVolAilleurs = horsDeMain.compactMap { annonce in
                        Self.peutEtreEnVol(annonce, maintenant: maintenant) ? annonce.inscriteA : nil
                    }
                    guard let plusAncienne = enVolAilleurs.min() else { return }
                    let echeance = plusAncienne.addingTimeInterval(Self.delaiEnVol)
                    await attendre(max(1, echeance.timeIntervalSince(horloge())))
                case .inutilisable:
                    return
                case .verrouTenu:
                    Journal.donnees.notice("Réinitialisation : annonces en attente non relues, verrou tenu ailleurs")
                    await attendre(Self.delaiReprise)
                }
            }
        }
    }

    /// Une date à venir — horloge reculée depuis — ne prouve pas qu'une demande est en vol :
    /// l'annonce se dit, au pire deux fois sous le même identifiant, qui se remplacent.
    private static func peutEtreEnVol(_ annonce: RegistreReinitialisation.Annonce, maintenant: Date) -> Bool {
        guard let inscriteA = annonce.inscriteA else { return false }
        let age = maintenant.timeIntervalSince(inscriteA)
        return age >= 0 && age < delaiEnVol
    }

    /// ⚠️ Une notification prise par le système juste avant que l'app quitte, sans que
    /// l'annonce ait pu être retirée, se reconnaît dans le centre de notifications : la
    /// redire la doublerait, sous un texte qui affirmerait qu'on n'a pas pu prévenir. Si
    /// l'utilisateur l'a effacée entre-temps, rien ne la distingue plus d'une annonce jamais
    /// faite, et elle se redit.
    private func redire(_ annonces: [RegistreReinitialisation.Annonce]) async {
        let aRedire = annonces.filter { !operationsEnMain.contains($0.operation) }
        guard !aRedire.isEmpty else { return }
        let operations = Set(aRedire.map(\.operation))
        operationsEnMain.formUnion(operations)
        defer { operationsEnMain.subtract(operations) }
        let delivrees = await dejaDelivrees()
        for annonce in aRedire {
            let alerte = Self.alerte(pour: annonce)
            let prise = delivrees.contains(alerte.identifiant) ? true : await notifier(alerte)
            if prise { await reprendre { await registre.solder(annonce.operation) } }
        }
    }

    private static func alerte(pour annonce: RegistreReinitialisation.Annonce) -> Alerte {
        guard let issue = annonce.issue else {
            return .reinitialisationInterrompue(operation: annonce.operation, nom: annonce.nom)
        }
        return .reinitialisationAutomatique(operation: annonce.operation, nom: annonce.nom, issue: issue)
    }
}
