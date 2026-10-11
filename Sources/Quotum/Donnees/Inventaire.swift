import Combine
import Foundation

/// Agrégat des trois sources, observé par le panneau. Le minuteur appartient à
/// l'appelant : `Inventaire` ne sait que se rafraîchir à la demande.
@MainActor
final class Inventaire: ObservableObject {
    @Published private(set) var lignes: [Ligne] = []
    /// Le même état, publié seulement quand toutes les sources ont répondu. La
    /// première publication d'un démarrage remplit le panneau avec ce que le disque
    /// et les proxies savent déjà ; la donner à des effets externes les ferait agir
    /// sur une mesure du pool que le relevé du Trousseau contredit parfois dans la
    /// seconde qui suit — une notification, elle, ne se retire pas.
    @Published private(set) var lignesEtablies: [Ligne] = []
    @Published private(set) var derniereMiseAJour: Date?
    /// La lecture elle-même, et non le seul booléen « muet » qu'on en tirait : `.absent`
    /// — aucun fichier de proxy sur cette machine — et `.muet` — installé, sans voix —
    /// s'y confondaient. L'accueil a besoin de les séparer : il ne mentionne jamais un
    /// proxy absent, sous peine de reprocher à un acheteur l'absence d'une brique qu'il
    /// n'a pas voulue.
    ///
    /// `nil` tant qu'aucune lecture n'a eu lieu — un diagnostic sans mesure n'en est pas
    /// un, et le panneau ne doit annoncer aucun silence avant d'avoir écouté.
    @Published private(set) var lectureProxyClaude: LectureProxy?
    @Published private(set) var lectureProxyCodex: LectureProxy?
    /// Les applications de bureau des fournisseurs, relues à chaque cycle : elles
    /// s'installent et se désinstallent sans que l'app redémarre.
    @Published private(set) var applicationsInstallees = ApplicationsInstallees()
    /// Le compte que Claude Code a écrit dans `~/.claude.json`, sans jeton. Publié
    /// pour l'accueil : c'est la seule preuve qu'une session existe **sans ouvrir une
    /// source d'identifiants**, donc sans rien demander à personne.
    @Published private(set) var identiteClaudeCode: IdentiteClaudeCode?

    var proxyClaudeMuet: Bool { lectureProxyClaude?.estMuet ?? false }
    var proxyCodexMuet: Bool { lectureProxyCodex?.estMuet ?? false }
    /// Le jeton du Trousseau a été refusé : le seul pourcentage exact du panneau est
    /// hors d'atteinte jusqu'au prochain `/login`.
    @Published private(set) var reconnexionClaudeCode = false
    /// Les lignes affichées sans aucune mesure, que la licence ne laisse pas relever : le
    /// panneau les rend comme telles. Vide avec une licence.
    @Published private(set) var verrouillees: Set<String> = []

    private(set) var rafraichissementEnCours = false
    /// Le départ du dernier cycle, quelle qu'en soit la cause : les relances s'y espacent.
    private(set) var dernierDepart: ContinuousClock.Instant?
    /// Le dernier relevé établi par chaque lecteur consenti, que `PorteEssai` reçoit d'un tour
    /// à l'autre. En mémoire seulement : un lancement repart de ce que la machine dit d'elle-même.
    private var relevesRetenus = RelevesDirects.indeterminees
    /// L'argent mesuré par les relevés directs, gardé pour le cycle où leur lecteur se tait.
    private var usagesConserves = UsagesConserves()
    /// La dernière dépense lue par chaque clé de lecture, pour le cycle où la requête ne
    /// rapporte rien. En mémoire seulement, comme `relevesRetenus`.
    private var depensesRetenues = DepensesRetenues()
    /// La dernière limite reçue : un tour parti sous une autre s'y plie à sa publication.
    private var derniereLimite: LimiteComptes?

    init() {}

