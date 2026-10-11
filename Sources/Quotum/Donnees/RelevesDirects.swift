import Foundation

/// Ce que les lecteurs directs ont rendu en un cycle — un champ par fournisseur, chacun
/// dans le type que son lecteur produit. Rien n'est unifié : la source d'identifiants, la
/// forme de réponse et l'ancre d'identité diffèrent d'un outil à l'autre, et ce sont
/// justement ces différences qui interdisent un protocole commun.
///
/// ⛔ **L'initialiseur n'a aucune valeur par défaut, et c'est toute sa raison d'être.** La
/// forme précédente — un paramètre optionnel par lecteur, tous à `.indetermine` faute de
/// mieux — laissait un lecteur écrit, testé et branché dans `Fusion` sans que rien ne
/// l'appelle : le code compilait, la suite entière passait au vert, et le compte n'était
/// jamais relevé. Ici, un lecteur oublié ne compile pas. Ne pas rendre ces champs
/// optionnels, ne pas leur donner de valeur par défaut.
struct RelevesDirects: Sendable, Equatable {
    var claude: ReleveTrousseau
    var chatgpt: ReleveCodex
    var windsurf: ResultatWindsurf
    var cursor: ResultatCursor
    var warp: ResultatWarp
    var codebuff: ReleveCodebuff
    var augment: ReleveAuggie
    var opencode: ReleveOpencode
    var grok: ReleveGrok
    var grokBot: ReleveGrokBot
    var copilot: ReleveCopilot
    var kiro: ReleveKiro
    var cline: ReleveClinePass
    var kimi: ReleveKimi
    var kilo: ReleveKilo
    var nous: ReleveNous
    var jetbrains: ReleveJetBrains
    var factory: ReleveFactory
    var muse: ReleveMuse
    var antigravity: ReleveAntigravity
    var doubao: ReleveDoubao
    var alibaba: ReleveAlibaba
    var amp: ReleveAmp
    var zai: ReleveZai
    var minimax: ReleveMiniMax
    /// Le fichier du relevé `chatgpt`, et les autres `auth.json` de Codex relevés ce cycle.
    var chatgptFichiers: FichiersCodex
}

extension RelevesDirects {
    /// Aucune lecture n'a rien établi. C'est l'état de la publication anticipée, où les
    /// relevés sont encore en vol : `.aucun` affirmerait qu'aucune session n'existe sur
    /// cette machine, ce que personne n'a encore constaté.
    static let indeterminees = RelevesDirects(claude: .indetermine,
                                              chatgpt: .indetermine,
                                              windsurf: .indetermine,
                                              cursor: .indetermine,
                                              warp: .indetermine,
                                              codebuff: .indetermine,
                                              augment: .indetermine,
                                              opencode: .indetermine,
                                              grok: .indetermine,
                                              grokBot: .indetermine,
                                              copilot: .indetermine,
                                              kiro: .indetermine,
                                              cline: .indetermine,
                                              kimi: .indetermine,
                                              kilo: .indetermine,
                                              nous: .indetermine,
                                              jetbrains: .indetermine,
                                              factory: .indetermine,
                                              muse: .indetermine,
                                              antigravity: .indetermine,
                                              doubao: .indetermine,
                                              alibaba: .indetermine,
                                              amp: .indetermine,
                                              zai: .indetermine,
                                              minimax: .indetermine,
                                              chatgptFichiers: .aucun)

