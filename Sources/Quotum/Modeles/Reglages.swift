import Foundation

enum AffichageBarre: String, Codable, Sendable, CaseIterable {
    case icone, iconeEtPourcentage, iconeEtCompte

    var libelle: String {
        switch self {
        case .icone: Mots.dit("Icône seule")
        case .iconeEtPourcentage: Mots.dit("Icône + %")
        case .iconeEtCompte: Mots.dit("Icône + compte")
        }
    }
}

/// L'apparence de tout ce que Quotum affiche. `automatique` n'impose rien : c'est macOS
/// qui décide, et une bascule du Mac se suit sans relancer l'app.
enum Apparence: String, Codable, Sendable, CaseIterable {
    case clair, sombre, automatique

    var libelle: String {
        switch self {
        case .clair: Mots.dit("Clair")
        case .sombre: Mots.dit("Sombre")
        case .automatique: Mots.dit("Automatique")
        }
    }
}

/// Le terminal dans lequel « Épingler mon terminal ici » ouvre la session.
///
/// ⚠️ Cette liste est un **poste de coût**, pas un catalogue : chacun réclame son
/// adaptateur de lancement et deux validations — application fermée, application déjà
/// ouverte. Ghostty et Warp en sont volontairement absents : le premier demande un
/// AppleScript qui lui est propre, le second un second script temporaire et une URL
/// `warp://`, et ni l'un ni l'autre n'a été mesuré ici.
enum TerminalCible: String, Codable, Sendable, CaseIterable {
    case terminal, iterm2, kitty, alacritty, wezterm

    var libelle: String {
        switch self {
        case .terminal: "Terminal"
        case .iterm2: "iTerm2"
        case .kitty: "kitty"
        case .alacritty: "Alacritty"
        case .wezterm: "WezTerm"
        }
    }

    /// Ce qui dit si le terminal est installé, et ce que `open -b` vise. Le nom de
    /// l'application ne conviendrait pas : il se localise et se renomme, l'identifiant
    /// de bundle non.
    var identifiantBundle: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm2: "com.googlecode.iterm2"
        case .kitty: "net.kovidgoyal.kitty"
        case .alacritty: "org.alacritty"
        case .wezterm: "com.github.wez.wezterm"
        }
    }
}

/// Ce que l'utilisateur a armé pour la mesure par jeton, fournisseur par fournisseur.
///
/// Dix décisions et non une : dix fournisseurs, dix jetons, dix conditions
/// d'utilisation, et accepter l'un n'engage aucun des autres.
///
/// ⛔ Un ensemble de `Fournisseur`, et non un booléen par fournisseur. Dix champs
/// nommés à la main seraient neuf occasions d'en oublier un — au décodage, à la
/// recopie, à la garde. Ici le domaine est `Fournisseur` lui-même : un fournisseur
/// ajouté demain a sa décision du seul fait d'exister, et elle vaut « non armé ».
struct ConsentementMesure: Sendable, Equatable {
    private var armes: Set<Fournisseur>

    init(_ armes: Set<Fournisseur> = []) { self.armes = armes }

    /// L'état d'une installation neuve, et celui de qui a répondu « Pas maintenant ».
    static let aucun = ConsentementMesure()

    subscript(fournisseur: Fournisseur) -> Bool {
        get { armes.contains(fournisseur) }
        set {
            if newValue { armes.insert(fournisseur) } else { armes.remove(fournisseur) }
        }
    }

    var nombreArmes: Int { armes.count }

    /// Ce qui reste autorisé des deux côtés : un suivi retiré en cours de route ne revient pas.
    func restreint(a autre: ConsentementMesure) -> ConsentementMesure {
        ConsentementMesure(armes.intersection(autre.armes))
    }
}

/// Ce qu'un relevé par jeton prend à l'utilisateur, fournisseur par fournisseur : la
/// source d'identifiants qu'il ouvre, et le serveur qu'il appelle.
///
/// ⚠️ Un `switch` exhaustif, jamais une table écrite à la main : un fournisseur ajouté
/// cesse de compiler ici tant que personne n'a dit ce qu'on lui prend — et c'est ce
/// texte-là que l'utilisateur lit avant d'armer.
enum MesureParJeton {
    /// Ce que Quotum prend à l'outil pour le mesurer.
    enum Nature: Sendable, Equatable {
        /// Sa connexion, relue à chaque mesure.
        case connexion
        /// Un fichier où l'outil écrit lui-même son quota, sans connexion.
        case fichierDeQuota
        /// Rien : son CLI officiel est lancé, en lecture seule, et interroge son serveur.
        case outilLance
    }

    struct Description: Identifiable, Sendable, Equatable {
        let fournisseur: Fournisseur
        /// La source d'identifiants, par son chemin réel sur ce Mac.
        let chemin: String
        /// Ce qui est lu et ce qui est appelé, du point de vue de qui arme.
        let detail: String
        var id: String { fournisseur.rawValue }