    /// Les lectures partent ensemble et hors du fil principal. Le disque — les bundles,
    /// la table de correspondances, puis l'identité que Claude Code a écrite — et les deux proxies
    /// répondent en une seconde et demie au plus ; le Trousseau, lui, peut ouvrir une
    /// fenêtre d'autorisation puis enchaîner deux appels réseau. Attendre ce dernier
    /// pour publier les autres laissait le panneau vide une quinzaine de secondes au
    /// démarrage, alors que presque tout était déjà connu.
    ///
    /// ⚠️ Les relevés directs ne sont pas listés ici : `RelevesDirects.relever()` les
    /// tient tous, et son initialiseur sans valeur par défaut est ce qui empêche d'en
    /// oublier un. Le `async let` qui l'appelle part avec les autres, donc les lectures
    /// restent simultanées.
    ///
    /// ⛔ Le consentement arrive par paramètre, et sans valeur par défaut : l'inventaire
    /// ne va pas le chercher lui-même dans les réglages. Un rafraîchissement ne peut
    /// donc pas partir sans que son appelant ait dit, à cet endroit précis du code, ce
    /// que l'utilisateur a autorisé.
    ///
    /// Chaque publication est un état complet, jamais une liste à moitié construite :
    /// la première dit ce que le disque et les proxies savent, la seconde y ajoute le
    /// relevé du Trousseau.
    ///
    /// La publication anticipée ne vaut que tant qu'il n'y a rien à l'écran. Un panneau
    /// déjà rempli garderait sa liste intacte pendant l'attente : la republier sans le
    /// relevé ferait disparaître puis revenir, à chaque tour de minuteur, la grille du
    /// seul compte mesuré exactement.
    ///
    /// ⛔ La limite arrive par paramètre et sans valeur par défaut, comme le consentement.
    /// Ce qu'elle laisse relever, lire et afficher, `PorteEssai` le décide ; sans porte,
    /// rien ne part du tout.
    ///
    /// ⛔ `cles` non plus n'a pas de valeur par défaut : c'est par là que passent le Trousseau
    /// de Quotum et la requête de dépense.
    ///
    /// ⛔ `consentementCourant` est relu après chaque attente, avant toute lecture ou requête
    /// qui suit : un suivi retiré pendant le tour n'ouvre plus rien et n'est plus publié.
    func rafraichir(consentement initial: ConsentementMesure,
                    consentementCourant: @MainActor () -> ConsentementMesure,
                    limite: LimiteComptes,
                    cles: LecteursClesLecture,
                    lecteurs: LecteursDirects = .reels,
                    lecteursCodex: LecteursCodex = .reels) async {
        derniereLimite = limite
        if let fermees = PorteEssai.fermerSansReleve(limite, publiees: lignes, verrouillees: verrouillees,
                                                     etablies: lignesEtablies) {
            (lignes, verrouillees) = fermees
            lignesEtablies = fermees.lignes
        }
        guard !rafraichissementEnCours, let porte = PorteEssai(limite) else { return }
        rafraichissementEnCours = true
        dernierDepart = ContinuousClock.now
        defer { rafraichissementEnCours = false }
        var consentement = initial.restreint(a: consentementCourant())

        // Sans limite, les relevés partent avec les lectures locales.
        let relevesLibres: Task<RelevesDirects, Never>? = porte.libre
            ? Task { await RelevesDirects.relever(consentement: consentement, lecteurs: lecteurs) }
            : nil
        let clesLibres: Task<ToursClesLecture, Never>? = porte.libre
            ? Task { await Self.toursCles(cles) { prevues in Set(prevues.map(\.id)) } }
            : nil

        async let comptesLocaux = Decouverte.comptes()
        async let tablesEnVol = Correspondances.tables()
        async let etatClaude = LecteurProxy.lire(.claude)
        async let etatCodex = LecteurProxy.lire(.codex)
        async let identiteEnVol = FichierClaudeCode.lire()
        async let applicationsEnVol = Inventaire.applicationsDesFournisseurs()

        let (locaux, tables, claude, codex, identite, applications) =
            await (comptesLocaux, tablesEnVol, etatClaude, etatCodex, identiteEnVol, applicationsEnVol)
        consentement = consentement.restreint(a: consentementCourant())
        // Les autres `auth.json` de Codex : ceux des apps de compte et ceux que le proxy publie,
        // que seules les lectures précédentes font connaître. ⛔ Sans consentement à Codex, pas
        // même leur dossier n'est regardé.
        let sourcesCodex: [SourceCodex] = consentement[.chatgpt]
            ? await HorsFil.executer { [codex] in
                SourcesCodex.sources(locaux: locaux, proxyCodex: codex.etat, principal: lecteursCodex.principal())
            }
            : []
        consentement = consentement.restreint(a: consentementCourant())
        let supplementairesLibres: Task<[ReleveSourceCodex], Never>? = porte.libre
            ? Task { await SourcesCodex.relever(sourcesCodex, consentement: consentement, lire: lecteursCodex.relever) }
            : nil
        // Seules lectures qui ne peuvent pas partir avec les autres : les mesures de
        // disque sont celles des dossiers de données, et la découverte seule dit
        // lesquels existent. Elles restent hors du fil principal ; leur coût est borné —
        // quelques fichiers de moins de 35 Ko chez Claude, la queue des rollouts les plus
        // récents chez ChatGPT — et la publication anticipée les porte déjà, plutôt que
        // d'ouvrir le panneau sans elles.
        //
        // ⛔ Sous la limite, la porte ne lit que les historiques des lignes ouvertes : ceux de
        // Codex sont des transcriptions de session, et une ligne verrouillée n'a rien à relever.
        let prevoir: PorteEssai.Prevoir = { [locaux, claude, codex, identite, tables] releves, lus in
            Fusion.lignesEtCibles(comptesLocaux: locaux,
                                  proxyClaude: claude.etat,
                                  proxyCodex: codex.etat,
                                  releves: releves,
                                  historiques: lus.plans,
                                  rollouts: lus.rollouts,
                                  identite: identite,
                                  correspondances: tables.correspondances,
                                  courriels: tables.courriels,
                                  organisations: tables.organisations)
        }
        let (disque, etatsCles) = await porte.lireDisque(locaux: locaux, cles: cles, retenus: relevesRetenus,
                                                         consentement: consentement, identite: identite,
                                                         lire: Self.lireHistoriques, prevoir: prevoir)
        let (historiques, rollouts) = (disque.plans, disque.rollouts)
        if lignes.isEmpty {
            // `.indetermine` et non `.aucun` : les relevés directs sont encore en vol,
            // rien n'est établi de leur côté — surtout pas l'absence de session.
            publier(locaux: locaux, claude: claude, codex: codex, identite: identite,
                    consentement: consentement,
                    releves: .indeterminees,
                    historiques: historiques,
                    rollouts: rollouts,
                    applications: applications,
                    tables: tables,
                    cles: nil,
                    limite: limite,
                    complet: false)
        }

        let releves: RelevesDirects
        let toursCles: ToursClesLecture
        consentement = consentement.restreint(a: consentementCourant())
        if let tour = await porte.relever(consentement: consentement, retenus: relevesRetenus, identite: identite,
                                          cles: cles, etatsCles: etatsCles, disque: disque, lecteurs: lecteurs,
                                          sourcesCodex: sourcesCodex, codex: lecteursCodex, prevoir: prevoir) {
            relevesRetenus = tour.retenus
            releves = tour.affiches
            toursCles = tour.cles
        } else {
            relevesRetenus = .indeterminees
            var libres = await relevesLibres?.value ?? .indeterminees
            libres.chatgptFichiers = FichiersCodex(principal: consentement[.chatgpt] ? lecteursCodex.principal() : nil,
                                                   supplementaires: await supplementairesLibres?.value ?? [])
            releves = libres
            toursCles = await clesLibres?.value ?? .empechees
        }
        consentement = consentement.restreint(a: consentementCourant())
        let fin = Self.finDeTour(initial: initial, final: consentement, releves: releves, retenus: relevesRetenus)
        relevesRetenus = fin.retenus

        publier(locaux: locaux, claude: claude, codex: codex, identite: identite,
                consentement: consentement,
                releves: fin.publies,
                historiques: historiques,
                rollouts: rollouts,
                applications: applications,
                tables: tables,
                cles: toursCles,
                limite: limite,
                complet: true)
    }

