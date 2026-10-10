import Foundation
import Testing
@testable import Quotum

/// Sondes locales à deux origines, macOS 26.6, le 2026-09-17 : un `Authorization`
/// posé par `URLRequest.setValue` est retiré par CFNetwork sur toute redirection,
/// même de même origine, tandis que le même en-tête posé dans la configuration de
/// session est rejoué sur la cible — autre hôte compris. Le jeton du Trousseau
/// partirait alors chez le redirecteur.
///
/// ⚠️ Ce qui suit vérifie **notre construction** : l'en-tête est posé par requête,
/// jamais par session. Rien du comportement d'Apple n'y est couvert — si CFNetwork
/// se mettait à rejouer les en-têtes de requête sur redirection, ces tests
/// resteraient verts. Seule une sonde à deux origines verrait cette régression-là.
@Suite("Gardes de réseau : ce que l'app envoie, et sous quel nom")
struct GardesReseauTests {
    /// Les noms sous lesquels l'app se ferait passer pour un client officiel. Lire un
    /// jeton qu'on a le droit de lire et se déguiser ne sont pas la même infraction.
    private static let deguisements = ["claude-code", "codex-cli", "codex_cli", "vscode", "githubcopilot", "copilot-chat", "copilot-language-server", "kimi_code_cli", "kimicli"]

    /// Les en-têtes par lesquels un client officiel se désigne lui-même : les poser, quelle que
    /// soit leur valeur, c'est parler en son nom.
    private static let entetesDeClientOfficiel: Set<String> = ["originator", "openai-beta"]

    /// Une imitation admise : une requête nommée, son adresse, une méthode, un en-tête, et la seule
    /// valeur qu'il peut porter. ⚠️ Le nom compte autant que l'adresse : la mesure par jeton
    /// personnel et la connexion OAuth visent la même adresse de `wham/usage`, et seule la
    /// première est admise.
    struct Exception: Sendable, CustomStringConvertible {
        let destinataire: String
        let adresse: String
        let entete: String
        /// L'expression que la valeur entière doit suivre.
        let motif: String
        let forme: String

        var description: String { "\(entete) « \(forme) » sur \(destinataire)" }
    }

    /// ⛔ La seule exception à « aucune requête ne se déguise en client officiel » (décision
    /// produit du 2026-10-03) : la mesure d'un compte Codex par jeton personnel. Ces deux
    /// requêtes, ces deux en-têtes, ces deux valeurs — rien d'autre. Les adresses sont écrites
    /// ici en toutes lettres, et non relues dans le code : l'élargir doit passer par ce fichier.
    static let identitePersonnelle = "Codex par jeton personnel, l'identité"
    static let mesurePersonnelle = "Codex par jeton personnel, la mesure"

    static let exceptionsAdmises: [Exception] = {
        let requetes = [(identitePersonnelle, "https://auth.openai.com/api/accounts/v1/user-auth-credential/whoami"),
                        (mesurePersonnelle, "https://chatgpt.com/backend-api/wham/usage")]
        return requetes.flatMap { destinataire, adresse in
            [Exception(destinataire: destinataire, adresse: adresse, entete: "user-agent", motif: #"codex_cli_rs/\d{1,4}(?:\.\d{1,4}){1,3}"#,
                       forme: "codex_cli_rs/<version>"),
             Exception(destinataire: destinataire, adresse: adresse, entete: "originator", motif: "codex_cli_rs", forme: "codex_cli_rs")]
        }
    }()

    /// Chaque en-tête qui parle au nom d'un client officiel, et qu'aucune exception ne couvre. Une
    /// exception ne couvre qu'un `GET` sans corps, à son adresse exacte, son en-tête exact, et une
    /// valeur entière conforme.
    static func imitations(_ sortantes: [(String, URLRequest)], admises: [Exception]) -> [String] {
        var fautes: [String] = []
        for (destinataire, requete) in sortantes {
            for (nom, valeur) in requete.allHTTPHeaderFields ?? [:] {
                let entete = nom.lowercased()
                let imite = entetesDeClientOfficiel.contains(entete)
                    || (entete == "user-agent" && deguisements.contains { valeur.lowercased().contains($0) })
                guard imite else { continue }
                let couverte = admises.contains { exception in
                    exception.entete == entete
                        && destinataire == exception.destinataire
                        && requete.url?.absoluteString == exception.adresse
                        && requete.httpMethod == "GET" && requete.httpBody == nil
                        && (try? Regex(exception.motif)).flatMap { valeur.wholeMatch(of: $0) } != nil
                }
                if !couverte { fautes.append("\(destinataire) : \(entete) « \(valeur) »") }
            }
        }
        return fautes
    }

    private static let jetonPersonnelCodex = JetonPersonnelCodex(valeur: "jeton-de-test")