    /// Le seul endroit où les lecteurs directs sont appelés.
    ///
    /// Ils partent tous ensemble : chacun lit un fichier ou une base puis appelle un
    /// serveur différent, et les enchaîner additionnerait leurs délais de garde au lieu
    /// d'attendre le plus lent.
    ///
    /// ⛔ Le consentement n'a **pas** de valeur par défaut, et ne doit pas en recevoir :
    /// un appelant qui l'oublierait relèverait tout, ce qui est exactement ce que ce
    /// paramètre existe pour empêcher.
    ///
    /// ⛔ Chacun des vingt-cinq passe par `sousConsentement`, qui nomme son fournisseur.
    /// Un `async let` posé ici sans ce passage lirait les identifiants d'un autre logiciel
    /// sans que personne l'ait armé — c'est le défaut que ce fichier existe pour rendre
    /// impossible : sans consentement, `sousConsentement` rend `.indetermine` sans appeler
    /// le lecteur ; avec lui, il l'appelle et rend ce qu'il a lu.
    static func relever(consentement: ConsentementMesure,
                        lecteurs: LecteursDirects) async -> RelevesDirects {
        async let claude = sousConsentement(.claude, consentement, lecteur: lecteurs.claude)
        async let chatgpt = sousConsentement(.chatgpt, consentement, lecteur: lecteurs.chatgpt)
        async let windsurf = sousConsentement(.windsurf, consentement, lecteur: lecteurs.windsurf)
        async let cursor = sousConsentement(.cursor, consentement, lecteur: lecteurs.cursor)
        async let warp = sousConsentement(.warp, consentement, lecteur: lecteurs.warp)
        async let codebuff = sousConsentement(.codebuff, consentement, lecteur: lecteurs.codebuff)
        async let augment = sousConsentement(.augment, consentement, lecteur: lecteurs.augment)
        async let opencode = sousConsentement(.opencode, consentement, lecteur: lecteurs.opencode)
        async let grok = sousConsentement(.grok, consentement, lecteur: lecteurs.grok)
        async let grokBot = sousConsentement(.grokBot, consentement, lecteur: lecteurs.grokBot)
        async let copilot = sousConsentement(.copilot, consentement, lecteur: lecteurs.copilot)
        async let kiro = sousConsentement(.kiro, consentement, lecteur: lecteurs.kiro)
        async let cline = sousConsentement(.cline, consentement, lecteur: lecteurs.cline)
        async let kimi = sousConsentement(.kimi, consentement, lecteur: lecteurs.kimi)
        async let kilo = sousConsentement(.kilo, consentement, lecteur: lecteurs.kilo)
        async let nous = sousConsentement(.nous, consentement, lecteur: lecteurs.nous)
        async let jetbrains = sousConsentement(.jetbrains, consentement, lecteur: lecteurs.jetbrains)
        async let factory = sousConsentement(.factory, consentement, lecteur: lecteurs.factory)
        async let muse = sousConsentement(.muse, consentement, lecteur: lecteurs.muse)
        async let antigravity = sousConsentement(.antigravity, consentement, lecteur: lecteurs.antigravity)
        async let doubao = sousConsentement(.doubao, consentement, lecteur: lecteurs.doubao)
        async let alibaba = sousConsentement(.alibaba, consentement, lecteur: lecteurs.alibaba)
        async let amp = sousConsentement(.amp, consentement, lecteur: lecteurs.amp)
        async let zai = sousConsentement(.zai, consentement, lecteur: lecteurs.zai)
        async let minimax = sousConsentement(.minimax, consentement, lecteur: lecteurs.minimax)

        return await RelevesDirects(claude: claude,
                                    chatgpt: chatgpt,
                                    windsurf: windsurf,
                                    cursor: cursor,
                                    warp: warp,
                                    codebuff: codebuff,
                                    augment: augment,
                                    opencode: opencode,
                                    grok: grok,
                                    grokBot: grokBot,
                                    copilot: copilot,
                                    kiro: kiro,
                                    cline: cline,
                                    kimi: kimi,
                                    kilo: kilo,
                                    nous: nous,
                                    jetbrains: jetbrains,
                                    factory: factory,
                                    muse: muse,
                                    antigravity: antigravity,
                                    doubao: doubao,
                                    alibaba: alibaba,
                                    amp: amp,
                                    zai: zai,
                                    minimax: minimax,
                                    // Les autres `auth.json` de Codex dépendent des apps de compte
                                    // et du proxy, que seul l'inventaire a lus : il les y pose.
                                    chatgptFichiers: .aucun)
    }

    /// ⛔ Sans consentement, le lecteur n'est **pas appelé du tout** : aucun jeton n'est
    /// demandé au Trousseau, aucun fichier d'identifiants n'est ouvert, aucune requête
    /// n'est émise. C'est là que se tient la promesse du produit, et c'est pourquoi le
    /// lecteur arrive par paramètre — la preuve se fait alors sans toucher au Trousseau
    /// ni au disque de la machine qui la lance.
    ///
    /// `.indetermine` est l'état de qui n'a pas regardé. `.aucun` affirmerait qu'il n'y
    /// a pas de session sur cette machine, ce que personne n'a constaté.
    static func sousConsentement<Mesure: ReleveDirecte>(
        _ fournisseur: Fournisseur,
        _ consentement: ConsentementMesure,
        lecteur: @Sendable () async -> Mesure
    ) async -> Mesure {
        guard consentement[fournisseur] else { return .indetermine }
        return await lecteur()
    }
}