    /// Ce qu'un tour publie et retient pour le suivant, une fois le consentement relu : un outil
    /// retiré ou révoqué en cours de route n'est ni publié ni retenu — un relevé retenu d'avant une
    /// révocation décrirait l'ancienne clé au tour suivant.
    nonisolated static func finDeTour(initial: ConsentementMesure,
                                      final: ConsentementMesure,
                                      releves: RelevesDirects,
                                      retenus: RelevesDirects) -> (publies: RelevesDirects, retenus: RelevesDirects) {
        let retires = Set(Fournisseur.allCases.filter { initial[$0] && !final[$0] })
        return (sansLesRetires(releves, retires), sansLesRetires(retenus, retires))
    }

    /// Ce qu'un tour a relevé pour un fournisseur dont le suivi a été retiré en cours de route
    /// ne se publie pas : rien n'est établi de son côté, comme s'il n'avait pas été lu.
    nonisolated static func sansLesRetires(_ releves: RelevesDirects, _ retires: Set<Fournisseur>) -> RelevesDirects {
        guard !retires.isEmpty else { return releves }
        var resultat = releves.remplacees(par: .indeterminees, pour: retires)
        if retires.contains(.chatgpt) { resultat.chatgptFichiers = .aucun }
        return resultat
    }

    /// Le Trousseau d'abord, sans le secret, pour les trois sources ; puis, ensemble, la requête
    /// de chaque source qui a une clé et dont la ligne sera ouverte. `ouvertes` reçoit toutes les
    /// lignes prévues à la fois, et les range ensemble, comme le panneau.
    nonisolated static func toursCles(_ cles: LecteursClesLecture,
                                      ouvertes: @Sendable ([Ligne]) -> Set<String>) async -> ToursClesLecture {
        await toursCles(cles, etats: await EtatsClesLecture.lire(cles), ouvertes: ouvertes)
    }