    /// Ce que chaque lecteur emporte, nom par nom et rien de plus.
    ///
    /// ⛔ C'est ici que tient la seconde promesse du contrat. Une liste d'en-têtes
    /// interdits contrôlée sur la configuration de session ne peut pas échouer tant que
    /// cette configuration est vide — et elle ne verrait pas un jeton qui aurait
    /// **quitté** la requête pour la session. Pincer l'ensemble exact de chaque requête
    /// le voit : l'en-tête disparaîtrait d'ici.
    private static let entetesAttendus: [Fournisseur: Set<String>] = [
        .claude: ["authorization", "anthropic-beta", "accept"],
        .chatgpt: ["authorization", "accept", "user-agent", "chatgpt-account-id"],
        // La clé de Windsurf voyage dans le corps, pas dans un en-tête.
        .windsurf: ["content-type", "accept", "connect-protocol-version", "user-agent"],
        .cursor: ["cookie", "accept", "user-agent"],
        .warp: ["authorization", "content-type"],
        .codebuff: ["cookie", "accept", "user-agent"],
        .augment: ["authorization", "content-type", "accept", "user-agent",
                   "x-request-id", "x-request-session-id"],
        .opencode: ["authorization", "accept", "user-agent"],
        .grok: ["authorization", QuotaGrok.enteteFamilleDeCle.lowercased(), "accept", "user-agent"],
        // Requête minimale, sans aucun en-tête du client officiel « sand ».
        .grokBot: ["authorization", "content-type", "connect-protocol-version", "user-agent"],
        .copilot: ["authorization", "accept", "user-agent"],
        .kiro: ["authorization", "accept", "user-agent"],
        .cline: ["authorization", "accept", "user-agent"],
        .kimi: ["authorization", "accept", "user-agent"],
        .kilo: ["authorization", "accept", "user-agent"],
        .nous: ["authorization", "accept", "user-agent"],
        // L'organisation choisie par `droid`, pour que la réponse décrive la même.
        .factory: ["authorization", "accept", "user-agent", QuotaFactory.enteteOrganisation.lowercased()],
        .muse: ["authorization", "content-type", "accept", "x-api-version", "user-agent"],
    ]

    /// Les cinq outils dont Quotum n'émet aucune requête : JetBrains AI se lit dans un fichier
    /// que l'IDE écrit, et les quatre autres par leur CLI officiel, qui interroge lui-même son
    /// serveur avec sa propre connexion.
    private static let sansRequete: Set<Fournisseur> = [.jetbrains, .antigravity, .doubao, .alibaba, .amp]

    private static let jetonClaude = JetonClaudeCode(valeur: "jeton-de-test", expireA: nil)
    private static let jetonCodex = JetonCodex(valeur: "jeton-de-test", compteIdentifiant: "compte-de-test")
    private static let jetonCursor = JetonCursor(valeur: "jeton-de-test", utilisateurIdentifiant: "user-de-test", courriel: nil, expireA: nil)
    private static let jetonCodebuff = JetonCodebuff(valeur: "jeton-de-test", courriel: nil, nom: nil)
    private static let cleWindsurf = CleWindsurf(valeur: "jeton-de-test", hote: nil)
    private static let jetonWarp = JetonWarp(valeur: "jeton-de-test", expireA: nil, utilisateurIdentifiant: nil)
    private static let jetonAugment = JetonAugment(valeur: "jeton-de-test", tenant: "https://essai.api.augmentcode.com/")
    private static let cleOpencode = CleOpencode(valeur: "jeton-de-test")
    private static let jetonGrok = JetonGrok(valeur: "jeton-de-test", organisation: nil, origine: .session)
    private static let cleDeDeploiementGrok = JetonGrok(valeur: "jeton-de-test", organisation: nil,
                                                        origine: .cleDeDeploiement)
    /// Grok Bot emprunte le jeton de l'éditeur Cursor : c'est le même type que Cursor.
    private static let jetonGrokBot = JetonCursor(valeur: "jeton-de-test", utilisateurIdentifiant: "user-de-test", courriel: nil, expireA: nil)
    private static let jetonCopilot = JetonCopilot(valeur: "jeton-de-test", utilisateur: nil)
    private static let jetonKilo = JetonKilo(valeur: "jeton-de-test")
    private static let jetonCline = JetonClinePass(valeur: "workos:jeton-de-test")
    private static let jetonKimi = JetonKimi(valeur: "jeton-de-test", expireA: nil)
    private static let jetonNous = JetonNous(valeur: "jeton-de-test", portail: IdentifiantsNous.portailParDefaut,
                                             expireA: nil)
    private static let jetonFactory = JetonFactory(valeur: "jeton-de-test", organisation: "org_essai",
                                                   region: .mondiale)
    private static let jetonMuse = JetonMuse(valeur: "dca:jeton-de-test")
    private static let jetonKiro = JetonKiro(valeur: "jeton-de-test",
                                             profileArn: "arn:aws:codewhisperer:us-east-1:123456789012:profile/ESSAI",
                                             region: "us-east-1")

