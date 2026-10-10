import Darwin
import Foundation

/// La seule implémentation réelle de `LanceurCLI` : elle exécute le CLI officiel d'un outil
/// pour lui faire afficher son quota, et rien d'autre.
///
/// ⛔ **Lancer un binaire tiers est la surface la plus exposée de l'app.** D'où, à chaque
/// lancement et sans exception :
/// - un chemin **absolu**, vérifié ici même s'il l'a déjà été par l'appelant : fichier
///   régulier, exécutable, à l'utilisateur ou à `root`, ni le fichier ni son dossier
///   inscriptibles par d'autres, et dont le chemin réel — liens symboliques résolus — reste
///   sous une des racines autorisées. C'est ce chemin réel qui est exécuté : repointer le lien
///   après la vérification ne change pas la cible ;
/// - jamais de shell : `Process` reçoit le binaire et un tableau d'arguments fixes ;
/// - un environnement construit à la main (`environnementMinimal`), sans rien hériter de
///   l'app — ni `PATH`, ni proxy, ni jeton ;
/// - un script `#!/usr/bin/env node` (les CLI publiés sur npm) ne trouve son `node` que dans
///   une liste fermée de chemins absolus (`interpretesNode`), vérifié comme le binaire ; le
///   dossier réel de ce `node`, et lui seul, passe en tête du `PATH` du fils ;
/// - un dossier de travail privé et vide (0700), supprimé ensuite ;
/// - aucune entrée standard, l'erreur standard jetée, la sortie bornée ;
/// - un délai au-delà duquel le **groupe de processus** entier est tué, enfants compris.
///
/// ⚠️ Un enfant qui quitte le groupe (`setsid`) échappe à la mise à mort ; le délai rend tout
/// de même la main, sans attendre la fin de sa sortie.
struct LanceurCLISysteme: Sendable {
    static let delaiParDefaut: TimeInterval = 10
    static let plafondSortieParDefaut = 256 * 1024

    /// Chemins réels (liens résolus) sous lesquels un binaire peut vivre.
    let racines: [String]
    /// Les `node` admis, dans l'ordre où on les essaie : chemins absolus, jamais le `PATH`.
    let interpretesNode: [URL]
    let delai: TimeInterval
    let plafondSortie: Int

    /// ⛔ `interpretesNode` n'a pas de valeur par défaut : un appelant dit lesquels il admet,
    /// et une liste vide refuse tout script qui réclame `node`.
    init(racinesAutorisees: [URL],
         interpretesNode: [URL],
         delai: TimeInterval = LanceurCLISysteme.delaiParDefaut,
         plafondSortie: Int = LanceurCLISysteme.plafondSortieParDefaut) {
        racines = racinesAutorisees.compactMap { Self.cheminReel($0.path) }
        self.interpretesNode = interpretesNode
        self.delai = delai
        self.plafondSortie = max(0, plafondSortie)
    }

    var lanceur: LanceurCLI { lanceur(reconnaissant: { _ in true }) }

    /// Le même lanceur, qui refuse en plus tout binaire dont le chemin réel — liens résolus —
    /// n'est pas celui de l'installation attendue (`QuotaDoubao.binaireReconnu`…). Le test porte
    /// sur le chemin même qui sera exécuté : un lien repointé entre-temps n'y échappe pas.
    func lanceur(reconnaissant reconnu: @escaping @Sendable (String) -> Bool) -> LanceurCLI {
        let copie = self
        return { binaire, arguments in await copie.lancer(binaire, arguments, reconnu: reconnu) }
    }