    /// `etats` déjà lus : la porte les regarde avant ses prévisions, et le même constat sert ici.
    nonisolated static func toursCles(_ cles: LecteursClesLecture,
                                      etats: EtatsClesLecture,
                                      ouvertes: @Sendable ([Ligne]) -> Set<String>) async -> ToursClesLecture {
        let (anthropic, aws, azure) = (etats.anthropic, etats.aws, etats.azure)
        let admises = ouvertes(etats.prevues)
        let suiviAnthropic = admises.contains(SourceCleLecture.anthropicEntreprise.identifiantCompte)
            ? anthropic.enregistrement : nil
        let suiviAWS = admises.contains(SourceCleLecture.awsBedrock.identifiantCompte) ? aws.enregistrement : nil
        let suiviAzure = admises.contains(SourceCleLecture.azureOpenAI.identifiantCompte) ? azure.enregistrement : nil

        async let releveAnthropic: ReleveCleAnthropic? = {
            guard let suiviAnthropic else { return nil }
            return await cles.releverAnthropic(suiviAnthropic)
        }()
        async let releveAWS: ReleveBudget? = {
            guard let suiviAWS else { return nil }
            return await cles.releverAWS(suiviAWS)
        }()
        async let releveAzure: ReleveBudget? = {
            guard let suiviAzure else { return nil }
            return await cles.releverAzure(suiviAzure)
        }()
        let (a, w, z) = await (releveAnthropic, releveAWS, releveAzure)
        return ToursClesLecture(anthropic: TourCleAnthropic(etat: anthropic, releve: a),
                                aws: TourCleAWS(etat: aws, releve: w),
                                azure: TourCleAzure(etat: azure, releve: z))
    }

    /// Les deux historiques de disque des comptes donnés, lus ensemble. ⛔ Le seul endroit qui
    /// appelle leurs lecteurs : la porte lui passe les comptes à lire.
    nonisolated static func lireHistoriques(_ comptes: [CompteLocal]) async -> HistoriquesDeDisque {
        async let plans = HistoriquePlanClaude.mesures(comptesLocaux: comptes)
        async let rollouts = HistoriqueRolloutCodex.mesures(comptesLocaux: comptes)
        return await HistoriquesDeDisque(plans: plans, rollouts: rollouts)
    }