        var nature: Nature {
            switch fournisseur {
            case .jetbrains: .fichierDeQuota
            case .antigravity, .doubao, .alibaba, .amp: .outilLance
            case .claude, .chatgpt, .windsurf, .cursor, .warp, .codebuff, .augment, .opencode, .grok, .grokBot,
                 .copilot, .kiro, .cline, .kimi, .kilo, .nous, .factory, .muse: .connexion
            }
        }
    }

    static func description(de fournisseur: Fournisseur) -> Description {
        switch fournisseur {
        case .claude:
            Description(fournisseur: fournisseur,
                        chemin: Mots.dit("Trousseau · « %1$@ »", Trousseau.serviceClaudeCode),
                        detail: Mots.dit("Connexion du Trousseau · deux requêtes à api.anthropic.com"))
        case .chatgpt:
            Description(fournisseur: fournisseur,
                        chemin: "<CODEX_HOME>/auth.json",
                        // La seconde requête est celle de la mesure par jeton personnel
                        // (`QuotaCodexJetonPersonnel`) : la route d'identité d'OpenAI.
                        detail: Mots.dit("Les connexions de Codex : ~/.codex/auth.json ou $CODEX_HOME, le CODEX_HOME de chaque app de compte, et le dossier que publie un proxy local · une requête à chatgpt.com par fichier auth.json lu, un même dossier une seule fois, plus une à auth.openai.com pour une clé d'accès personnelle · et, quand vous dépliez le tiroir d'un compte, deux lectures à chatgpt.com : sa réserve de réinitialisations et leur historique"))
        case .windsurf:
            Description(fournisseur: fournisseur,
                        chemin: "~/Library/…/Windsurf/…/state.vscdb · ~/.local/share/devin/credentials.toml",
                        detail: Mots.dit("Clé de l'éditeur · une requête au serveur déclaré "
                            + "dans ce fichier, chez codeium.com, windsurf.com ou devin.ai"))
        case .cursor:
            Description(fournisseur: fournisseur,
                        chemin: "~/Library/…/Cursor/…/state.vscdb",
                        detail: Mots.dit("Connexion de la base de l'éditeur · une requête à cursor.com"))
        case .warp:
            Description(fournisseur: fournisseur,
                        chemin: Mots.dit("Trousseau · « %1$@ »", IdentifiantsWarp.serviceApplication),
                        detail: Mots.dit("Connexion du Trousseau · une requête à app.warp.dev"))
        case .codebuff:
            Description(fournisseur: fournisseur,
                        chemin: "~/.config/manicode/credentials.json",
                        detail: Mots.dit("Connexion de ~/.config/manicode/credentials.json · une "
                            + "requête à www.codebuff.com"))
        case .augment:
            Description(fournisseur: fournisseur,
                        chemin: "~/.augment/session.json",
                        detail: Mots.dit("Connexion de ~/.augment/session.json · une requête à votre "
                            + "espace augmentcode.com"))
        case .opencode:
            Description(fournisseur: fournisseur,
                        chemin: "~/.local/share/opencode/auth.json",
                        detail: Mots.dit("Clé de ~/.local/share/opencode/auth.json · une requête "
                            + "à opencode.ai"))
        case .grok:
            Description(fournisseur: fournisseur,
                        chemin: "~/.grok/auth.json",
                        detail: Mots.dit("Connexion de ~/.grok/auth.json · une requête à cli-chat-proxy.grok.com"))
        case .grokBot:
            // La même base que Cursor : Grok Bot se connecte avec le compte Cursor, et son
            // quota hebdomadaire vit sur ce compte. Chemin distinct de celui de Cursor pour
            // que la liste « Ce que Quotum lit » ne confonde pas les deux lignes.
            Description(fournisseur: fournisseur,
                        chemin: "~/Library/…/Cursor/…/state.vscdb · compte de Grok Bot",
                        detail: Mots.dit("Connexion de la base de l'éditeur · une requête à api2.cursor.sh"))
        case .copilot:
            Description(fournisseur: fournisseur,
                        chemin: Mots.dit("~/.config/gh/hosts.yml · Trousseau · « %1$@ »",
                                         IdentifiantsCopilot.serviceTrousseau),
                        detail: Mots.dit("Connexion de la CLI gh · une requête à api.github.com"))
        case .kiro:
            Description(fournisseur: fournisseur,
                        chemin: "~/.aws/sso/cache/kiro-auth-token.json",
                        detail: Mots.dit("Connexion de ~/.aws/…/kiro-auth-token.json · une requête à amazonaws.com"
                            + " · si Kiro réclame le profil d'un compte d'organisation : la clé "
                            + "api.codewhisperer.profile de ~/Library/…/kiro-cli/data.sqlite3, puis une seconde requête"))
        case .cline:
            Description(fournisseur: fournisseur,
                        chemin: "~/.cline/data/settings/providers.json",
                        detail: Mots.dit("Connexion de ~/.cline/…/providers.json · une requête à api.cline.bot"))
        case .kimi:
            Description(fournisseur: fournisseur,
                        chemin: "~/.kimi-code/credentials/kimi-code.json",
                        detail: Mots.dit("Connexion de ~/.kimi-code/…/kimi-code.json · une requête à api.kimi.com"))
        case .kilo:
            Description(fournisseur: fournisseur,
                        chemin: "~/.local/share/kilo/auth.json",
                        detail: Mots.dit("Connexion de ~/.local/share/kilo/auth.json · une requête à app.kilo.ai"))
        case .nous:
            Description(fournisseur: fournisseur,
                        chemin: "~/.hermes/auth.json · ~/.hermes/shared/nous_auth.json",
                        detail: Mots.dit("Connexion d'Hermes, dans ~/.hermes · une requête à portal.nousresearch.com"))
        case .jetbrains:
            // Le seul outil lu sans aucune requête : l'IDE écrit lui-même son quota sur le disque.
            Description(fournisseur: fournisseur,
                        chemin: "~/Library/…/JetBrains/…/options/AIAssistantQuotaManager2.xml",
                        detail: Mots.dit("Fichier de quota que l'IDE écrit · aucune requête"))
        case .factory:
            Description(fournisseur: fournisseur,
                        chemin: Mots.dit("~/.factory/auth.v2.loginkeychain · Trousseau · « %1$@ »",
                                         IdentifiantsFactory.serviceTrousseau),
                        detail: Mots.dit("Connexion de droid, chiffrée dans ~/.factory · une requête à api.factory.ai"))
        case .muse:
            Description(fournisseur: fournisseur,
                        chemin: Mots.dit("~/.config/muse/auth.json · Trousseau · « %1$@ »",
                                         IdentifiantsMuse.serviceTrousseau),
                        detail: Mots.dit("Connexion de muse · une requête à api.meta.ai au plus toutes les 15 minutes"))
        // Les quatre suivants ne sont pas lus : leur outil en ligne de commande est lancé, en
        // lecture seule, et c'est lui qui interroge son serveur avec sa propre connexion. Leur
        // « chemin » est la commande lancée ; les emplacements essayés sont dans `OutilsCLI` et
        // sur la page « Ce que Quotum lit ».
        case .antigravity:
            Description(fournisseur: fournisseur,
                        chemin: "agy -p /usage",
                        detail: Mots.dit("Lance « %1$@ », en lecture seule : l'outil interroge lui-même son serveur",
                                         "agy -p /usage"))
        case .doubao:
            Description(fournisseur: fournisseur,
                        chemin: "arkcli usage plan",
                        detail: Mots.dit("Lance « %1$@ », en lecture seule : l'outil interroge lui-même son serveur",
                                         "arkcli usage plan"))
        case .alibaba:
            Description(fournisseur: fournisseur,
                        chemin: "bl usage token-plan",
                        detail: Mots.dit("Lance « %1$@ », en lecture seule : l'outil interroge lui-même son serveur",
                                         "bl usage token-plan"))
        case .amp:
            Description(fournisseur: fournisseur,
                        chemin: "amp usage",
                        detail: Mots.dit("Lance « %1$@ », en lecture seule : l'outil interroge lui-même son serveur",
                                         "amp usage"))
        }
    }