/// Ce que rend un lecteur que personne n'a armé. Les vingt-cinq états de lecteur le
/// savent déjà dire — le protocole ne fait que le rendre exigible par la garde, pour
/// qu'elle n'ait pas à recevoir cette valeur en paramètre à vingt-cinq endroits où elle
/// pourrait être mal choisie.
protocol ReleveDirecte: Sendable {
    static var indetermine: Self { get }
}

extension ReleveTrousseau: ReleveDirecte {}
extension ReleveCodex: ReleveDirecte {}
extension ResultatWindsurf: ReleveDirecte {}
extension ResultatCursor: ReleveDirecte {}
extension ResultatWarp: ReleveDirecte {}
extension ReleveCodebuff: ReleveDirecte {}
extension ReleveAuggie: ReleveDirecte {}
extension ReleveOpencode: ReleveDirecte {}
extension ReleveGrok: ReleveDirecte {}
extension ReleveGrokBot: ReleveDirecte {}
extension ReleveCopilot: ReleveDirecte {}
extension ReleveKiro: ReleveDirecte {}
extension ReleveClinePass: ReleveDirecte {}
extension ReleveKimi: ReleveDirecte {}
extension ReleveKilo: ReleveDirecte {}
extension ReleveNous: ReleveDirecte {}
extension ReleveJetBrains: ReleveDirecte {}
extension ReleveFactory: ReleveDirecte {}
extension ReleveMuse: ReleveDirecte {}
extension ReleveAntigravity: ReleveDirecte {}
extension ReleveDoubao: ReleveDirecte {}
extension ReleveAlibaba: ReleveDirecte {}
extension ReleveAmp: ReleveDirecte {}
extension ReleveZai: ReleveDirecte {}
extension ReleveMiniMax: ReleveDirecte {}

/// Les vingt-cinq lecteurs, tels que `relever` les appelle.
///
/// ⛔ **Aucune valeur par défaut, comme les champs de `RelevesDirects`, et pour la même
/// raison** : un lecteur ajouté ne compile pas tant que personne n'a dit lequel appeler.
/// C'est aussi ce qui rend la preuve possible sans réseau ni disque — chaque lecteur se
/// remplace par un témoin, et l'on constate lesquels ont été appelés.
struct LecteursDirects: Sendable {
    var claude: @Sendable () async -> ReleveTrousseau
    var chatgpt: @Sendable () async -> ReleveCodex
    var windsurf: @Sendable () async -> ResultatWindsurf
    var cursor: @Sendable () async -> ResultatCursor
    var warp: @Sendable () async -> ResultatWarp
    var codebuff: @Sendable () async -> ReleveCodebuff
    var augment: @Sendable () async -> ReleveAuggie
    var opencode: @Sendable () async -> ReleveOpencode
    var grok: @Sendable () async -> ReleveGrok
    var grokBot: @Sendable () async -> ReleveGrokBot
    var copilot: @Sendable () async -> ReleveCopilot
    var kiro: @Sendable () async -> ReleveKiro
    var cline: @Sendable () async -> ReleveClinePass
    var kimi: @Sendable () async -> ReleveKimi
    var kilo: @Sendable () async -> ReleveKilo
    var nous: @Sendable () async -> ReleveNous
    var jetbrains: @Sendable () async -> ReleveJetBrains
    var factory: @Sendable () async -> ReleveFactory
    var muse: @Sendable () async -> ReleveMuse
    var antigravity: @Sendable () async -> ReleveAntigravity
    var doubao: @Sendable () async -> ReleveDoubao
    var alibaba: @Sendable () async -> ReleveAlibaba
    var amp: @Sendable () async -> ReleveAmp
    var zai: @Sendable () async -> ReleveZai
    var minimax: @Sendable () async -> ReleveMiniMax