    /// ⚠️ Le délai ne dépend ni du pool coopératif ni de GCD : mesuré le 2026-10-03, un pool
    /// tenu par des attentes bloquantes d'autres travaux retardait jusqu'au lancement du
    /// processus — un `sleep 30` sous un délai d'une demi-seconde rendait la main après 35 s.
    /// Tout le déroulé vit donc sur un fil à soi, et `nonisolated(nonsending)` garde l'appel sur
    /// l'exécuteur de l'appelant. La seule attente qui reste est la reprise de l'appelant, que
    /// le runtime confie à son exécuteur : un pool saturé la retarde, mais le CLI est déjà tué.
    nonisolated(nonsending)
    func lancer(_ binaire: URL, _ arguments: [String],
                reconnu: @escaping @Sendable (String) -> Bool = { _ in true }) async -> ResultatCLI {
        let controle = ControleExecution()
        let copie = self
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (suite: CheckedContinuation<ResultatCLI, Never>) in
                // Jamais sur le fil principal ni dans le pool : `posix_spawn`, `lstat` et la
                // création du dossier de travail bloquent, et l'attente du délai aussi.
                let fil = Thread {
                    suite.resume(returning: copie.executer(binaire, arguments, reconnu: reconnu,
                                                           controle: controle))
                }
                fil.qualityOfService = .userInitiated
                fil.start()
            }
        } onCancel: {
            controle.annuler()
        }
    }

    /// Le déroulé entier, sur le fil de l'appelant, qu'il bloque jusqu'à la fin du CLI ou jusqu'à
    /// l'échéance. Aucun saut vers le pool coopératif ni vers GCD : c'est ce qui garantit le délai.
    func executer(_ binaire: URL, _ arguments: [String],
                  reconnu: @Sendable (String) -> Bool,
                  controle: ControleExecution) -> ResultatCLI {
        dispatchPrecondition(condition: .notOnQueue(.main))

        let executable: URL
        switch Self.verifier(binaire, racines: racines) {
        case .introuvable:
            return ResultatCLI(issue: .introuvable, sortie: Data(), tronquee: false)
        case .refuse:
            return ResultatCLI(issue: .refusee, sortie: Data(), tronquee: false)
        case .valide(let reel):
            executable = reel
        }
        guard reconnu(executable.path) else {
            return ResultatCLI(issue: .refusee, sortie: Data(), tronquee: false)
        }
        var enTete: [String] = []
        switch Self.interprete(de: executable) {
        case .aucun:
            break
        case .inconnu:
            return ResultatCLI(issue: .refusee, sortie: Data(), tronquee: false)
        case .node:
            guard let node = Self.localiserNode(interpretesNode, racines: racines) else {
                return ResultatCLI(issue: .refusee, sortie: Data(), tronquee: false)
            }
            enTete = [node.deletingLastPathComponent().path]
        }
        // Un octet nul couperait l'argument en silence au passage vers `execve`.
        guard !arguments.contains(where: { $0.utf8.contains(0) }),
              let dossier = Self.creerDossierPrive() else {
            return ResultatCLI(issue: .refusee, sortie: Data(), tronquee: false)
        }
        defer { try? FileManager.default.removeItem(at: dossier) }

        guard let fils = FilsCLI.lancer(executable: executable,
                                         arguments: arguments,
                                         environnement: Self.environnementMinimal(dossiersEnTete: enTete),
                                         dossier: dossier) else {
            return ResultatCLI(issue: .refusee, sortie: Data(), tronquee: false)
        }
        return fils.suivre(delai: delai, plafond: plafondSortie, controle: controle)
    }

    // MARK: - Vérification du binaire

    enum Verification: Sendable, Equatable {
        /// Le chemin réel, liens résolus : c'est lui qu'on exécute.
        case valide(URL)
        case introuvable
        case refuse
    }

    static func verifier(_ binaire: URL, racines: [String]) -> Verification {
        guard binaire.isFileURL else { return .refuse }
        let chemin = binaire.path
        guard chemin.hasPrefix("/"),
              !chemin.utf8.contains(0),
              !chemin.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            return .refuse
        }

        var etat = stat()
        if lstat(chemin, &etat) != 0 {
            return errno == ENOENT || errno == ENOTDIR ? .introuvable : .refuse
        }
        // Un lien pendant n'a pas de cible : rien à lancer.
        guard let reel = cheminReel(chemin) else { return .introuvable }

        // Le dossier où l'appelant l'a trouvé, comme la cible du lien, restent sous une racine.
        let dossierDemande = (chemin as NSString).deletingLastPathComponent
        guard let dossierReel = cheminReel(dossierDemande),
              sousUneRacine(dossierReel, racines),
              sousUneRacine(reel, racines) else { return .refuse }

        guard stat(reel, &etat) == 0,
              (etat.st_mode & S_IFMT) == S_IFREG,
              proprietaireAdmis(etat.st_uid),
              etat.st_mode & (S_IWGRP | S_IWOTH) == 0,
              access(reel, X_OK) == 0 else { return .refuse }

        var etatDossier = stat()
        let dossierCible = (reel as NSString).deletingLastPathComponent
        guard stat(dossierCible, &etatDossier) == 0,
              proprietaireAdmis(etatDossier.st_uid),
              etatDossier.st_mode & S_IWOTH == 0 else { return .refuse }

        return .valide(URL(fileURLWithPath: reel))
    }

    /// Cherche `nom` dans une liste **fermée** de dossiers, dans l'ordre, et rend le premier
    /// candidat que `verifier` admet. Jamais de `PATH` : on ne lance que ce qu'on a désigné.
    static func localiser(nom: String, dans dossiers: [URL], racines racinesURL: [URL]) -> URL? {
        guard !nom.isEmpty, nom != ".", nom != "..",
              !nom.contains("/"), !nom.utf8.contains(0) else { return nil }
        let racines = racinesURL.compactMap { cheminReel($0.path) }
        for dossier in dossiers {
            let candidat = dossier.appendingPathComponent(nom, isDirectory: false)
            if case .valide = verifier(candidat, racines: racines) { return candidat }
        }
        return nil
    }

    // MARK: - Interprète d'un script

    enum Interprete: Sendable, Equatable {
        /// Un binaire, ou un script dont la ligne `#!` nomme un chemin absolu du système.
        case aucun
        /// `#!/usr/bin/env node`, la forme des CLI publiés sur npm.
        case node
        /// `#!/usr/bin/env` suivi d'autre chose : on ne sait pas ce qu'il irait chercher dans
        /// le `PATH`, donc on ne le lance pas.
        case inconnu
    }

    /// Lit la ligne `#!` du fichier réel. Seul `/usr/bin/env` délègue au `PATH` : c'est le seul
    /// cas où le fils irait chercher un exécutable ailleurs qu'au chemin écrit.
    static func interprete(de executable: URL) -> Interprete {
        guard let poignee = try? FileHandle(forReadingFrom: executable) else { return .inconnu }
        defer { try? poignee.close() }
        let tete = (try? poignee.read(upToCount: 256)) ?? Data()
        return interprete(tete: tete)
    }

    static func interprete(tete: Data) -> Interprete {
        guard tete.starts(with: Data("#!".utf8)) else { return .aucun }
        let ligne = tete.dropFirst(2).prefix { $0 != 0x0A && $0 != 0x0D }
        let mots = String(decoding: ligne, as: UTF8.self)
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let premier = mots.first else { return .inconnu }
        guard premier == "/usr/bin/env" else { return premier.hasPrefix("/") ? .aucun : .inconnu }
        var reste = mots.dropFirst()
        if reste.first == "-S" { reste = reste.dropFirst() }
        return reste.first == "node" ? .node : .inconnu
    }

    /// Le premier `node` de la liste fermée que `verifier` admet, liens résolus.
    static func localiserNode(_ candidats: [URL], racines: [String]) -> URL? {
        for candidat in candidats {
            guard candidat.lastPathComponent == "node" else { continue }
            if case .valide(let reel) = verifier(candidat, racines: racines) { return reel }
        }
        return nil
    }

    private static func sousUneRacine(_ chemin: String, _ racines: [String]) -> Bool {
        racines.contains { racine in
            racine == "/" ? chemin.hasPrefix("/") : (chemin == racine || chemin.hasPrefix(racine + "/"))
        }
    }

    private static func proprietaireAdmis(_ uid: uid_t) -> Bool {
        uid == getuid() || uid == 0
    }

    static func cheminReel(_ chemin: String) -> String? {
        guard let brut = realpath(chemin, nil) else { return nil }
        defer { free(brut) }
        return String(cString: brut)
    }

    // MARK: - Environnement et dossier de travail

    /// Rien n'est hérité de l'app. `HOME`, `USER` et `LOGNAME` viennent de la base des
    /// utilisateurs, pas de l'environnement courant ; `PATH` ne nomme que les dossiers du
    /// système, pour qu'un outil qui relance un utilitaire ne trouve rien d'installé par
    /// l'utilisateur ; `LANG` est figé pour que la sortie ne dépende pas de la langue du Mac.
    /// `NO_COLOR` et `TERM=dumb` demandent une sortie sans séquences de terminal, que les
    /// lecteurs n'auraient pas à retirer. `dossiersEnTete` ne porte que le dossier réel d'un
    /// `node` vérifié.
    static func environnementMinimal(dossiersEnTete: [String] = []) -> [String: String] {
        var environnement = [
            "LANG": "en_US.UTF-8",
            "PATH": (dossiersEnTete + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":"),
            "NO_COLOR": "1",
            "TERM": "dumb",
        ]
        if let compte = compteCourant() {
            environnement["HOME"] = compte.dossier
            environnement["USER"] = compte.nom
            environnement["LOGNAME"] = compte.nom
        }
        if let temporaire = dossierTemporaireUtilisateur() {
            environnement["TMPDIR"] = temporaire
        }
        return environnement
    }

    private static func compteCourant() -> (nom: String, dossier: String)? {
        var entree = passwd()
        var resultat: UnsafeMutablePointer<passwd>?
        var tampon = [CChar](repeating: 0, count: 16_384)
        let code = getpwuid_r(getuid(), &entree, &tampon, tampon.count, &resultat)
        guard code == 0, resultat != nil, let nom = entree.pw_name, let dossier = entree.pw_dir else {
            return nil
        }
        return (String(cString: nom), String(cString: dossier))
    }

    private static func dossierTemporaireUtilisateur() -> String? {
        var tampon = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &tampon, tampon.count) > 0 else { return nil }
        let octets = tampon.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let chemin = String(decoding: octets, as: UTF8.self)
        return chemin.isEmpty ? nil : chemin
    }

    private static func creerDossierPrive() -> URL? {
        let dossier = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotum-cli-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dossier,
                                                    withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            return dossier
        } catch {
            return nil
        }
    }
}