    /// Toutes, dans l'ordre de déclaration du fournisseur — celui du panneau.
    static let toutes: [Description] = Fournisseur.allCases.map(description(de:))
}

/// Les familles sous lesquelles « Choisir les outils à suivre » range ses interrupteurs
/// (décision produit du 2026-10-03) : chaque outil dans une seule, par `switch` exhaustif.
///
/// Amp va dans « Lus par leur outil » et non parmi les agents : Quotum ne lit pas sa
/// connexion, il lance `amp usage`, comme pour Antigravity, Doubao et Alibaba Model Studio.
/// Le groupe dit ce que suivre l'outil prend à l'utilisateur, pas la forme du produit.
/// Cline et Kilo Code sont des agents : c'est la connexion de leur outil en ligne de
/// commande qui est lue (`~/.cline`, `~/.local/share/kilo`), pas celle d'un éditeur.
enum FamilleOutil: CaseIterable, Sendable {
    case claudeEtCodex, editeurs, agentsEnLigneDeCommande, lusParLeurOutil

    static func de(_ fournisseur: Fournisseur) -> FamilleOutil {
        switch fournisseur {
        case .claude, .chatgpt: .claudeEtCodex
        case .windsurf, .cursor, .warp, .augment, .grokBot, .copilot, .kiro, .jetbrains: .editeurs
        case .codebuff, .opencode, .grok, .cline, .kimi, .kilo, .nous, .factory, .muse: .agentsEnLigneDeCommande
        case .antigravity, .doubao, .alibaba, .amp: .lusParLeurOutil
        }
    }

    var libelle: String {
        switch self {
        case .claudeEtCodex: Mots.dit("Claude et Codex")
        case .editeurs: Mots.dit("Éditeurs de code")
        case .agentsEnLigneDeCommande: Mots.dit("Agents en ligne de commande")
        case .lusParLeurOutil: Mots.dit("Lus par leur outil")
        }
    }