    static let reels = LecteursDirects(claude: { await QuotaAnthropic.relever() },
                                       chatgpt: { await QuotaCodex.relever() },
                                       windsurf: { await QuotaWindsurf.relever() },
                                       cursor: { await QuotaCursor.relever() },
                                       warp: { await QuotaWarp.relever() },
                                       codebuff: { await QuotaCodebuff.relever() },
                                       augment: { await QuotaAugment.relever() },
                                       opencode: { await QuotaOpencode.relever() },
                                       grok: { await QuotaGrok.relever() },
                                       grokBot: { await QuotaGrokBot.relever() },
                                       copilot: { await QuotaCopilot.relever() },
                                       kiro: { await QuotaKiro.relever() },
                                       cline: { await QuotaClinePass.relever() },
                                       kimi: {
                                           await QuotaKimi.relever(accueil: FileManager.default.homeDirectoryForCurrentUser,
                                                                   environnement: ProcessInfo.processInfo.environment,
                                                                   session: Reseau.session,
                                                                   maintenant: Date(),
                                                                   delai: 8)
                                       },
                                       kilo: {
                                           await QuotaKilo.relever(
                                               fichier: IdentifiantsKilo.fichier(environnement: ProcessInfo.processInfo.environment,
                                                                                 accueil: FileManager.default.homeDirectoryForCurrentUser),
                                               session: Reseau.session,
                                               delai: 8)
                                       },
                                       nous: { await QuotaNous.relever(sources: .poste, session: Reseau.session, delai: 8) },
                                       jetbrains: {
                                           await QuotaJetBrains.relever(accueil: FileManager.default.homeDirectoryForCurrentUser,
                                                                        disque: .reel)
                                       },
                                       factory: {
                                           await QuotaFactory.relever(
                                               dossier: IdentifiantsFactory.dossier(accueil: FileManager.default.homeDirectoryForCurrentUser),
                                               cleTrousseau: IdentifiantsFactory.cleParTrousseau,
                                               session: Reseau.session)
                                       },
                                       muse: { await ReleveurMuse.systeme.relever() },
                                       antigravity: { await OutilsCLI.releverAntigravity() },
                                       doubao: { await OutilsCLI.releverDoubao() },
                                       alibaba: { await OutilsCLI.releverAlibaba() },
                                       amp: { await OutilsCLI.releverAmp() },
                                       zai: { await LectureCleCollee.systeme.releverZai(session: Reseau.session, delai: 8) },
                                       minimax: { await LectureCleCollee.systeme.releverMiniMax(session: Reseau.session, delai: 8) })
}

// MARK: - Les mesures, quand il y en a une

/// Seul `.releve` porte une mesure. `.reconnexionNecessaire`, `.indetermine` et `.aucun`
/// n'établissent rien du niveau — les traduire en quota vide afficherait à sec un compte
/// dont on ignore tout.
extension RelevesDirects {
    var mesureClaude: ReleveAnthropic? {
        guard case .releve(let mesure) = claude else { return nil }
        return mesure
    }

    var mesureChatgpt: ReleveChatGPT? {
        guard case .releve(let mesure) = chatgpt else { return nil }
        return mesure
    }

    var mesureWindsurf: ReleveWindsurf? {
        guard case .releve(let mesure) = windsurf else { return nil }
        return mesure
    }

    var mesureCursor: ReleveCursor? {
        guard case .releve(let mesure) = cursor else { return nil }
        return mesure
    }

    var mesureWarp: ReleveWarp? {
        guard case .releve(let mesure) = warp else { return nil }
        return mesure
    }

    var mesureCodebuff: MesureCodebuff? {
        guard case .releve(let mesure) = codebuff else { return nil }
        return mesure
    }

    var mesureAugment: ReleveAugment? {
        guard case .releve(let mesure) = augment else { return nil }
        return mesure
    }

    var mesureOpencode: MesureOpencode? {
        guard case .releve(let mesure) = opencode else { return nil }
        return mesure
    }

    var mesureGrok: MesureGrok? {
        guard case .releve(let mesure) = grok else { return nil }
        return mesure
    }

    var mesureGrokBot: MesureGrokBot? {
        guard case .releve(let mesure) = grokBot else { return nil }
        return mesure
    }

    var mesureCopilot: MesureCopilot? {
        guard case .releve(let mesure) = copilot else { return nil }
        return mesure
    }

    var mesureKiro: MesureKiro? {
        guard case .releve(let mesure) = kiro else { return nil }
        return mesure
    }

    var mesureCline: MesureClinePass? {
        guard case .releve(let mesure) = cline else { return nil }
        return mesure
    }

    var mesureKimi: MesureKimi? {
        guard case .releve(let mesure) = kimi else { return nil }
        return mesure
    }

    var mesureKilo: MesureKilo? {
        guard case .releve(let mesure) = kilo else { return nil }
        return mesure
    }

    var mesureNous: MesureNous? {
        guard case .releve(let mesure) = nous else { return nil }
        return mesure
    }

