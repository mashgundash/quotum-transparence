import Foundation
import Synchronization

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

/// Les heures pendant lesquelles une notification arrive sans son ni bannière. Une liste
/// fermée de plages : une valeur inconnue se relit « éteintes », jamais une plage que
/// personne n'a choisie.
enum HeuresCalmes: String, Codable, Sendable, CaseIterable {
    case desactivees
    case de22a8 = "22-08"
    case de23a7 = "23-07"
    case de20a9 = "20-09"

    /// Début et fin, en heures pleines de l'heure locale ; la fin est exclue.
    var plage: (debut: Int, fin: Int)? {
        switch self {
        case .desactivees: nil
        case .de22a8: (22, 8)
        case .de23a7: (23, 7)
        case .de20a9: (20, 9)
        }
    }

    /// L'instant tombe dans la plage. Une plage qui enjambe minuit couvre la fin de soirée
    /// et le début de matinée.
    func contient(_ instant: Date, calendrier: Calendar) -> Bool {
        guard let plage else { return false }
        let heure = calendrier.component(.hour, from: instant)
        if plage.debut <= plage.fin { return heure >= plage.debut && heure < plage.fin }
        return heure >= plage.debut || heure < plage.fin
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
    private(set) var revocations: RevocationsMesure

    init(_ armes: Set<Fournisseur> = [], revocations: RevocationsMesure = RevocationsMesure()) {
        self.armes = armes
        self.revocations = revocations
    }

    /// L'état d'une installation neuve, et celui de qui a répondu « Pas maintenant ».
    static let aucun = ConsentementMesure()

    subscript(fournisseur: Fournisseur) -> Bool {
        get { armes.contains(fournisseur) }
        set {
            if newValue {
                armes.insert(fournisseur)
            } else if armes.remove(fournisseur) != nil {
                revocations.revoquer(fournisseur)
            }
        }
    }

    var nombreArmes: Int { armes.count }

    /// Ce qui reste autorisé des deux côtés : un suivi retiré en cours de route ne revient pas,
    /// même réarmé depuis — une révocation de plus d'un côté suffit à l'exclure.
    func restreint(a autre: ConsentementMesure) -> ConsentementMesure {
        ConsentementMesure(armes.filter { autre.armes.contains($0) && revocations[$0] == autre.revocations[$0] },
                           revocations: autre.revocations)
    }
}

/// Combien de fois, depuis le lancement, chaque suivi a été retiré ou la clé collée de son outil
/// changée. Une autorisation lue avant une révocation ne vaut plus après, même si le suivi a été
/// réarmé et une autre clé collée entre-temps : c'est ce qui empêche une mesure faite avec
/// l'ancienne clé d'être publiée pour la nouvelle.
///
/// En mémoire seulement : jamais écrites avec les réglages.
struct RevocationsMesure: Sendable, Equatable {
    private var compteurs: [Fournisseur: UInt64] = [:]

    init() {}

    subscript(fournisseur: Fournisseur) -> UInt64 { compteurs[fournisseur, default: 0] }

    mutating func revoquer(_ fournisseur: Fournisseur) { compteurs[fournisseur, default: 0] &+= 1 }

    /// Ce qu'une modification laisse : jamais moins qu'avant, et une révocation de plus pour chaque
    /// suivi qu'elle retire sans l'avoir comptée. Une copie ancienne des réglages réécrite telle
    /// quelle ne fait donc jamais revenir une autorisation périmée.
    func suivies(de modifiees: RevocationsMesure, retires: Set<Fournisseur>) -> RevocationsMesure {
        var resultat = RevocationsMesure()
        for fournisseur in Set(compteurs.keys).union(modifiees.compteurs.keys).union(retires) {
            let plus = max(self[fournisseur], modifiees[fournisseur])
            resultat.compteurs[fournisseur] = retires.contains(fournisseur) && plus == self[fournisseur] ? plus &+ 1 : plus
        }
        return resultat
    }
}

/// Une valeur que les réglages portent sans qu'elle compte dans leur égalité : `Reglages` se compare
/// pour savoir si l'utilisateur a changé un réglage, et une révocation n'en est pas un. Le
/// consentement, lui, compare ses révocations : deux autorisations différentes n'y sont pas égales.
struct HorsEgaliteReglages<Valeur: Sendable>: Sendable, Equatable {
    var valeur: Valeur