    /// Les outils de la famille, dans l'ordre de déclaration — celui du panneau.
    var outils: [MesureParJeton.Description] {
        MesureParJeton.toutes.filter { Self.de($0.fournisseur) == self }
    }
}

/// Ce que l'utilisateur a décidé pour un compte donné. Séparé de `Compte`, qui est
/// découvert : un compte disparu de la machine ne doit pas emporter son réglage,
/// sinon le rebrancher réinitialise le nom choisi et le rang.
struct ReglageCompte: Codable, Sendable, Equatable {
    var nomPersonnalise: String?
    var masque = false
    var rang: Int?
}

struct Reglages: Codable, Sendable, Equatable {
    var apparence: Apparence = .automatique
    var affichageBarre: AffichageBarre = .icone
    /// Le compte dont la barre de menus montre le pourcentage en mode « Icône + % », par son
    /// identifiant. `nil` : le plus utilisé, celui qui bloquera en premier (`ligneBarre`).
    var compteBarre: String?
    /// Pourcentage de consommation qui déclenche une notification. `nil` = jamais.
    var seuilAlerte: Int? = 80
    var prevenirJetonExpirant = true
    /// Une dépense payante qui commence, un plafond atteint, un solde prépayé à zéro. Armé par
    /// défaut (décision Q6) : c'est de l'argent, et chaque épisode ne se dit qu'une fois.
    var prevenirDepenses = true
    var grouperParFournisseur = true
    /// ⚠️ Le plancher est un choix de sobriété du produit, **pas** une contrainte
    /// constatée : aucune des neuf routes de quota ne traite un 429, et rien n'établit
    /// qu'un éditeur refuserait en deçà. Annoncer une limite qu'on n'a pas mesurée
    /// reviendrait à parler au nom de neuf éditeurs.
    var intervalleRafraichissementSecondes: TimeInterval = 300
    /// Nom d'application, tel que `open -a` l'attend. Vide = navigateur par défaut du système.
    var navigateurWeb = ""
    /// Terminal dans lequel s'ouvre une session épinglée. Terminal.app par défaut :
    /// c'est le seul dont la présence est garantie sur toute machine.
    var terminalEpinglage: TerminalCible = .terminal
    /// Répertoire où la session épinglée s'ouvre. Vide = celui que le terminal choisit
    /// lui-même, ce qu'il faisait avant que ce réglage existe.
    var repertoireEpinglage = ""
    var comptes: [String: ReglageCompte] = [:]
    /// En-têtes de groupe choisis par l'utilisateur, indexés par `Fournisseur.rawValue`.
    /// « Claude » et « Codex » sont les noms des outils, pas forcément ceux
    /// sous lesquels on range ses propres comptes — « Perso » et « Boulot » valent
    /// mieux pour qui sépare ainsi. Un nom vide ou effacé fait revenir le défaut.
    var nomsFournisseurs: [String: String] = [:]
    /// Pastilles d'en-tête choisies par l'utilisateur, indexées par `Fournisseur.rawValue`
    /// et écrites « #RRGGBB » en sRGB. Seize des vingt-trois teintes livrées sont des
    /// repères attribués faute de couleur de marque : ce réglage est la porte de sortie de qui
    /// n'en veut pas. Une clé absente rend la teinte livrée.
    var teintesFournisseurs: [String: String] = [:]
    /// ⛔ Éteint par défaut, et il doit le rester. Consommer une réinitialisation est la
    /// **seule écriture** que Quotum fait sur un compte, et elle n'est pas réversible :
    /// un crédit dépensé est perdu ; offerts par OpenAI ou gagnés par parrainage, ils périment
    /// au bout de trente jours. Armer ce réglage se fait donc en connaissance de cause, et l'interface le dit à ce
    /// moment-là — pas après.
    var reinitialisationAutomatique = false
    /// Le retour du quota doit être au moins à ce délai pour qu'une réinitialisation soit
    /// proposée : un compte qui revient seul dans quelques heures n'a pas à dépenser un crédit.
    ///
    /// ⛔ Borné à l'écriture comme à la relecture, et il entraîne `delaiAutomatiqueHeures` : le
    /// délai de l'automatisme ne descend jamais sous celui-ci.
    var delaiPropositionHeures = Reglages.delaiPropositionParDefaut {
        didSet { bornerDelais() }
    }
    /// Le même délai, pour le mode automatique — qui reste éteint tant que
    /// `reinitialisationAutomatique` ne l'arme pas.
    ///
    /// ⛔ Jamais plus court que `delaiPropositionHeures` : l'automatisme dépenserait sinon là où
    /// la proposition se tait. Un délai plus court se relève à celui de la proposition.
    var delaiAutomatiqueHeures = Reglages.delaiAutomatiqueParDefaut {
        didSet { bornerDelais() }
    }
    /// Ce que l'utilisateur a armé, indexé par `Fournisseur.rawValue`. Relever un compte
    /// demande le jeton que son outil garde déjà sur ce Mac — un élément qui appartient
    /// à un autre logiciel — puis un ou deux appels à une interface que son éditeur ne
    /// publie pas. Tant qu'un fournisseur n'est pas ici à vrai, aucun des deux n'a lieu.
    ///
    /// ⛔ **Une clé absente vaut « non armé », et c'est toute la raison de ce
    /// dictionnaire.** Neuf booléens nommés à la main donneraient neuf occasions d'en
    /// oublier un ; ici un fournisseur ajouté demain arrive éteint sans que personne ait
    /// à y penser.
    var mesureParJeton: [String: Bool] = [:]
    /// Vrai dès que l'écran d'ouverture a été présenté. Sans lui, il reparaîtrait à
    /// chaque lancement, y compris chez qui a répondu « Pas maintenant » — et la
    /// question posée une seconde fois se lit comme une insistance, pas comme un choix.
    var ouvertureVue = false
    /// Version de l'accueil déjà présentée. Un numéro et non un booléen : le jour où
    /// l'accueil dira autre chose, l'incrémenter le remontre une fois à qui l'avait
    /// déjà lu, sans le remontrer à chaque lancement.
    var versionAccueilVue = 0
    var rouvrirAppsALOuverture = false