    var mesureJetBrains: MesureJetBrains? {
        guard case .releve(let mesure) = jetbrains else { return nil }
        return mesure
    }

    var mesureFactory: MesureFactory? {
        guard case .releve(let mesure) = factory else { return nil }
        return mesure
    }

    var mesureMuse: MesureMuse? {
        guard case .releve(let mesure) = muse else { return nil }
        return mesure
    }

    var mesureAntigravity: MesureAntigravity? {
        guard case .releve(let mesure) = antigravity else { return nil }
        return mesure
    }

    var mesureDoubao: MesureDoubao? {
        guard case .releve(let mesure) = doubao else { return nil }
        return mesure
    }

    var mesureAlibaba: MesureAlibaba? {
        guard case .releve(let mesure) = alibaba else { return nil }
        return mesure
    }

    var mesureAmp: MesureAmp? {
        guard case .releve(let mesure) = amp else { return nil }
        return mesure
    }

    var mesureZai: MesureZai? {
        guard case .releve(let mesure) = zai else { return nil }
        return mesure
    }

    var mesureMiniMax: MesureMiniMax? {
        guard case .releve(let mesure) = minimax else { return nil }
        return mesure
    }
}

// MARK: - Ce qu'un lecteur sans mesure sait quand même dire

extension RelevesDirects {
    /// Seuls les états qui **constatent** quelque chose produisent une cause : un jeton
    /// refusé, une formule qui n'ouvre pas la route. ⛔ `.aucun` et `.indetermine` n'en
    /// produisent aucune — le premier dit que l'outil n'est pas sur cette machine, le
    /// second qu'on n'a rien appris, et fabriquer une ligne pour l'un ou l'autre
    /// inventerait un compte.
    ///
    /// ⚠️ Le `switch` sur `Fournisseur` est le second verrou du câblage : un fournisseur
    /// déclaré sans lecteur cesse de compiler ici, le champ qu'il réclame oblige à son
    /// tour l'initialiseur à le porter, et l'initialiseur oblige `relever()` à l'appeler.
    func cause(de fournisseur: Fournisseur) -> Cause? {
        switch fournisseur {
        case .claude: Self.cause(de: claude)
        case .chatgpt: Self.cause(de: chatgpt)
        case .windsurf: Self.cause(de: windsurf)
        case .cursor: Self.cause(de: cursor)
        case .warp: Self.cause(de: warp)
        case .codebuff: Self.cause(de: codebuff)
        case .augment: Self.cause(de: augment)
        case .opencode: Self.cause(de: opencode)
        case .grok: Self.cause(de: grok)
        case .grokBot: Self.cause(de: grokBot)
        case .copilot: Self.cause(de: copilot)
        case .kiro: Self.cause(de: kiro)
        case .cline: Self.cause(de: cline)
        case .kimi: Self.cause(de: kimi)
        case .kilo: Self.cause(de: kilo)
        case .nous: Self.cause(de: nous)
        case .jetbrains: Self.cause(de: jetbrains)
        case .factory: Self.cause(de: factory)
        case .muse: Self.cause(de: muse)
        case .antigravity: Self.cause(de: antigravity)
        case .doubao: Self.cause(de: doubao)
        case .alibaba: Self.cause(de: alibaba)
        case .amp: Self.cause(de: amp)
        case .zai: Self.cause(de: zai)
        case .minimax: Self.cause(de: minimax)
        }
    }

    /// Ce que le lecteur savait du compte avant que la route se ferme : Grok lit son
    /// organisation sur le disque, et un 412 ou un 426 ne la rend pas moins vraie. Sans
    /// elle, la ligne changerait d'identifiant et perdrait nom personnalisé et masquage.
    func organisationSansMesure(de fournisseur: Fournisseur) -> String? {
        guard fournisseur == .grok else { return nil }
        switch grok {
        case .sansEquipePersonnelle(let organisation), .clientRefuse(let organisation): return organisation
        case .releve, .reconnexionNecessaire, .indetermine, .aucun: return nil
        }
    }

    /// Les onze sont écrits en `switch` exhaustif : un état ajouté à un lecteur cesse de
    /// compiler tant que personne n'a dit ce qu'il vaut ici.
    private static func cause(de trousseau: ReleveTrousseau) -> Cause? {
        switch trousseau {
        case .reconnexionNecessaire: .authentification
        case .releve, .indetermine, .aucun: nil
        }
    }