    /// ⛔ Un `switch` exhaustif, jamais une liste écrite à la main : c'est le compilateur
    /// qui tient le compte, comme partout ailleurs dans ce projet. Le tableau littéral
    /// qu'il remplace serait resté à douze entrées le jour d'un dixième lecteur — et ce
    /// lecteur-là serait parti sans passer par un seul de ces gardes.
    private static func requete(pour fournisseur: Fournisseur) throws -> URLRequest? {
        switch fournisseur {
        case .claude:
            try #require(QuotaAnthropic.requete(chemin: "/api/oauth/usage", jeton: jetonClaude, delai: 8))
        case .chatgpt:
            try #require(QuotaCodex.requete(jeton: jetonCodex, delai: 8))
        case .windsurf:
            try #require(QuotaWindsurf.requete(cle: cleWindsurf, delai: 8))
        case .cursor:
            try #require(QuotaCursor.requete(jeton: jetonCursor, delai: 8))
        case .warp:
            try #require(QuotaWarp.requete(jeton: jetonWarp, delai: 8))
        case .codebuff:
            try #require(QuotaCodebuff.requete(jeton: jetonCodebuff, delai: 8))
        case .augment:
            try #require(QuotaAugment.requete(jeton: jetonAugment, delai: 8))
        case .opencode:
            try #require(QuotaOpencode.requete(cle: cleOpencode, delai: 8))
        case .grok:
            try #require(QuotaGrok.requete(jeton: jetonGrok, delai: 8))
        case .grokBot:
            try #require(QuotaGrokBot.requete(jeton: jetonGrokBot, delai: 8))
        case .copilot:
            try #require(QuotaCopilot.requete(jeton: jetonCopilot, delai: 8))
        case .kiro:
            try #require(QuotaKiro.requete(jeton: jetonKiro, delai: 8))
        case .cline:
            try #require(QuotaClinePass.requete(jeton: jetonCline, delai: 8))
        case .kimi:
            try #require(QuotaKimi.requete(jeton: jetonKimi, delai: 8))
        case .kilo:
            try #require(QuotaKilo.requete(jeton: jetonKilo, delai: 8))
        case .nous:
            try #require(QuotaNous.requete(jeton: jetonNous, delai: 8))
        case .factory:
            try #require(QuotaFactory.requete(jeton: jetonFactory, delai: 8))
        case .muse:
            try #require(QuotaMuse.requete(jeton: jetonMuse, delai: 8))
        case .jetbrains, .antigravity, .doubao, .alibaba, .amp:
            nil
        }
    }