    static func == (_: HorsEgaliteReglages, _: HorsEgaliteReglages) -> Bool { true }
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
        /// Rien d'un autre outil : la clé que l'utilisateur a collée dans Quotum, gardée dans son
        /// propre élément du Trousseau.
        case cleCollee
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
            case .zai, .minimax: .cleCollee
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
                        chemin: Mots.dit("<CODEX_HOME>/auth.json · Trousseau · « %1$@ »", TrousseauCodex.service),
                        // La seconde requête est celle de la mesure par jeton personnel
                        // (`QuotaCodexJetonPersonnel`) : la route d'identité d'OpenAI.
                        detail: Mots.dit("Les connexions de Codex : ~/.codex/auth.json ou $CODEX_HOME, ou l'élément « Codex Auth » du Trousseau quand Codex y range sa connexion, le CODEX_HOME de chaque app de compte, et le dossier que publie un proxy local · une requête à chatgpt.com par fichier auth.json lu, un même dossier une seule fois, plus une à auth.openai.com pour une clé d'accès personnelle · et, quand vous dépliez le tiroir d'un compte, deux lectures à chatgpt.com : sa réserve de réinitialisations et leur historique"))
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
        // Les deux suivants ne lisent rien d'un autre outil : la clé que l'utilisateur colle dans
        // Quotum, rangée dans l'élément du Trousseau propre à Quotum, désigné par son libellé.
        case .zai:
            Description(fournisseur: fournisseur,
                        chemin: Mots.dit("Trousseau · « %1$@ »", MagasinClesOutil.libelle(.zai)),
                        detail: Mots.dit("Clé que vous avez collée dans Quotum, gardée dans son propre élément du Trousseau · une requête à %1$@ ou à %2$@, selon la région du compte",
                                         QuotaZai.hoteInternational, QuotaZai.hoteChine))
        case .minimax:
            Description(fournisseur: fournisseur,
                        chemin: Mots.dit("Trousseau · « %1$@ »", MagasinClesOutil.libelle(.minimax)),
                        detail: Mots.dit("Clé que vous avez collée dans Quotum, gardée dans son propre élément du Trousseau · une requête à %1$@ ou à %2$@, selon la région du compte",
                                         QuotaMiniMax.hoteInternational, QuotaMiniMax.hoteChine))
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
    case claudeEtCodex, editeurs, agentsEnLigneDeCommande, lusParLeurOutil, avecUneCleCollee

    static func de(_ fournisseur: Fournisseur) -> FamilleOutil {
        switch fournisseur {
        case .claude, .chatgpt: .claudeEtCodex
        case .windsurf, .cursor, .warp, .augment, .grokBot, .copilot, .kiro, .jetbrains: .editeurs
        case .codebuff, .opencode, .grok, .cline, .kimi, .kilo, .nous, .factory, .muse: .agentsEnLigneDeCommande
        case .antigravity, .doubao, .alibaba, .amp: .lusParLeurOutil
        case .zai, .minimax: .avecUneCleCollee
        }
    }