    private static func cause(de fichierCodex: ReleveCodex) -> Cause? {
        switch fichierCodex {
        case .reconnexionNecessaire: .authentification
        case .horsDePortee(let empechement, _): empechement.cause
        case .releve, .indetermine, .aucun: nil
        }
    }

    private static func cause(de resultat: ResultatWindsurf) -> Cause? {
        switch resultat {
        case .reconnexionNecessaire: .authentification
        case .releve, .indetermine, .aucun: nil
        }
    }

    private static func cause(de resultat: ResultatCursor) -> Cause? {
        switch resultat {
        case .reconnexionNecessaire: .authentification
        case .releve, .indetermine, .aucun: nil
        }
    }

    private static func cause(de resultat: ResultatWarp) -> Cause? {
        switch resultat {
        case .reconnexionNecessaire: .authentification
        case .releve, .indetermine, .aucun: nil
        }
    }

    private static func cause(de resultat: ReleveCodebuff) -> Cause? {
        switch resultat {
        case .reconnexionNecessaire: .authentification
        case .releve, .indetermine, .aucun: nil
        }
    }

    private static func cause(de resultat: ReleveAuggie) -> Cause? {
        switch resultat {
        case .reconnexionNecessaire: .authentification
        case .releve, .indetermine, .aucun: nil
        }
    }

    /// opencode est le seul à distinguer une clé refusée d'une clé valable hors
    /// abonnement : la seconde ne se règle par aucune reconnexion.
    private static func cause(de resultat: ReleveOpencode) -> Cause? {
        switch resultat {
        case .reconnexionNecessaire: .authentification
        case .sansAbonnement: .abonnement
        case .releve, .indetermine, .aucun: nil
        }
    }

    /// Le 412 vient d'un compte d'équipe ou d'entreprise, déjà abonné, que la route ne sait
    /// pas lire : ni la clé ni la formule n'y sont pour rien. Le 426 refuse le client
    /// lui-même ; « Injoignable » est le plus juste des libellés existants — la route ne
    /// répondra pas, et rien n'est à refaire de ce côté.
    private static func cause(de resultat: ReleveGrok) -> Cause? {
        switch resultat {
        case .reconnexionNecessaire: .authentification
        case .sansEquipePersonnelle: .mesureIndisponible
        case .clientRefuse: .reseau
        case .releve, .indetermine, .aucun: nil
        }
    }

    /// Grok Bot ne déclare aucun refus pour quota : son dépassement passe par l'usage à la
    /// demande, facturé en dollars, que cette route ne publie pas. Seule une reconnexion se
    /// constate.
    private static func cause(de resultat: ReleveGrokBot) -> Cause? {
        switch resultat {
        case .reconnexionNecessaire: .authentification
        case .releve, .indetermine, .aucun: nil
        }
    }

    private static func cause(de resultat: ReleveCopilot) -> Cause? {
        switch resultat {
        case .reconnexionNecessaire: .authentification
        case .releve, .indetermine, .aucun: nil
        }
    }

    /// Le 400 sans profil vient d'un compte d'organisation : la connexion est bonne, c'est
    /// l'offre qui ferme la route tant que le profil manque.
    private static func cause(de resultat: ReleveKiro) -> Cause? {
        switch resultat {
        case .reconnexionNecessaire: .authentification
        case .profilManquant: .abonnement
        case .releve, .indetermine, .aucun: nil
        }
    }

    private static func cause(de resultat: ReleveClinePass) -> Cause? {
        switch resultat {
        case .reconnexionNecessaire: .authentification
        case .releve, .indetermine, .aucun: nil
        }
    }

    /// Le jeton du CLI `kimi` dure un quart d'heure et Quotum ne le renouvelle jamais : une
    /// échéance passée ne demande pas de se reconnecter, seulement de relancer l'outil. Un 400
    /// ou un 403 sur un jeton valable vient de la route, qu'aucune reconnexion ne rouvre.
    private static func cause(de resultat: ReleveKimi) -> Cause? {
        switch resultat {
        case .jetonExpire: .connexionExpiree
        case .reconnexionNecessaire: .authentification
        case .mesureRefusee: .mesureIndisponible
        case .releve, .indetermine, .aucun: nil
        }
    }

    /// Sans Kilo Pass, le compte n'a que des crédits : aucune fenêtre à jauger, et une
    /// reconnexion n'y changerait rien.
    private static func cause(de resultat: ReleveKilo) -> Cause? {
        switch resultat {
        case .reconnexionNecessaire: .authentification
        case .sansAbonnement: .abonnement
        case .releve, .indetermine, .aucun: nil
        }
    }