/// Le nom `kevent` désigne à la fois la structure et l'appel système : l'appel, sans ambiguïté.
private func appelKevent(_ file: Int32, _ abonnements: UnsafePointer<Darwin.kevent>?, _ nombre: Int32,
                         _ evenements: UnsafeMutablePointer<Darwin.kevent>?, _ place: Int32,
                         _ limite: UnsafePointer<timespec>?) -> Int32 {
    kevent(file, abonnements, nombre, evenements, place, limite)
}

/// L'annulation de la tâche appelante, qui peut arriver avant, pendant ou après le suivi du
/// processus : elle réveille la file `kqueue` du suivi par un événement utilisateur.
final class ControleExecution: @unchecked Sendable {
    private let verrou = NSLock()
    private var annule = false
    private var file: Int32 = -1

    static let identifiantReveil: UInt = 1

    func annuler() {
        verrou.lock()
        defer { verrou.unlock() }
        annule = true
        if file >= 0 { FilsCLI.declencher(file) }
    }

    /// Rend `false` si l'annulation est déjà tombée : le suivi n'attend alors rien.
    func attacher(_ file: Int32) -> Bool {
        verrou.lock()
        defer { verrou.unlock() }
        self.file = file
        return !annule
    }

    /// Détache la file avant qu'on la ferme : un `annuler` tardif ne vise plus un descripteur
    /// qui pourrait avoir été réattribué.
    func detacher() {
        verrou.lock()
        file = -1
        verrou.unlock()
    }