    var libelle: String {
        switch self {
        case .claudeEtCodex: Mots.dit("Claude et Codex")
        case .editeurs: Mots.dit("Éditeurs de code")
        case .agentsEnLigneDeCommande: Mots.dit("Agents en ligne de commande")
        case .lusParLeurOutil: Mots.dit("Lus par leur outil")
        case .avecUneCleCollee: Mots.dit("Avec une clé que vous collez")
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
    /// Les pourcentages de consommation qui déclenchent une notification, triés, sans
    /// doublon, chacun entre 50 et 99. Vide = jamais.
    var seuilsAlerte: [Int] = Reglages.seuilsParDefaut {
        didSet {
            let normalises = Self.normaliser(seuilsAlerte)
            if normalises != seuilsAlerte { seuilsAlerte = normalises }
        }
    }
    var prevenirJetonExpirant = true
    /// Une fenêtre dont le rythme mène à sec avant sa recharge.
    var prevenirRythme = true
    /// Une fenêtre vue presque épuisée, au moment où elle se recharge.
    var prevenirRetour = true
    var heuresCalmes: HeuresCalmes = .desactivees
    /// Des initiales à la place des noms et des adresses.
    var masquerNoms = false
    /// Demander à macOS de tenir le panneau hors des captures d'écran.
    var exclureDesCaptures = false
    /// Écrire l'état des quotas dans un fichier local.
    var ecrireStatutLocal = false
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
    /// et écrites « #RRGGBB » en sRGB. Dix-huit des vingt-cinq teintes livrées sont des
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
    /// Hors de `CodingKeys` : jamais écrit, chaque lancement repart de zéro.
    private var memoireRevocations = HorsEgaliteReglages(valeur: RevocationsMesure())
    var revocationsMesure: RevocationsMesure {
        get { memoireRevocations.valeur }
        set { memoireRevocations.valeur = newValue }
    }
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

    static let seuilsParDefaut = [80, 95]
    static let plageSeuils = 50...99

    /// Le plus bas des seuils, celui qui prévient le premier ; `nil` quand aucun n'est réglé.
    /// L'affecter remplace la liste par ce seul seuil.
    var seuilAlerte: Int? {
        get { seuilsAlerte.first }
        set { seuilsAlerte = newValue.map { [$0] } ?? [] }
    }

    private static func normaliser(_ seuils: [Int]) -> [Int] {
        Array(Set(seuils.filter(plageSeuils.contains))).sorted()
    }

    /// Une liste relue telle quelle si chacune de ses valeurs est un seuil admis ; sinon `nil`,
    /// et l'appelant reprend le défaut plutôt qu'une liste amputée qu'on n'a pas choisie.
    private static func seuilsAdmis(_ seuils: [Int]) -> [Int]? {
        seuils.allSatisfy(plageSeuils.contains) ? normaliser(seuils) : nil
    }

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
        if !arme, mesureArmee(fournisseur) { revocationsMesure.revoquer(fournisseur) }
        mesureParJeton[fournisseur.rawValue] = arme
    }

    /// La clé collée de l'outil a changé ou disparu : ce qui a été autorisé avant ne vaut plus.
    mutating func revoquerMesure(_ fournisseur: Fournisseur) {
        revocationsMesure.revoquer(fournisseur)
    }

    /// Ce que `rafraichir()` a le droit de relever. Construit depuis
    /// `Fournisseur.allCases` : aucune liste à tenir à jour, donc aucune à oublier.
    var consentementMesure: ConsentementMesure {
        ConsentementMesure(Set(Fournisseur.allCases.filter { mesureArmee($0) }), revocations: revocationsMesure)
    }

    /// Écrite à la main : dès que le type porte ses deux moitiés de `Codable`, Swift ne
    /// la synthétise plus. ⚠️ Un réglage ajouté sans sa clé ici ne serait jamais persisté.
    private enum CodingKeys: String, CodingKey {
        case apparence
        case affichageBarre, compteBarre, seuilsAlerte, prevenirJetonExpirant, prevenirDepenses, grouperParFournisseur
        case prevenirRythme, prevenirRetour, heuresCalmes
        case masquerNoms, exclureDesCaptures, ecrireStatutLocal
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
        /// Le seuil unique d'avant les seuils multiples. ⚠️ Relu, jamais réécrit.
        case seuilAlerte
    }

    init() {}

    /// ⚠️ Le décodage synthétisé par Swift **ignore les valeurs par défaut** : une clé
    /// absente le fait échouer, et `MagasinReglages` repart alors des défauts. Ajouter
    /// un réglage effacerait donc tous les autres au premier lancement qui suit —
    /// mesuré, pas supposé. Chaque clé est lue si elle est là, sinon le défaut tient.
    ///
    /// Le seuil unique d'avant passe par `contains` : la clé absente doit rendre le défaut, la
    /// clé présente à `null` doit rendre « jamais », et `decodeIfPresent` confond les deux.
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
        // `try?` partout : une valeur d'un autre type, ou hors de la plage, redonne le défaut
        // sans emporter les autres réglages. La liste prime sur le seuil unique qu'elle remplace.
        if bloc.contains(.seuilsAlerte) {
            seuilsAlerte = (try? bloc.decode([Int].self, forKey: .seuilsAlerte)).flatMap(Self.seuilsAdmis)
                ?? Self.seuilsParDefaut
        } else if bloc.contains(.seuilAlerte) {
            if (try? bloc.decodeNil(forKey: .seuilAlerte)) == true {
                seuilsAlerte = []
            } else if let seuil = try? bloc.decode(Int.self, forKey: .seuilAlerte),
                      Self.plageSeuils.contains(seuil) {
                seuilsAlerte = [seuil]
            } else {
                seuilsAlerte = Self.seuilsParDefaut
            }
        }
        prevenirJetonExpirant = try bloc.decodeIfPresent(Bool.self, forKey: .prevenirJetonExpirant)
            ?? prevenirJetonExpirant
        // Des réglages écrits avant une alerte la font suivre l'état d'alerte d'alors : qui avait
        // tout éteint, ou s'est vu refuser l'autorisation, ne se retrouve pas armé en silence.
        let alertesDejaReglees = bloc.contains(.seuilAlerte) || bloc.contains(.seuilsAlerte)
            || bloc.contains(.prevenirJetonExpirant)
        if let lue = try? bloc.decodeIfPresent(Bool.self, forKey: .prevenirDepenses) {
            prevenirDepenses = lue
        } else if alertesDejaReglees {
            prevenirDepenses = !seuilsAlerte.isEmpty || prevenirJetonExpirant
        }
        let etatAnterieur = !seuilsAlerte.isEmpty || prevenirJetonExpirant || prevenirDepenses
        let alertesAnterieures = alertesDejaReglees || bloc.contains(.prevenirDepenses)
        if let lue = try? bloc.decodeIfPresent(Bool.self, forKey: .prevenirRythme) {
            prevenirRythme = lue
        } else if alertesAnterieures {
            prevenirRythme = etatAnterieur
        }
        if let lue = try? bloc.decodeIfPresent(Bool.self, forKey: .prevenirRetour) {
            prevenirRetour = lue
        } else if alertesAnterieures {
            prevenirRetour = etatAnterieur
        }
        if let lue = try? bloc.decodeIfPresent(String.self, forKey: .heuresCalmes) {
            heuresCalmes = HeuresCalmes(rawValue: lue) ?? .desactivees
        }
        if let lue = try? bloc.decodeIfPresent(Bool.self, forKey: .masquerNoms) { masquerNoms = lue }
        if let lue = try? bloc.decodeIfPresent(Bool.self, forKey: .exclureDesCaptures) { exclureDesCaptures = lue }
        if let lue = try? bloc.decodeIfPresent(Bool.self, forKey: .ecrireStatutLocal) { ecrireStatutLocal = lue }
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

    /// « Prévenir : jamais » s'écrit en liste vide, jamais par omission : une clé absente se
    /// relit comme le défaut, et le réglage reviendrait tout seul au prochain lancement.
    func encode(to encodeur: Encoder) throws {
        var bloc = encodeur.container(keyedBy: CodingKeys.self)
        try bloc.encode(apparence, forKey: .apparence)
        try bloc.encode(affichageBarre, forKey: .affichageBarre)
        try bloc.encodeIfPresent(compteBarre, forKey: .compteBarre)
        try bloc.encode(seuilsAlerte, forKey: .seuilsAlerte)
        try bloc.encode(prevenirJetonExpirant, forKey: .prevenirJetonExpirant)
        try bloc.encode(prevenirDepenses, forKey: .prevenirDepenses)
        try bloc.encode(prevenirRythme, forKey: .prevenirRythme)
        try bloc.encode(prevenirRetour, forKey: .prevenirRetour)
        try bloc.encode(heuresCalmes, forKey: .heuresCalmes)
        try bloc.encode(masquerNoms, forKey: .masquerNoms)
        try bloc.encode(exclureDesCaptures, forKey: .exclureDesCaptures)
        try bloc.encode(ecrireStatutLocal, forKey: .ecrireStatutLocal)
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
/// Le consentement courant, lisible depuis n'importe quel fil sans attendre le fil principal : un
/// travail sur une file du système le relit juste avant son effet, et une révocation faite entre
/// sa programmation et son exécution l'arrête.
final class MiroirConsentement: Sendable {
    static let systeme = MiroirConsentement()

    private let courant = Mutex(ConsentementMesure.aucun)

    init() {}

    func lire() -> ConsentementMesure { courant.withLock { $0 } }

    func poser(_ consentement: ConsentementMesure) { courant.withLock { $0 = consentement } }
}

@MainActor
final class MagasinReglages {
    static let shared = MagasinReglages(defaults: .standard, miroir: .systeme)
    private static let cle = "reglages"

    private(set) var valeur: Reglages
    private let defaults: UserDefaults
    private let miroir: MiroirConsentement?

    init(defaults: UserDefaults, miroir: MiroirConsentement? = nil) {
        self.defaults = defaults
        self.miroir = miroir
        defer { miroir?.poser(valeur.consentementMesure) }
        if let data = defaults.data(forKey: Self.cle),
           let lu = try? JSONDecoder().decode(Reglages.self, from: data) {
            valeur = lu
        } else {
            valeur = Reglages()
        }
    }

    func modifier(_ transformation: (inout Reglages) -> Void) {
        let avant = valeur
        transformation(&valeur)
        let retires = Set(Fournisseur.allCases.filter { avant.mesureArmee($0) && !valeur.mesureArmee($0) })
        valeur.revocationsMesure = avant.revocationsMesure.suivies(de: valeur.revocationsMesure, retires: retires)
        miroir?.poser(valeur.consentementMesure)
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