    /// Le jeton d'Hermes expiré ou refusé ne se renouvelle qu'en rouvrant Hermes : c'est le
    /// `nomApplication` de Nous Portal que la feuille d'ajout nomme.
    private static func cause(de resultat: ReleveNous) -> Cause? {
        switch resultat {
        case .reconnexionNecessaire: .connexionExpiree
        case .releve, .indetermine, .aucun: nil
        }
    }

    /// Un fichier que l'IDE n'écrit plus ne se constate pas : il vieillit, et l'âge le dit.
    private static func cause(de resultat: ReleveJetBrains) -> Cause? {
        switch resultat {
        case .releve, .indetermine, .aucun: nil
        }
    }

    /// Le jeton d'accès de `droid` vit peu, et seul `droid` le renouvelle : un refus est le cas
    /// ordinaire d'un outil resté fermé, qu'on règle en le relançant.
    private static func cause(de resultat: ReleveFactory) -> Cause? {
        switch resultat {
        case .reconnexionNecessaire: .connexionExpiree
        case .releve, .indetermine, .aucun: nil
        }
    }

    /// `.differe` n'arrive jamais ici : `ReleveurMuse` le remplace par la dernière mesure.
    /// Un abonnement qui attend son paiement n'ouvre pas plus la mesure qu'une absence
    /// d'abonnement.
    private static func cause(de resultat: ReleveMuse) -> Cause? {
        switch resultat {
        case .reconnexionNecessaire: .authentification
        case .sansAbonnement, .paiementRequis: .abonnement
        case .releve, .differe, .indetermine, .aucun: nil
        }
    }

    /// Une version d'`agy` trop ancienne pourrait consommer du quota pour le mesurer : rien
    /// ne part, et la mesure reste indisponible tant qu'elle n'est pas mise à jour. Un binaire
    /// refusé par le lanceur ne se lance pas davantage.
    private static func cause(de resultat: ReleveAntigravity) -> Cause? {
        switch resultat {
        case .versionNonAdmise, .binaireRefuse: .mesureIndisponible
        case .releve, .indetermine, .aucun: nil
        }
    }

    private static func cause(de resultat: ReleveDoubao) -> Cause? {
        switch resultat {
        case .reconnexionNecessaire: .authentification
        case .aucuneOffre: .abonnement
        case .releve, .indetermine, .absent: nil
        }
    }

    /// Une sortie lisible sans fenêtre — un pool de crédits d'équipe, des parts sans échéance —
    /// vient d'un compte connecté que la commande ne sait pas jauger.
    private static func cause(de resultat: ReleveAlibaba) -> Cause? {
        switch resultat {
        case .reconnexionNecessaire: .authentification
        case .aucuneFenetre: .mesureIndisponible
        case .releve, .indetermine, .absent: nil
        }
    }

    /// Un code non nul ne dit pas pourquoi — compte déconnecté, panne réseau, version qui ne
    /// connaît pas la sous-commande : rien ne se constate.
    private static func cause(de resultat: ReleveAmp) -> Cause? {
        switch resultat {
        case .releve, .binaireIntrouvable, .echecCommande, .delaiDepasse, .refusee, .illisible, .indetermine: nil
        }
    }

    /// Une clé refusée ne se règle qu'en en collant une nouvelle dans Quotum. Le compte sans
    /// forfait de codage a une clé valable : c'est la route du relevé qui n'a rien à lire.
    private static func cause(de resultat: ReleveZai) -> Cause? {
        switch resultat {
        case .cleRefusee: .cleRefusee
        case .sansForfait: .mesureIndisponible
        case .releve, .indetermine, .sansCle: nil
        }
    }

    private static func cause(de resultat: ReleveMiniMax) -> Cause? {
        switch resultat {
        case .cleRefusee: .cleRefusee
        case .releve, .indetermine, .sansCle: nil
        }
    }
}

// MARK: - Les outils suivis par une clé collée

/// Ce qu'une lecture de clé collée doit rendre selon ce que le Trousseau et le suivi disent.
/// Chaque lecteur garde son propre type : seuls ces trois états sont communs.
struct IssuesCleCollee<Releve: Sendable>: Sendable {
    let sansCle: Releve
    let indetermine: Releve
}