    /// Numéro de la version courante de l'accueil.
    static let versionAccueil = 1

    /// L'accueil n'a pas encore été présenté dans sa version courante.
    var accueilARevoir: Bool { versionAccueilVue < Self.versionAccueil }

    static let delaiPropositionParDefaut = 12
    /// Une journée : plus prudent que la proposition, puisque personne ne confirme.
    static let delaiAutomatiqueParDefaut = 24
    /// Trente jours, la durée de vie d'une réinitialisation : au-delà, aucun délai n'a de sens.
    static let plageDelaiHeures = 0...720

    /// ⛔ Ramène les deux délais dans la plage, puis l'automatique au moins à la proposition.
    /// N'écrit que ce qui change : une affectation dans un `didSet` relance l'observateur de
    /// l'autre propriété, qui retrouve alors des valeurs déjà bornées.
    private mutating func bornerDelais() {
        let proposition = Self.borne(delaiPropositionHeures)
        if proposition != delaiPropositionHeures { delaiPropositionHeures = proposition }
        let automatique = max(Self.borne(delaiAutomatiqueHeures), proposition)
        if automatique != delaiAutomatiqueHeures { delaiAutomatiqueHeures = automatique }
    }

    private static func borne(_ heures: Int) -> Int {
        min(max(heures, plageDelaiHeures.lowerBound), plageDelaiHeures.upperBound)
    }

    /// Les deux délais, tels que la règle d'armement les lit.
    var delaisReinitialisation: ArmementReinitialisation.Delais {
        ArmementReinitialisation.Delais(propositionHeures: delaiPropositionHeures,
                                        automatiqueHeures: delaiAutomatiqueHeures)
    }

    func mesureArmee(_ fournisseur: Fournisseur) -> Bool {
        mesureParJeton[fournisseur.rawValue] ?? false
    }

    mutating func armerMesure(_ fournisseur: Fournisseur, _ arme: Bool) {
        mesureParJeton[fournisseur.rawValue] = arme
    }

    /// Ce que `rafraichir()` a le droit de relever. Construit depuis
    /// `Fournisseur.allCases` : aucune liste à tenir à jour, donc aucune à oublier.
    var consentementMesure: ConsentementMesure {
        ConsentementMesure(Set(Fournisseur.allCases.filter { mesureArmee($0) }))
    }

    /// Écrite à la main : dès que le type porte ses deux moitiés de `Codable`, Swift ne
    /// la synthétise plus. ⚠️ Un réglage ajouté sans sa clé ici ne serait jamais persisté.
    private enum CodingKeys: String, CodingKey {
        case apparence
        case affichageBarre, compteBarre, seuilAlerte, prevenirJetonExpirant, prevenirDepenses, grouperParFournisseur
        case intervalleRafraichissementSecondes, navigateurWeb, comptes
        case nomsFournisseurs, teintesFournisseurs, reinitialisationAutomatique
        case delaiPropositionHeures, delaiAutomatiqueHeures
        case terminalEpinglage, repertoireEpinglage
        case mesureParJeton, ouvertureVue, versionAccueilVue
        case rouvrirAppsALOuverture
        /// Les deux clés qu'écrivait la version à deux fournisseurs. ⚠️ Relues, jamais
        /// réécrites : qui avait armé Claude ou ChatGPT le retrouve armé, et la décision
        /// vit désormais dans `mesureParJeton`, où les neuf tiennent.
        case mesureParJetonClaude, mesureParJetonChatgpt
    }

    init() {}