    /// Les dix-huit lecteurs qui émettent une requête, plus les dix-sept requêtes qui
    /// n'appartiennent à aucun d'eux.
    private static func requetesSortantes() throws -> [(String, URLRequest)] {
        let statut = try #require(SourceProxy.adresseLocale("http://127.0.0.1:8787/abc123/_proxy/status"))
        var toutes = try Fournisseur.allCases.compactMap { fournisseur in
            try requete(pour: fournisseur).map { (fournisseur.libelle, $0) }
        }
        // Le profil part avec le quota, et il emporte le même jeton.
        toutes.append(("Claude, le profil",
                       try #require(QuotaAnthropic.requete(chemin: "/api/oauth/profile",
                                                           jeton: jetonClaude, delai: 8))))
        // La seule écriture du produit passe au même garde que les lectures.
        toutes.append(("la réinitialisation ChatGPT",
                       try #require(ReinitialisationCodex.requete(jeton: jetonCodex,
                                                                  creditIdentifiant: nil,
                                                                  demandeIdentifiant: UUID()))))
        // La réserve et l'historique des réinitialisations, lus au dépli du tiroir.
        toutes.append(("la réserve de réinitialisations Codex",
                       try #require(ReserveCodex.requeteReserve(jeton: jetonCodex))))
        toutes.append(("l'historique des réinitialisations Codex",
                       try #require(ReserveCodex.requeteHistorique(jeton: jetonCodex, curseur: "page 2&x=1"))))
        // Codex par jeton personnel : l'identité, puis la mesure — la seule exception admise.
        toutes.append((identitePersonnelle,
                       try #require(QuotaCodexJetonPersonnel.requeteIdentite(jeton: jetonPersonnelCodex, delai: 8))))
        toutes.append((mesurePersonnelle,
                       try #require(QuotaCodexJetonPersonnel.requeteUsage(jeton: jetonPersonnelCodex,
                                                                          compte: "compte-de-test", delai: 8))))
        toutes.append(("la lecture d'un proxy", LecteurProxy.requete(url: statut, delai: 1.5)))
        // Les deux requêtes vers le service de licence : l'activation de ce Mac, et celle du
        // premier lancement, qui ouvre l'essai. Leur code n'est pas publié ; la fixture qui les
        // construit par ce code non plus, et ce test n'en lit que les requêtes.
        toutes.append(("l'activation de ce Mac", try FixturesLicence.requeteActivation()))
        toutes.append(("l'essai", try FixturesLicence.requeteEssai()))
        // Kiro en organisation : le second essai, avec le profil lu dans la base de kiro-cli.
        let sansProfil = JetonKiro(valeur: "jeton-de-test", profileArn: nil, region: "us-east-1")
        let profilDeLaBase = try #require(QuotaKiro.jeton(sansProfil,
                                                          profilDeLaBase: "arn:aws:codewhisperer:eu-central-1:123456789012:profile/BASE",
                                                          region: "eu-central-1"))
        toutes.append(("Kiro, avec le profil de kiro-cli", try #require(QuotaKiro.requete(jeton: profilDeLaBase, delai: 8))))
        // Le repli de Grok sur une clé de déploiement part sans l'en-tête de famille.
        toutes.append(("Grok, par clé de déploiement",
                       try #require(QuotaGrok.requete(jeton: cleDeDeploiementGrok, delai: 8))))
        // La clé de lecture : collée par l'utilisateur, elle ne sort d'aucun outil.
        let cleLecture = try DepenseAnthropicEntreprise.valider(cle: DepenseAnthropicEntreprise.prefixe
                                                                  + String(repeating: "a", count: 40)).get()
        toutes.append(("la dépense Claude Enterprise, par clé de lecture",
                       try #require(DepenseAnthropicEntreprise.requete(cle: cleLecture, membre: "user_01Ab",
                                                                       page: nil, delai: 8))))
        // Les deux nuages d'une clé de lecture : deux requêtes signées pour AWS, trois pour Azure.
        let instant = Date(timeIntervalSince1970: 1_791_000_000)
        toutes.append(("AWS, l'identité qui signe",
                       try #require(DepenseAWS.requeteIdentite(GardeAWSTests.identite, region: "eu-west-3",
                                                               instant: instant, delai: 8))))
        toutes.append(("AWS, les budgets",
                       try #require(DepenseAWS.requeteBudgets(GardeAWSTests.identite, compte: "123456789012",
                                                              suivant: nil, instant: instant, delai: 8))))
        let azure = GardeAzureTests.saisie
        toutes.append(("Azure, le jeton",
                       try #require(DepenseAzure.requeteJeton(tenant: azure.tenant, client: azure.client,
                                                              secret: azure.secret, delai: 8))))
        let jeton = JetonAzure(valeur: "aaa.bbb.ccc")
        toutes.append(("Azure, les permissions",
                       DepenseAzure.requeteGestion(try #require(DepenseAzure.adressePermissions(abonnement: azure.abonnement)),
                                                   jeton: jeton, delai: 8)))
        toutes.append(("Azure, les budgets",
                       DepenseAzure.requeteGestion(try #require(DepenseAzure.adresseBudgets(abonnement: azure.abonnement)),
                                                   jeton: jeton, delai: 8)))
        return toutes
    }

    /// Le CLI officiel de Kimi s'annonce par ces en-têtes : les reprendre serait se faire
    /// passer pour lui.
    @Test("Aucune requête sortante ne porte d'en-tête d'identité X-Msh du CLI de Kimi")
    func aucunEnTeteXMsh() throws {
        for (destinataire, requete) in try Self.requetesSortantes() {
            let noms = (requete.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }
            #expect(!noms.contains { $0.hasPrefix("x-msh") }, "\(destinataire) porte \(noms.sorted())")
        }
    }

    /// ⛔ Fermé par défaut : la configuration ne porte **aucun** en-tête, et pas seulement
    /// aucun de ceux qu'on a su nommer. Une liste d'interdits éprouvée sur un
    /// dictionnaire vide ne peut pas échouer, et elle laisserait passer celui auquel
    /// personne n'a pensé.
    @Test("La session partagée ne porte aucun en-tête, quel qu'il soit")
    func sessionSansEnTete() {
        let entetes = Reseau.session.configuration.httpAdditionalHeaders ?? [:]
        #expect(entetes.isEmpty, """
            La configuration de session porte \(entetes.keys.compactMap { $0 as? String }.sorted()). \
            CFNetwork rejoue ces en-têtes sur la cible d'une redirection, autre hôte compris : \
            ce qui identifie se pose sur la requête.
            """)
    }

    /// L'autre moitié de la même promesse, celle qui passe par les neuf lecteurs. Chacun
    /// pince déjà son propre jeu d'en-têtes dans son fichier ; ce qu'ajoute cette
    /// boucle-ci, c'est qu'un dixième lecteur **ne peut pas** ne pas y figurer.
    @Test("Chaque lecteur emporte son identification lui-même, et rien de plus")
    func chaqueLecteurPorteSonIdentification() throws {
        for fournisseur in Fournisseur.allCases {
            guard let requete = try Self.requete(pour: fournisseur) else {
                #expect(Self.sansRequete.contains(fournisseur),
                        "\(fournisseur.libelle) n'a aucune requête, sans être déclaré comme tel")
                #expect(Self.entetesAttendus[fournisseur] == nil)
                continue
            }
            #expect(!Self.sansRequete.contains(fournisseur))
            let attendus = try #require(Self.entetesAttendus[fournisseur],
                                        "\(fournisseur.libelle) n'a aucun jeu d'en-têtes décrit")
            let noms = Set((requete.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
            #expect(noms == attendus, "\(fournisseur.libelle) : \(noms.sorted())")
        }
    }

    @Test("Le jeton d'Anthropic est posé sur la requête, et rien d'autre ne part avec")
    func entetesDAnthropic() throws {
        let requete = try #require(QuotaAnthropic.requete(chemin: "/api/oauth/usage",
                                                          jeton: Self.jetonClaude, delai: 8))
        #expect(requete.value(forHTTPHeaderField: "Authorization") == "Bearer jeton-de-test")
        let noms = Set((requete.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        #expect(noms == ["authorization", "anthropic-beta", "accept"])
    }

    @Test("Le jeton de ChatGPT est posé sur la requête, et rien d'autre ne part avec")
    func entetesDeChatGPT() throws {
        let requete = try #require(QuotaCodex.requete(jeton: Self.jetonCodex, delai: 8))
        #expect(requete.value(forHTTPHeaderField: "Authorization") == "Bearer jeton-de-test")
        let noms = Set((requete.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        #expect(noms == ["authorization", "accept", "user-agent", "chatgpt-account-id"])
    }

    /// Le secret d'un proxy voyage dans le chemin, jamais dans un en-tête : la lecture
    /// du statut n'a donc rien à porter.
    @Test("Kiro avec le profil de kiro-cli : même adresse, mêmes en-têtes, le profil en paramètre")
    func kiroAvecLeProfilDeLaBase() throws {
        let sortante = try #require(try Self.requetesSortantes().first { $0.0 == "Kiro, avec le profil de kiro-cli" }?.1)
        let url = try #require(sortante.url)
        #expect(url.host() == "q.eu-central-1.amazonaws.com")
        #expect(url.path() == "/getUsageLimits")
        let parametres = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { [$0.name, $0.value ?? ""] }
        #expect(parametres == [["origin", "AI_EDITOR"], ["resourceType", "AGENTIC_REQUEST"],
                               ["profileArn", "arn:aws:codewhisperer:eu-central-1:123456789012:profile/BASE"]])
        let noms = Set((sortante.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        #expect(noms == Self.entetesAttendus[.kiro])
        #expect(sortante.value(forHTTPHeaderField: "User-Agent") == "Quotum")
    }

    @Test("La lecture d'un proxy ne porte aucun identifiant")
    func entetesDUnProxy() throws {
        let statut = try #require(SourceProxy.adresseLocale("http://127.0.0.1:8787/abc123/_proxy/status"))
        let requete = LecteurProxy.requete(url: statut, delai: 1.5)
        #expect(Set((requete.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }) == ["accept"])
    }

    @Test("Aucune requête sortante ne se fait passer pour un client officiel, hors l'exception nommée")
    func aucunDeguisementEnClientOfficiel() throws {
        let sortantes = try Self.requetesSortantes()
        // Sans ce plancher, une liste devenue vide passerait sans rien avoir regardé.
        #expect(sortantes.count == Fournisseur.allCases.count - Self.sansRequete.count + 17)
        let fautes = Self.imitations(sortantes, admises: Self.exceptionsAdmises)
        #expect(fautes.isEmpty, "l'app s'y annonce comme le client officiel : \(fautes.joined(separator: " · "))")
        // Hors des deux requêtes du jeton personnel, aucune ne porte même un User-Agent de client.
        for (destinataire, requete) in sortantes
        where destinataire != Self.identitePersonnelle && destinataire != Self.mesurePersonnelle {
            let annonce = requete.value(forHTTPHeaderField: "User-Agent")?.lowercased() ?? ""
            for deguisement in Self.deguisements {
                #expect(!annonce.contains(deguisement), "\(destinataire) reçoit « \(annonce) »")
            }
            for entete in Self.entetesDeClientOfficiel {
                #expect(requete.value(forHTTPHeaderField: entete) == nil, "\(destinataire) porte \(entete)")
            }
        }
    }

    /// La preuve par mutation : chaque élément de l'exception est nécessaire. Retirer l'un
    /// d'eux fait rougir la garde sur la requête qu'il couvrait.
    @Test("Retirer un en-tête de l'exception fait échouer la garde", arguments: 0..<4)
    func exceptionNecessaire(_ rang: Int) throws {
        var amputee = Self.exceptionsAdmises
        #expect(amputee.count == 4, "l'exception ne compte plus deux requêtes et deux en-têtes")
        let retiree = amputee.remove(at: rang)
        let fautes = Self.imitations(try Self.requetesSortantes(), admises: amputee)
        #expect(fautes.count == 1, "sans \(retiree), la garde devait relever une faute : \(fautes)")
        #expect(fautes.first?.contains(retiree.entete) == true)
    }

    /// L'exception est étroite : la même imitation, ailleurs ou autrement, est relevée.
    @Test("L'exception ne couvre rien d'autre que ses deux requêtes et ses deux en-têtes")
    func exceptionEtroite() throws {
        let admises = Self.exceptionsAdmises
        func faute(_ nom: String, _ requete: URLRequest) -> Bool {
            !Self.imitations([(nom, requete)], admises: admises).isEmpty
        }
        let nom = Self.identitePersonnelle
        let identite = try #require(QuotaCodexJetonPersonnel.requeteIdentite(jeton: Self.jetonPersonnelCodex, delai: 8))
        #expect(!faute(nom, identite))
        // La même requête, sous un autre nom : l'exception ne la couvre plus.
        #expect(faute("une autre requête", identite))
        // La mesure par OAuth vise la même adresse que la mesure par jeton personnel.
        var oauthDeguisee = try #require(QuotaCodex.requete(jeton: Self.jetonCodex, delai: 8))
        oauthDeguisee.setValue(QuotaCodexJetonPersonnel.agent, forHTTPHeaderField: "User-Agent")
        oauthDeguisee.setValue(QuotaCodexJetonPersonnel.originator, forHTTPHeaderField: "originator")
        #expect(oauthDeguisee.url?.absoluteString == QuotaCodexJetonPersonnel.adresseUsage)
        #expect(faute(Fournisseur.chatgpt.libelle, oauthDeguisee), "la mesure OAuth déguisée passe sous l'exception")

        // Les mêmes en-têtes sur la connexion OAuth, la réserve, l'historique ou la réinitialisation.
        var autres: [(String, URLRequest)] = [
            ("OAuth", try #require(QuotaCodex.requete(jeton: Self.jetonCodex, delai: 8))),
            ("réserve", try #require(ReserveCodex.requeteReserve(jeton: Self.jetonCodex))),
            ("historique", try #require(ReserveCodex.requeteHistorique(jeton: Self.jetonCodex, curseur: nil))),
            ("réinitialisation", try #require(ReinitialisationCodex.requete(jeton: Self.jetonCodex, creditIdentifiant: nil,
                                                                           demandeIdentifiant: UUID()))),
        ]
        for rang in autres.indices {
            autres[rang].1.setValue(QuotaCodexJetonPersonnel.originator, forHTTPHeaderField: "originator")
            #expect(faute(autres[rang].0, autres[rang].1), "\(autres[rang].0) : originator admis hors de l'exception")
            autres[rang].1.setValue(nil, forHTTPHeaderField: "originator")
            autres[rang].1.setValue(QuotaCodexJetonPersonnel.agent, forHTTPHeaderField: "User-Agent")
            #expect(faute(autres[rang].0, autres[rang].1), "\(autres[rang].0) : User-Agent du CLI admis hors de l'exception")
        }

        // Un autre en-tête de client sur une requête couverte.
        var avecBeta = identite
        avecBeta.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        #expect(faute(nom, avecBeta), "identité + OpenAI-Beta")
        // Une autre valeur, une autre méthode, un corps, un paramètre, un autre hôte.
        var autreValeur = identite
        autreValeur.setValue("codex_cli_rs/0.159.2 (Mac OS 26.6.0; arm64)", forHTTPHeaderField: "User-Agent")
        #expect(faute(nom, autreValeur), "User-Agent allongé")
        var autreOrigine = identite
        autreOrigine.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        #expect(faute(nom, autreOrigine), "originator Codex Desktop")
        var post = identite
        post.httpMethod = "POST"
        #expect(faute(nom, post), "POST")
        var corps = identite
        corps.httpBody = Data("{}".utf8)
        #expect(faute(nom, corps), "corps")
        var parametre = identite
        parametre.url = URL(string: QuotaCodexJetonPersonnel.adresseIdentite + "?x=1")
        #expect(faute(nom, parametre), "paramètre")
        var ailleurs = identite
        ailleurs.url = URL(string: "https://auth.openai.com.exemple.invalid/api/accounts/v1/user-auth-credential/whoami")
        #expect(faute(nom, ailleurs), "autre hôte")
    }

    /// Ce que chaque requête du jeton personnel emporte, nom par nom et valeur par valeur.
    @Test("Le jeton personnel de Codex : deux GET, en-têtes exacts, le compte rendu par l'identité")
    func entetesDuJetonPersonnelCodex() throws {
        let identite = try #require(QuotaCodexJetonPersonnel.requeteIdentite(jeton: Self.jetonPersonnelCodex, delai: 8))
        let usage = try #require(QuotaCodexJetonPersonnel.requeteUsage(jeton: Self.jetonPersonnelCodex,
                                                                       compte: "compte-rendu", delai: 8))
        #expect(identite.url?.absoluteString == "https://auth.openai.com/api/accounts/v1/user-auth-credential/whoami")
        #expect(usage.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        for requete in [identite, usage] {
            #expect(requete.httpMethod == "GET")
            #expect(requete.httpBody == nil)
            #expect(requete.value(forHTTPHeaderField: "Authorization") == "Bearer jeton-de-test")
            #expect(requete.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(requete.value(forHTTPHeaderField: "User-Agent") == "codex_cli_rs/0.159.2")
            #expect(requete.value(forHTTPHeaderField: "originator") == "codex_cli_rs")
        }
        #expect(Set((identite.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
                == ["authorization", "accept", "user-agent", "originator"])
        #expect(Set((usage.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
                == ["authorization", "accept", "user-agent", "originator", "chatgpt-account-id"])
        #expect(usage.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "compte-rendu")
    }

    /// Ni jeton, ni cookie, ni numéro de version : ce qui part tient dans ces trois en-têtes
    /// et ces trois champs, et rien d'autre ne s'y ajoute sans faire tomber ce test.
    @Test("L'activation emporte exactement trois en-têtes, s'annonce « Quotum », et son corps trois champs")
    func entetesDeLActivation() throws {
        let requete = try FixturesLicence.requeteActivation()
        #expect(requete.httpMethod == "POST")
        #expect(Set((requete.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
                == ["content-type", "accept", "user-agent"])
        #expect(requete.value(forHTTPHeaderField: "User-Agent") == "Quotum")
        let corps = try #require(requete.httpBody)
        let objet = try #require(try JSONSerialization.jsonObject(with: corps) as? [String: Any])
        #expect(Set(objet.keys) == ["cle", "cle_publique", "preuve"])
        #expect(requete.url?.scheme == "https")
    }

    /// Ni cookie ni version, et aucun identifiant de la machine hors du jeton `DCDevice`, que
    /// seul Apple sait lire : deux champs, trois en-têtes.
    @Test("L'essai emporte exactement trois en-têtes, s'annonce « Quotum », et son corps deux champs")
    func entetesDeLEssai() throws {
        let requete = try FixturesLicence.requeteEssai()
        #expect(requete.httpMethod == "POST")
        #expect(Set((requete.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
                == ["content-type", "accept", "user-agent"])
        #expect(requete.value(forHTTPHeaderField: "User-Agent") == "Quotum")
        let corps = try #require(requete.httpBody)
        let objet = try #require(try JSONSerialization.jsonObject(with: corps) as? [String: Any])
        #expect(Set(objet.keys) == ["demande", "jeton_appareil"])
        #expect(requete.url?.scheme == "https")
        #expect(requete.url?.host() == (try FixturesLicence.requeteActivation()).url?.host())
    }

    /// Les requêtes des clés de lecture, nom par nom et rien de plus : la clé collée, et ce que
    /// chaque service exige pour la lire. Les deux requêtes AWS signent `content-type` (et
    /// `x-amz-target` pour les budgets) ; la signature se pose dans `authorization`.
    private static let entetesClesLecture: [String: Set<String>] = [
        "la dépense Claude Enterprise, par clé de lecture": ["x-api-key", "anthropic-version", "accept", "user-agent"],
        "AWS, l'identité qui signe": ["content-type", "x-amz-date", "authorization", "accept", "user-agent"],
        "AWS, les budgets": ["content-type", "x-amz-target", "x-amz-date", "authorization", "accept", "user-agent"],
        "Azure, le jeton": ["content-type", "accept", "user-agent"],
        "Azure, les permissions": ["authorization", "accept", "user-agent"],
        "Azure, les budgets": ["authorization", "accept", "user-agent"],
    ]

    /// La même promesse que pour les lecteurs, tenue pour les six requêtes des clés de lecture :
    /// un en-tête ajouté à l'une d'elles, quel qu'il soit, fait tomber ce test.
    @Test("Chaque requête d'une clé de lecture emporte exactement ses en-têtes, et rien de plus")
    func entetesDesClesDeLecture() throws {
        let toutes = try Self.requetesSortantes()
        for (destinataire, attendus) in Self.entetesClesLecture.sorted(by: { $0.key < $1.key }) {
            let trouvees = toutes.filter { $0.0 == destinataire }
            try #require(trouvees.count == 1, "\(destinataire) n'est plus énumérée une fois et une seule")
            let noms = Set((trouvees[0].1.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
            #expect(noms == attendus, "\(destinataire) : \(noms.sorted())")
        }
    }

    /// ⛔ La recharge automatique est une route de facturation, écartée par Q5 : aucune
    /// requête n'y mène. Et si l'une d'elles venait à porter `include_payment_method`, ce
    /// ne peut être qu'à `false` — à `true`, la réponse ramène le moyen de paiement.
    @Test("Aucune requête ne lit la facturation ni ne demande le moyen de paiement")
    func aucuneLectureDeFacturation() throws {
        for (destinataire, requete) in try Self.requetesSortantes() {
            let url = try #require(requete.url)
            #expect(!url.path().contains("auto_top_up"), "\(destinataire) vise la recharge automatique")
            // Chez Azure, `subscriptions/<id>` est la portée de toute ressource, pas un abonnement
            // payant : seules les deux routes de lecture y sont admises.
            if url.host() == DepenseAzure.hoteGestion {
                #expect(url.path().hasSuffix("/providers/Microsoft.Authorization/permissions")
                        || url.path().hasSuffix("/providers/Microsoft.Consumption/budgets"),
                        "\(destinataire) vise une autre route d'Azure")
            } else {
                #expect(!url.path().contains("subscriptions"), "\(destinataire) vise la facturation")
            }
            let parametres = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            for parametre in parametres where parametre.name.lowercased() == "include_payment_method" {
                #expect(parametre.value == "false", "\(destinataire) demande le moyen de paiement")
            }
        }
    }

    /// Les deux `GET` mesurés le 29/09, chemin et paramètres exacts : la réserve n'en porte
    /// aucun, l'historique son seul curseur — encodé, il ne glisse pas un second paramètre.
    @Test("La réserve et l'historique Codex : chemins exacts, jeton sur la requête, nom propre")
    func reserveEtHistoriqueCodex() throws {
        let reserve = try #require(ReserveCodex.requeteReserve(jeton: Self.jetonCodex))
        let historique = try #require(ReserveCodex.requeteHistorique(jeton: Self.jetonCodex,
                                                                     curseur: "page 2&x=1"))
        let premiere = try #require(ReserveCodex.requeteHistorique(jeton: Self.jetonCodex, curseur: nil))
        #expect(reserve.url?.absoluteString
                == "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")
        #expect(premiere.url?.absoluteString
                == "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/history")
        let composants = try #require(historique.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        })
        #expect(composants.path == "/backend-api/wham/rate-limit-reset-credits/history")
        #expect(composants.queryItems == [URLQueryItem(name: "cursor", value: "page 2&x=1")])

        for requete in [reserve, historique, premiere] {
            #expect(requete.httpMethod == "GET")
            #expect(requete.httpBody == nil)
            #expect(requete.value(forHTTPHeaderField: "Authorization") == "Bearer jeton-de-test")
            #expect(requete.value(forHTTPHeaderField: "User-Agent") == "Quotum")
            #expect(requete.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "compte-de-test")
            let noms = Set((requete.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
            #expect(noms == ["authorization", "accept", "user-agent", "chatgpt-account-id"])
        }
    }

    /// Kilo n'a pas encore de `Fournisseur` : son jeu d'en-têtes se pince ici, hors de
    /// `entetesAttendus`, jusqu'au branchement.
    @Test("Kilo Pass : un GET de lecture, jeton sur la requête, trois en-têtes et rien d'autre")
    func entetesDeKilo() throws {
        let requete = try #require(QuotaKilo.requete(jeton: Self.jetonKilo, delai: 8))
        #expect(requete.httpMethod == "GET")
        #expect(requete.httpBody == nil)
        #expect(requete.value(forHTTPHeaderField: "Authorization") == "Bearer jeton-de-test")
        #expect(requete.value(forHTTPHeaderField: "User-Agent") == "Quotum")
        let noms = Set((requete.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        #expect(noms == ["authorization", "accept", "user-agent"])
    }

    @Test("L'app s'annonce auprès de ChatGPT sous son propre nom")
    func agentDeChatGPT() throws {
        let requete = try #require(QuotaCodex.requete(jeton: Self.jetonCodex, delai: 8))
        #expect(requete.value(forHTTPHeaderField: "User-Agent") == "Quotum")
    }
}