/// La lecture des outils suivis par une clé collée (Z.ai, MiniMax) : la clé du Trousseau de
/// Quotum, puis la requête, encadrée de revalidations.
///
/// ⛔ Double porte : le suivi de l'outil **et** une clé présente. L'autorisation lue au départ est
/// confrontée au consentement courant avant la lecture du secret, avant l'envoi et avant de rendre
/// la réponse ; la génération de la clé, avant l'envoi et après. Le consentement se relit **après**
/// chaque attente du Trousseau : une lecture d'attribut restituée en retard ne couvre pas un
/// retrait fait pendant qu'elle attendait. Un retrait, un remplacement de clé ou un suivi coupé
/// puis réarmé compte comme une révocation, et rien de ce qui a été autorisé avant ne part plus.
struct LectureCleCollee: Sendable {
    let magasin: MagasinClesOutil
    /// Le consentement courant, révocations comprises, relu à chaque revalidation et dans le travail
    /// qui lit le secret : il se lit donc sans attente, depuis n'importe quel fil. Aucune valeur par
    /// défaut.
    let consentementCourant: @Sendable () -> ConsentementMesure

    static let systeme = LectureCleCollee(magasin: .systeme, consentementCourant: { MiroirConsentement.systeme.lire() })

    func releverZai(session: URLSession, delai: TimeInterval) async -> ReleveZai {
        await relever(.zai, .zai, issues: IssuesCleCollee(sansCle: .sansCle, indetermine: .indetermine)) { cle, region in
            await QuotaZai.relever(cle: cle, region: region, session: session, delai: delai)
        }
    }

    func releverMiniMax(session: URLSession, delai: TimeInterval) async -> ReleveMiniMax {
        await relever(.minimax, .minimax,
                      issues: IssuesCleCollee(sansCle: .sansCle, indetermine: .indetermine)) { cle, region in
            await QuotaMiniMax.relever(cle: cle, region: region, session: session, delai: delai)
        }
    }

    func relever<Releve: Sendable>(_ outil: OutilCle,
                                   _ fournisseur: Fournisseur,
                                   issues: IssuesCleCollee<Releve>,
                                   demander: @Sendable (CleOutil, RegionCleOutil) async -> Releve) async -> Releve {
        let accord = consentementCourant()
        guard accord[fournisseur] else { return issues.indetermine }
        let attribut: AttributCleOutil
        switch await magasin.attribut(outil) {
        case .absente: return issues.sansCle
        case .empechee: return issues.indetermine
        case .presente(let lu): attribut = lu
        }
        guard toujoursAutorise(fournisseur, accord) else {
            Journal.donnees.notice("Clé \(outil.nom) : suivi changé avant la lecture du secret, rien n'est lu")
            return issues.indetermine
        }
        let cle: CleOutil
        let consentement = consentementCourant
        switch await magasin.secret(outil, si: { accord.restreint(a: consentement())[fournisseur] }) {
        case nil:
            Journal.donnees.notice("Clé \(outil.nom) : suivi changé avant l'accès au Trousseau, rien n'est lu")
            return issues.indetermine
        case .absente: return issues.sansCle
        case .empechee: return issues.indetermine
        case .presente(let lue): cle = lue
        }
        guard await toujoursValable(outil, fournisseur, accord, generation: attribut.generation) else {
            Journal.donnees.notice("Clé \(outil.nom) : suivi ou clé changés avant l'envoi, rien ne part")
            return issues.indetermine
        }
        let releve = await demander(cle, attribut.region)
        guard await toujoursValable(outil, fournisseur, accord, generation: attribut.generation) else {
            Journal.donnees.notice("Clé \(outil.nom) : suivi ou clé changés pendant la requête, réponse jetée")
            return issues.indetermine
        }
        return releve
    }

    private func toujoursAutorise(_ fournisseur: Fournisseur, _ accord: ConsentementMesure) -> Bool {
        accord.restreint(a: consentementCourant())[fournisseur]
    }

    /// La génération d'abord, le consentement en dernier : c'est lui que l'utilisateur retire, et
    /// il doit être lu après la dernière attente.
    private func toujoursValable(_ outil: OutilCle, _ fournisseur: Fournisseur, _ accord: ConsentementMesure,
                                 generation: UUID) async -> Bool {
        guard case .presente(let courant) = await magasin.attribut(outil),
              courant.generation == generation else { return false }
        return toujoursAutorise(fournisseur, accord)
    }
}