    /// Les applications de bureau que Quotum sait ouvrir et dupliquer, telles qu'elles
    /// sont — ou non — dans `/Applications`. Le chemin vient de `CreationCompte`, seul
    /// endroit qui le compose : une seconde règle ici dériverait de lui au premier
    /// changement, et le panneau proposerait de nouveau d'installer l'installé.
    static func applicationsDesFournisseurs() async -> ApplicationsInstallees {
        await HorsFil.executer {
            let gestionnaire = FileManager.default
            return ApplicationsInstallees(Set(Fournisseur.allCases.filter { fournisseur in
                fournisseur.urlTelechargement != nil
                    && gestionnaire.fileExists(atPath: CreationCompte.applicationSource(fournisseur).path)
            }))
        }
    }

    /// ⛔ `historiques`, `rollouts`, `releves` et `applications` n'ont pas de valeur par
    /// défaut : c'est ce qui oblige l'appelant à dire ce que chaque lecteur a rendu. Un
    /// défaut à cet endroit laisse un lecteur écrit, testé, et jamais appelé — c'est
    /// arrivé deux fois sur ce projet, sans qu'aucun test puisse le voir.
    ///
    /// ⛔ `consentement` non plus : c'est lui qui distingue un lecteur qui s'est tu d'un
    /// lecteur qu'on n'a plus le droit d'appeler, et seul le second oublie l'argent gardé.
    func publier(locaux: [CompteLocal],
                 claude: LectureProxy,
                 codex: LectureProxy,
                 identite: IdentiteClaudeCode? = nil,
                 consentement: ConsentementMesure,
                 releves: RelevesDirects,
                 historiques: [String: [MesureHistoriquePlan]],
                 rollouts: [String: MesureRolloutCodex],
                 applications: ApplicationsInstallees,
                 tables: TablesCorrespondances = TablesCorrespondances(),
                 cles: ToursClesLecture?,
                 limite: LimiteComptes,
                 complet: Bool) {
        // Les tables arrivent lues : `publier` ne touche pas au disque, elle tourne sur
        // le fil principal. `rafraichir` les relit à chaque tour, hors de ce fil —
        // modifier `comptes.json` ne doit pas demander de redémarrer l'app.
        let fusion = Fusion.lignesEtCibles(comptesLocaux: locaux,
                                           proxyClaude: claude.etat,
                                           proxyCodex: codex.etat,
                                           releves: releves,
                                           historiques: historiques,
                                           rollouts: rollouts,
                                           identite: identite,
                                           correspondances: tables.correspondances,
                                           courriels: tables.courriels,
                                           organisations: tables.organisations)
        // Avant la porte : une ligne verrouillée perd ensuite toute mesure, gardée ou non.
        let (conservees, conserves) = usagesConserves.appliquer(a: fusion.lignes,
                                                                 cibles: fusion.cibles,
                                                                 releves: releves,
                                                                 consentement: consentement)
        usagesConserves = conserves
        var fusionnees = conservees
        // `nil` : la publication anticipée, où les clés n'ont pas encore été regardées.
        if let cles {
            for ligne in LignesCleLecture.lignes(cles, retenues: depensesRetenues) {
                fusionnees = LignesCleLecture.inserer(ligne, dans: fusionnees)
            }
            depensesRetenues = LignesCleLecture.retenues(cles, precedentes: depensesRetenues)
        }
        // ⛔ La porte s'applique ici, sur l'état publié, avant que quiconque le lise : les
        // alertes et le mode automatique ne voient d'une ligne verrouillée que son nom.
        (lignes, verrouillees) = PorteEssai.appliquer(limite, derniere: derniereLimite, a: fusionnees)
        lectureProxyClaude = claude
        lectureProxyCodex = codex
        applicationsInstallees = applications
        identiteClaudeCode = identite
        // Un appel qui n'a rien établi n'infirme rien : effacer la demande de `/login`
        // sur une coupure réseau la ferait disparaître sans qu'aucune reconnexion ait
        // eu lieu. Seuls un relevé obtenu ou un Trousseau vide la lèvent.
        switch releves.claude {
        case .reconnexionNecessaire: reconnexionClaudeCode = true
        case .releve, .aucun: reconnexionClaudeCode = false
        case .indetermine: break
        }
        derniereMiseAJour = .now
        if complet { lignesEtablies = lignes }
    }
}