    /// ⚠️ Le décodage synthétisé par Swift **ignore les valeurs par défaut** : une clé
    /// absente le fait échouer, et `MagasinReglages` repart alors des défauts. Ajouter
    /// un réglage effacerait donc tous les autres au premier lancement qui suit —
    /// mesuré, pas supposé. Chaque clé est lue si elle est là, sinon le défaut tient.
    ///
    /// `seuilAlerte` passe par `contains` : la clé absente doit rendre 80, la clé
    /// présente à `null` doit rendre « jamais », et `decodeIfPresent` confond les deux.
    init(from decodeur: Decoder) throws {
        let bloc = try decodeur.container(keyedBy: CodingKeys.self)
        // `try?` et non `try` : une valeur d'un autre type ferait échouer tout le bloc, et
        // le magasin repartirait des défauts en emportant noms, rangs et masquages pour un
        // réglage purement visuel. Inconnue, illisible ou absente, elle vaut `automatique`
        // — jamais une apparence que personne n'a choisie.
        if let choisie = try? bloc.decodeIfPresent(String.self, forKey: .apparence) {
            apparence = Apparence(rawValue: choisie) ?? apparence
        }
        affichageBarre = try bloc.decodeIfPresent(AffichageBarre.self, forKey: .affichageBarre) ?? affichageBarre
        // `try?` : un identifiant d'un autre type redonne « le plus utilisé » sans emporter le reste.
        if let choisi = try? bloc.decodeIfPresent(String.self, forKey: .compteBarre),
           !choisi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            compteBarre = choisi
        }
        if bloc.contains(.seuilAlerte) {
            seuilAlerte = try bloc.decodeIfPresent(Int.self, forKey: .seuilAlerte)
        }
        prevenirJetonExpirant = try bloc.decodeIfPresent(Bool.self, forKey: .prevenirJetonExpirant)
            ?? prevenirJetonExpirant
        // `try?` : une valeur d'un autre type ne fait pas tomber les autres réglages. Absente —
        // des réglages écrits avant cette alerte —, elle suit les deux autres alertes : qui les
        // a éteintes, ou s'est vu refuser l'autorisation, ne se retrouve pas armé en silence.
        if let lue = try? bloc.decodeIfPresent(Bool.self, forKey: .prevenirDepenses) {
            prevenirDepenses = lue
        } else if bloc.contains(.seuilAlerte) || bloc.contains(.prevenirJetonExpirant) {
            prevenirDepenses = seuilAlerte != nil || prevenirJetonExpirant
        }
        reinitialisationAutomatique = try bloc.decodeIfPresent(Bool.self,
                                                               forKey: .reinitialisationAutomatique)
            ?? reinitialisationAutomatique
        // `try?` : un délai d'un autre type ou illisible redonne le défaut sans emporter le
        // reste. Hors plage, il est borné plus bas, avec l'invariant entre les deux.
        if let heures = try? bloc.decodeIfPresent(Int.self, forKey: .delaiPropositionHeures) {
            delaiPropositionHeures = heures
        }
        if let heures = try? bloc.decodeIfPresent(Int.self, forKey: .delaiAutomatiqueHeures) {
            delaiAutomatiqueHeures = heures
        }
        grouperParFournisseur = try bloc.decodeIfPresent(Bool.self, forKey: .grouperParFournisseur)
            ?? grouperParFournisseur
        intervalleRafraichissementSecondes = try bloc.decodeIfPresent(
            TimeInterval.self, forKey: .intervalleRafraichissementSecondes) ?? intervalleRafraichissementSecondes
        navigateurWeb = try bloc.decodeIfPresent(String.self, forKey: .navigateurWeb) ?? navigateurWeb
        comptes = try bloc.decodeIfPresent([String: ReglageCompte].self, forKey: .comptes) ?? comptes
        nomsFournisseurs = try bloc.decodeIfPresent([String: String].self, forKey: .nomsFournisseurs)
            ?? nomsFournisseurs
        teintesFournisseurs = try bloc.decodeIfPresent([String: String].self, forKey: .teintesFournisseurs)
            ?? teintesFournisseurs
        // Relu comme une chaîne, et non comme le type lui-même : un terminal choisi
        // dans une version postérieure ferait échouer tout le décodage après un retour
        // en arrière, et le magasin repartirait des défauts — c'est-à-dire qu'un réglage
        // inconnu emporterait les noms, les rangs et les masquages avec lui.
        if let choisi = try bloc.decodeIfPresent(String.self, forKey: .terminalEpinglage) {
            terminalEpinglage = TerminalCible(rawValue: choisi) ?? terminalEpinglage
        }
        repertoireEpinglage = try bloc.decodeIfPresent(String.self, forKey: .repertoireEpinglage)
            ?? repertoireEpinglage
        // Les deux clés d'avant d'abord, le dictionnaire par-dessus : une décision prise
        // après la migration prime sur celle qu'elle remplace, et des réglages qui n'ont
        // ni l'une ni l'autre restent éteints.
        var armes: [String: Bool] = [:]
        if let claude = try bloc.decodeIfPresent(Bool.self, forKey: .mesureParJetonClaude) {
            armes[Fournisseur.claude.rawValue] = claude
        }
        if let chatgpt = try bloc.decodeIfPresent(Bool.self, forKey: .mesureParJetonChatgpt) {
            armes[Fournisseur.chatgpt.rawValue] = chatgpt
        }
        if let enregistres = try bloc.decodeIfPresent([String: Bool].self, forKey: .mesureParJeton) {
            armes.merge(enregistres) { _, apres in apres }
        }
        mesureParJeton = armes
        ouvertureVue = try bloc.decodeIfPresent(Bool.self, forKey: .ouvertureVue) ?? ouvertureVue
        versionAccueilVue = try bloc.decodeIfPresent(Int.self, forKey: .versionAccueilVue)
            ?? versionAccueilVue
        // `try?` : une valeur d'un autre type ne fait pas tomber les autres réglages.
        if let lue = try? bloc.decodeIfPresent(Bool.self, forKey: .rouvrirAppsALOuverture) {
            rouvrirAppsALOuverture = lue
        }
        // ⛔ Dans un initialiseur, les `didSet` ne se déclenchent pas : le bornage se fait ici.
        bornerDelais()
    }

    /// ⚠️ L'encodage synthétisé **tait** un optionnel nul. « Prévenir : jamais » ne
    /// s'écrivait donc pas, et la lecture ci-dessus le relisait comme une clé absente,
    /// c'est-à-dire comme 80 % : le réglage revenait tout seul au prochain lancement.
    /// `encodeNil` inscrit le refus au lieu de l'omettre.
    func encode(to encodeur: Encoder) throws {
        var bloc = encodeur.container(keyedBy: CodingKeys.self)
        try bloc.encode(apparence, forKey: .apparence)
        try bloc.encode(affichageBarre, forKey: .affichageBarre)
        try bloc.encodeIfPresent(compteBarre, forKey: .compteBarre)
        if let seuilAlerte {
            try bloc.encode(seuilAlerte, forKey: .seuilAlerte)
        } else {
            try bloc.encodeNil(forKey: .seuilAlerte)
        }
        try bloc.encode(prevenirJetonExpirant, forKey: .prevenirJetonExpirant)
        try bloc.encode(prevenirDepenses, forKey: .prevenirDepenses)
        try bloc.encode(grouperParFournisseur, forKey: .grouperParFournisseur)
        try bloc.encode(intervalleRafraichissementSecondes, forKey: .intervalleRafraichissementSecondes)
        try bloc.encode(navigateurWeb, forKey: .navigateurWeb)
        try bloc.encode(comptes, forKey: .comptes)
        try bloc.encode(nomsFournisseurs, forKey: .nomsFournisseurs)
        try bloc.encode(reinitialisationAutomatique, forKey: .reinitialisationAutomatique)
        try bloc.encode(delaiPropositionHeures, forKey: .delaiPropositionHeures)
        try bloc.encode(delaiAutomatiqueHeures, forKey: .delaiAutomatiqueHeures)
        try bloc.encode(teintesFournisseurs, forKey: .teintesFournisseurs)
        try bloc.encode(terminalEpinglage, forKey: .terminalEpinglage)
        try bloc.encode(repertoireEpinglage, forKey: .repertoireEpinglage)
        try bloc.encode(mesureParJeton, forKey: .mesureParJeton)
        try bloc.encode(ouvertureVue, forKey: .ouvertureVue)
        try bloc.encode(versionAccueilVue, forKey: .versionAccueilVue)
        try bloc.encode(rouvrirAppsALOuverture, forKey: .rouvrirAppsALOuverture)
    }

    /// Le nom affiché d'un compte : celui que l'utilisateur a choisi, sinon celui qui a
    /// été découvert sur la machine. Une seule définition pour les alertes et pour le mode
    /// automatique — deux copies finiraient par nommer le même compte autrement dans une
    /// notification et dans la rangée qui l'a déclenchée.
    ///
    /// ⚠️ Un nom fait de blancs n'est pas un nom : il laisserait la notification sans
    /// titre, sans que rien ne dise de quel compte elle parle.
    func nomAffiche(de ligne: Ligne) -> String {
        let personnalise = comptes[ligne.id]?.nomPersonnalise?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let personnalise, !personnalise.isEmpty else { return ligne.compte.nom }
        return personnalise
    }

    /// Le nom affiché d'un groupe : celui qui a été choisi, sinon celui du fournisseur.
    func nomAffiche(de fournisseur: Fournisseur) -> String {
        let choisi = nomsFournisseurs[fournisseur.rawValue]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let choisi, !choisi.isEmpty else { return fournisseur.libelle }
        return choisi
    }

    /// Les lignes que le panneau affiche, dans l'ordre où il les affiche : masquées
    /// retirées, rang choisi d'abord, puis groupées par fournisseur si le réglage le veut.
    ///
    /// ⛔ La seule définition de cet ordre. Le panneau la numérote, et le reste de l'app
    /// s'y fie pour savoir quel compte vient en tête : deux copies finiraient par en
    /// désigner un autre que celui qu'on voit.
    func lignesAffichees(_ lignes: [Ligne]) -> [Ligne] {
        let visibles = lignes.filter { !(comptes[$0.id]?.masque ?? false) }
        let triees = visibles.enumerated().sorted { gauche, droite in
            let rangGauche = comptes[gauche.element.id]?.rang ?? Int.max
            let rangDroite = comptes[droite.element.id]?.rang ?? Int.max
            if rangGauche != rangDroite { return rangGauche < rangDroite }
            return gauche.offset < droite.offset
        }.map(\.element)

        guard grouperParFournisseur else { return triees }
        return GroupeLignes.ordre.flatMap { groupe in
            triees.filter { $0.compte.groupe == groupe }
        }
    }

    /// Le compte que la barre de menus chiffre en mode « Icône + % » : celui qui est épinglé,
    /// s'il est affiché et mesuré ; sinon le plus utilisé — celui dont la fenêtre contraignante
    /// est la plus consommée, donc qui bloquera en premier. À égalité, le premier affiché.
    ///
    /// ⛔ Seules les fenêtres du compte comptent : une limite de modèle n'est pas dans
    /// `Quota.fenetres`. Un compte masqué ne commande pas la barre, et sans aucune mesure il
    /// n'y a rien à chiffrer : `nil`, jamais un chiffre inventé. Une fenêtre rechargée depuis
    /// sa mesure ne chiffre plus rien : son pourcentage parle d'une fenêtre close.
    func ligneBarre(_ lignes: [Ligne], maintenant: Date = .now) -> Ligne? {
        let commande = { (ligne: Ligne) in
            ligne.etat.quota?.fenetreContraignante(mesureeA: ligne.etat.quotaMesureA, a: maintenant)
        }
        let mesurees = lignesAffichees(lignes).filter { commande($0) != nil }
        if let compteBarre, let epingle = mesurees.first(where: { $0.id == compteBarre }) {
            return epingle
        }
        var retenue: (ligne: Ligne, utilisation: Double)?
        for ligne in mesurees {
            guard let utilisation = commande(ligne)?.utilisation else { continue }
            if retenue.map({ utilisation > $0.utilisation }) ?? true { retenue = (ligne, utilisation) }
        }
        return retenue?.ligne
    }

    /// Le compte épinglé est affiché mais sans mesure : la barre en chiffre un autre, ce que
    /// les réglages doivent dire, puisque le menu y montre toujours le compte épinglé.
    func compteBarreEnAttenteDeMesure(_ lignes: [Ligne], maintenant: Date = .now) -> Bool {
        guard let compteBarre, let epingle = lignesAffichees(lignes).first(where: { $0.id == compteBarre })
        else { return false }
        return epingle.etat.quota?.fenetreContraignante(mesureeA: epingle.etat.quotaMesureA, a: maintenant) == nil
    }

    /// Ce que la barre écrit après l'icône en mode « Icône + % » : vide sans compte mesuré.
    func titreBarrePourcentage(_ lignes: [Ligne], maintenant: Date = .now) -> String {
        guard let ligne = ligneBarre(lignes, maintenant: maintenant),
              let fenetre = ligne.etat.quota?.fenetreContraignante(mesureeA: ligne.etat.quotaMesureA, a: maintenant)
        else { return "" }
        return " \(Int(fenetre.utilisation.rounded())) %"
    }

    /// Le prochain instant où ce titre peut changer sans nouvelle publication : la recharge
    /// d'une fenêtre affichée, prise aux seuils du panneau. `nil` hors du mode « Icône + % ».
    func prochainChangementBarre(_ lignes: [Ligne], apres maintenant: Date) -> Date? {
        guard affichageBarre == .iconeEtPourcentage else { return nil }
        return CorpsPanneau.prochainSeuil(lignesAffichees(lignes), verrouillees: [], apres: maintenant)
    }

    static let plancherRafraichissement: TimeInterval = 60

    var intervalleEffectif: TimeInterval {
        max(Self.plancherRafraichissement, intervalleRafraichissementSecondes)
    }
}

/// Persistance dans les préférences de l'app. Un réglage illisible ne casse rien :
/// on repart des valeurs par défaut plutôt que de refuser de démarrer.
@MainActor
final class MagasinReglages {
    static let shared = MagasinReglages(defaults: .standard)
    private static let cle = "reglages"

    private(set) var valeur: Reglages
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.cle),
           let lu = try? JSONDecoder().decode(Reglages.self, from: data) {
            valeur = lu
        } else {
            valeur = Reglages()
        }
    }

    func modifier(_ transformation: (inout Reglages) -> Void) {
        transformation(&valeur)
        if let data = try? JSONEncoder().encode(valeur) {
            defaults.set(data, forKey: Self.cle)
        }
    }

    func reglage(pour identifiant: String) -> ReglageCompte {
        valeur.comptes[identifiant] ?? ReglageCompte()
    }

    /// Le domaine où ces réglages vivent, pour ce que l'app y retient hors de `Reglages`.
    var preferences: UserDefaults { defaults }
}