    var estAnnule: Bool {
        verrou.lock()
        defer { verrou.unlock() }
        return annule
    }
}

/// Un CLI lancé par `posix_spawn`, suivi sur le fil de l'appelant par `kqueue` : lecture de la
/// sortie, fin du processus et échéance du délai, sans gestionnaire GCD ni tâche Swift. Le fils
/// est seul dans son groupe (`POSIX_SPAWN_SETPGROUP`) et n'hérite d'aucun descripteur de l'app
/// (`POSIX_SPAWN_CLOEXEC_DEFAULT`) hormis ses trois entrées-sorties.
struct FilsCLI {
    let pid: pid_t
    let lecture: Int32

    static func lancer(executable: URL, arguments: [String], environnement: [String: String],
                       dossier: URL) -> FilsCLI? {
        var bouts: [Int32] = [-1, -1]
        guard pipe(&bouts) == 0 else { return nil }
        let (lecture, ecriture) = (bouts[0], bouts[1])
        // Un autre lancement de l'app ne doit pas hériter du bout d'écriture : il tiendrait la
        // sortie ouverte après la mort du groupe.
        _ = fcntl(lecture, F_SETFD, FD_CLOEXEC)
        _ = fcntl(ecriture, F_SETFD, FD_CLOEXEC)
        _ = fcntl(lecture, F_SETFL, fcntl(lecture, F_GETFL) | O_NONBLOCK)

        var actions: posix_spawn_file_actions_t?
        var attributs: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributs)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributs)
        }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, ecriture, STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir(&actions, dossier.path)

        // Les signaux ignorés ou masqués par l'app ne passent pas au CLI.
        var aucun = sigset_t()
        var tous = ~sigset_t()
        posix_spawnattr_setsigmask(&attributs, &aucun)
        posix_spawnattr_setsigdefault(&attributs, &tous)
        posix_spawnattr_setpgroup(&attributs, 0)
        posix_spawnattr_setflags(&attributs, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                   | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_set_qos_class_np(&attributs, QOS_CLASS_UTILITY)

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environnement.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable.path, &actions, &attributs, argv, envp)
        close(ecriture)
        guard code == 0, pid > 0 else {
            close(lecture)
            return nil
        }
        return FilsCLI(pid: pid, lecture: lecture)
    }

    static func declencher(_ file: Int32) {
        var reveil = Darwin.kevent(ident: ControleExecution.identifiantReveil, filter: Int16(EVFILT_USER),
                                   flags: 0, fflags: UInt32(NOTE_TRIGGER), data: 0, udata: nil)
        _ = appelKevent(file, &reveil, 1, nil, 0, nil)
    }

    /// Lit la sortie jusqu'à la fin du processus, ou jusqu'à l'échéance — mesurée sur une horloge
    /// monotone — ou jusqu'à l'annulation. Rend toujours la main à l'échéance : ni un processus
    /// qui refuse de mourir ni un enfant sorti du groupe qui garde la sortie ouverte ne la
    /// retiennent.
    func suivre(delai: TimeInterval, plafond: Int, controle: ControleExecution) -> ResultatCLI {
        let horloge = ContinuousClock()
        let echeance = horloge.now.advanced(by: .nanoseconds(Int64(max(0, delai) * 1_000_000_000)))

        var sortie = Data()
        var tronquee = false
        var sortieClose = false
        var fin: Int32?

        let file = kqueue()
        var suiviFiable = file >= 0
        if file >= 0 {
            var abonnements = [
                Darwin.kevent(ident: UInt(lecture), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD),
                              fflags: 0, data: 0, udata: nil),
                Darwin.kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD),
                              fflags: UInt32(NOTE_EXIT), data: 0, udata: nil),
                Darwin.kevent(ident: ControleExecution.identifiantReveil, filter: Int16(EVFILT_USER),
                              flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: nil),
            ]
            for indice in abonnements.indices
            where appelKevent(file, &abonnements[indice], 1, nil, 0, nil) != 0 {
                suiviFiable = false
            }
        }
        var annule = file >= 0 ? !controle.attacher(file) : controle.estAnnule
        defer {
            controle.detacher()
            if file >= 0 { close(file) }
            close(lecture)
        }

        var tampon = [UInt8](repeating: 0, count: 64 * 1024)
        func vider() {
            while !sortieClose {
                let lu = tampon.withUnsafeMutableBytes { read(lecture, $0.baseAddress, $0.count) }
                if lu > 0 {
                    guard !tronquee else { continue }
                    let place = plafond - sortie.count
                    if lu > place {
                        sortie.append(contentsOf: tampon[0..<max(0, place)])
                        tronquee = true
                        // Au-delà du plafond, la suite ne sera pas lue : inutile de laisser
                        // tourner le CLI.
                        tuerGroupe()
                    } else {
                        sortie.append(contentsOf: tampon[0..<lu])
                    }
                } else if lu == 0 {
                    sortieClose = true
                } else if errno != EINTR {
                    return
                }
            }
        }

        var lectureSuivie = suiviFiable
        while true {
            vider()
            // Une fois la sortie close, le filtre de lecture se déclencherait sans fin : on le
            // retire pour attendre la mort du processus sans tourner à vide.
            if sortieClose, lectureSuivie {
                var retrait = Darwin.kevent(ident: UInt(lecture), filter: Int16(EVFILT_READ),
                                            flags: UInt16(EV_DELETE), fflags: 0, data: 0, udata: nil)
                if appelKevent(file, &retrait, 1, nil, 0, nil) != 0 { suiviFiable = false }
                lectureSuivie = false
            }
            if fin == nil { fin = recolter() }
            if let fin, sortieClose || tronquee {
                return ResultatCLI(issue: .terminee(code: fin), sortie: sortie, tronquee: tronquee)
            }
            if annule { break }
            let reste = horloge.now.duration(to: echeance)
            guard reste > .zero else { break }
            // Sans abonnement fiable, on se réveille souvent pour constater par soi-même.
            let attente = suiviFiable ? reste : min(reste, .milliseconds(50))
            let (secondes, attos) = attente.components
            var limite = timespec(tv_sec: Int(secondes), tv_nsec: Int(attos / 1_000_000_000))
            var evenements = [Darwin.kevent](repeating: Darwin.kevent(), count: 4)
            if file >= 0 {
                let nombre = appelKevent(file, nil, 0, &evenements, Int32(evenements.count), &limite)
                if nombre > 0, evenements[0..<Int(nombre)].contains(where: { $0.filter == Int16(EVFILT_USER) }) {
                    annule = true
                }
            } else {
                _ = nanosleep(&limite, nil)
                annule = controle.estAnnule
            }
        }

        // Délai dépassé ou tâche annulée : le groupe est tué et la main rendue tout de suite.
        tuerGroupe()
        if fin == nil, recolter() == nil {
            // Un processus qui ne meurt pas encore est récolté plus tard, sans faire attendre.
            let pid = self.pid
            let recolteur = Thread {
                var statut: Int32 = 0
                while waitpid(pid, &statut, 0) < 0, errno == EINTR {}
            }
            recolteur.qualityOfService = .utility
            recolteur.start()
        }
        return ResultatCLI(issue: .delaiDepasse, sortie: sortie, tronquee: tronquee)
    }

    /// Le fils non récolté reste dans son groupe : tant qu'on ne l'a pas récolté, le numéro du
    /// groupe ne peut pas être réattribué, et `kill(-pid)` ne vise que lui et ses enfants restés.
    private func tuerGroupe() {
        _ = kill(-pid, SIGKILL)
    }

    /// Le code de fin si le fils est mort — convention du shell pour une mort par signal, qui ne
    /// doit jamais se lire comme un succès —, `nil` s'il vit encore. Les enfants restés dans le
    /// groupe sont tués avant la récolte : ils tiendraient la sortie ouverte.
    private func recolter() -> Int32? {
        var infos = siginfo_t()
        guard waitid(P_PID, id_t(pid), &infos, WEXITED | WNOHANG | WNOWAIT) == 0, infos.si_pid == pid else {
            return nil
        }
        tuerGroupe()
        var statut: Int32 = 0
        while waitpid(pid, &statut, 0) < 0, errno == EINTR {}
        let signal = statut & 0x7F
        return signal == 0 ? (statut >> 8) & 0xFF : 128 + signal
    }
}
