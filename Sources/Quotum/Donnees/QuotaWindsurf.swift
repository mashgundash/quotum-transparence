import Foundation
import SQLite3

/// Ce qu'un relevé de Windsurf établit. Pendant de `ReleveChatGPT`, à une réserve
/// près qui change tout à l'affichage : **deux voies alimentent ce relevé et elles
/// n'ont pas la même fraîcheur**. L'appel direct date sa mesure de l'instant ; le
/// cache de l'éditeur, lui, date de la dernière fois que l'IDE a écrit — ce peut
/// être il y a une semaine. `mesureA` porte cette date dans les deux cas, et c'est
/// la seule chose qui empêche de présenter un chiffre périmé comme frais.
struct ReleveWindsurf: Sendable, Equatable {
    var quota: Quota
    var mesureA: Date = .now
    var courriel: String?
    var plan: String?
}

/// Ce qu'une tentative de relevé a établi. Même partition que `ReleveCodex` : une
/// clé refusée ne dit rien du quota, une coupure encore moins.
enum ResultatWindsurf: Sendable, Equatable {
    case releve(ReleveWindsurf)
    /// Clé présente mais refusée. Elle se retrouve par une reconnexion dans l'IDE.
    case reconnexionNecessaire
    /// L'appel et le cache n'ont rien établi.
    case indetermine
    /// Ni installation, ni identifiants sur cette machine : rien à relever.
    case aucun
}

/// La clé d'API que Devin Desktop dépose sur le disque. Elle sert à un appel et
/// n'est ni journalisée, ni recopiée ailleurs.
struct CleWindsurf: Sendable, Equatable {
    let valeur: String
    /// `api_server_url` de `credentials.toml`, quand il est déclaré. Une installation
    /// d'entreprise pointe ailleurs que le serveur public, et envoyer la clé au
    /// serveur public dans ce cas la livrerait à un tiers.
    let hote: String?
}

enum LectureCleWindsurf: Sendable, Equatable {
    case cle(CleWindsurf)
    /// Aucun identifiant : l'outil n'est pas installé, ou personne ne s'y est connecté.
    case absent
    /// Lecture empêchée. Rien n'est établi : la clé peut être là, intacte.
    case empechee
}

/// Relevé du quota de Windsurf — renommé **Devin Desktop** en cours de route, d'où
/// les deux noms qui cohabitent partout ici.
///
/// Deux voies, et elles se complètent au lieu de se doubler :
/// - le **cache de l'éditeur**, une base SQLite lue en place, sans réseau ni
///   identifiant — mais dont la fraîcheur est celle de la dernière écriture de l'IDE ;
/// - l'**appel direct**, qui date sa mesure de l'instant, et réclame la clé d'API.
///
/// ⛔ Le piège central de ce fournisseur : **ses pourcentages sont des restants**,
/// là où Anthropic et OpenAI publient des consommés. L'inversion est faite une seule
/// fois, dans `fenetre(libelle:sorte:restant:recharge:absenceEstZero:)`, et nulle part ailleurs.
enum QuotaWindsurf {
    static let hote = "https://server.codeium.com"
    static let chemin = "/exa.seat_management_pb.SeatManagementService/GetUserStatus"

    /// L'app s'annonce sous son propre nom, ici comme ailleurs. Le protocole réclame
    /// un nom d'IDE et un nom d'extension : ce sont deux champs de plus à remplir, pas
    /// deux occasions de se faire passer pour le client officiel.
    static let agent = "Quotum"
    static let agentProtocole = "quotum"
    static let versionProtocole = "1.0"

    /// Le produit a été renommé Devin Desktop, et le dossier de données suit le nom
    /// sous lequel l'installation a été faite. Sonder les deux — supposer l'un ferait
    /// conclure « pas installé » sur une machine qui l'a.
    static let dossiersApplication = ["Windsurf", "Devin"]

    static let cleCache = "windsurf.settings.cachedPlanInfo"
    static let cleIdentite = "codeium.windsurf"
    static let cleJeton = "windsurfAuthStatus"

    // MARK: - Emplacements

    static func basesEtat(accueil: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        dossiersApplication.map {
            accueil.appendingPathComponent("Library/Application Support/\($0)/User/globalStorage/state.vscdb")
        }
    }

    /// `XDG_DATA_HOME` déplace tout `~/.local/share`, `credentials.toml` compris —
    /// c'est la définition de ce chemin, pas une option qu'on ajoute.
    ///
    /// Portée mesurée : cette lecture porte sur l'environnement de processus de
    /// Quotum, qui reflète l'environnement de session GUI (`launchctl setenv`), pas un
    /// profil de shell. Un `export XDG_DATA_HOME=…` dans `~/.zshrc` seul n'atteint
    /// donc pas l'app lancée depuis le Finder, le Dock ou le LaunchAgent — voir la note
    /// équivalente sur `QuotaGrok.variableCle`.
    static func fichierIdentifiants(
        environnement: [String: String] = ProcessInfo.processInfo.environment,
        accueil: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let declare = environnement["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let declare, !declare.isEmpty else {
            return accueil.appendingPathComponent(".local/share/devin/credentials.toml")
        }
        return URL(fileURLWithPath: (declare as NSString).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent("devin/credentials.toml")
    }

    // MARK: - Ce que les deux voies publient

    /// Le dénominateur commun des deux voies : elles portent les mêmes grandeurs sous
    /// des noms de champs différents. Les règles délicates — l'inversion et
    /// l'échéance sans pourcentage — ne s'écrivent donc qu'une fois.
    struct Mesure: Sendable, Equatable {
        var restantQuotidien: Double?
        var restantHebdomadaire: Double?
        var rechargeQuotidienne: Date?
        var rechargeHebdomadaire: Date?
        var masquerQuotidienne = false
    }

    /// `absenceEstZero` distingue les deux voies : seul l'appel direct est du
    /// Connect/protobuf, où proto3 omet un scalaire nul — un restant à zéro y
    /// disparaît donc du JSON, et l'absence se lit comme un zéro. Le cache de
    /// l'éditeur n'a pas cette garantie : ses champs ne sont pas proto3 (deux
    /// orthographes du même horodatage y cohabitent, ce qu'une sérialisation proto3
    /// ne produit jamais), et rien n'y établit qu'un champ omis vaille zéro plutôt
    /// que renommé ou abandonné par une version suivante de l'éditeur.
    static func composer(_ mesure: Mesure, absenceEstZero: Bool) -> Quota? {
        // `hideDailyQuota` retire la fenêtre du tableau, il ne la met pas à zéro.
        let quotidienne = mesure.masquerQuotidienne
            ? nil
            : fenetre(libelle: Fenetre.libelleVingtQuatreHeures,
                      sorte: .vingtQuatreHeures,
                      restant: mesure.restantQuotidien,
                      recharge: mesure.rechargeQuotidienne,
                      absenceEstZero: absenceEstZero)
        let hebdomadaire = fenetre(libelle: Fenetre.libelleSeptJours,
                                   sorte: .septJours,
                                   restant: mesure.restantHebdomadaire,
                                   recharge: mesure.rechargeHebdomadaire,
                                   absenceEstZero: absenceEstZero)
        // La courte d'abord : l'ordre de la liste est celui du tiroir.
        let fenetres = [quotidienne, hebdomadaire].compactMap { $0 }
        return fenetres.isEmpty ? nil : Quota(fenetres)
    }

    private static func fenetre(libelle: String, sorte: Fenetre.Sorte, restant: Double?,
                                recharge: Date?, absenceEstZero: Bool) -> Fenetre? {
        guard let restant else {
            // ⛔ Un restant absent ne vaut « épuisé » que sur la voie qui le fonde
            // (proto3) — voir `composer`. Ailleurs, une échéance sans pourcentage est
            // une mesure incomplète, pas un compte à sec : ne rien fabriquer.
            guard absenceEstZero, let recharge else { return nil }
            return Fenetre(libelle: libelle, sorte: sorte, utilisation: 100, seRechargeA: recharge)
        }
        // Une valeur non finie n'est pas un zéro omis : elle n'établit rien, et la
        // traiter comme une saturation inventerait le pire.
        guard restant.isFinite else { return nil }
        // ⛔ Windsurf publie ce qu'il **reste**, à l'inverse d'Anthropic et d'OpenAI.
        // Sans cette soustraction, un compte plein s'affiche vide et réciproquement.
        // La durée reste absente : aucun champ ne la publie, et la déduire du nom de
        // la fenêtre serait la réinventer.
        return Fenetre(libelle: libelle, sorte: sorte, utilisation: 100 - restant,
                       seRechargeA: recharge)
    }

    // MARK: - Voie du cache — aucun appel réseau

    private struct PlanEnCache: Decodable {
        struct Usage: Decodable {
            var restantQuotidien: Double?
            var restantHebdomadaire: Double?
            var rechargeQuotidienne: Horodatage?
            var rechargeQuotidienneUnix: Horodatage?
            var rechargeHebdomadaire: Horodatage?
            var rechargeHebdomadaireUnix: Horodatage?
            var masquerQuotidienne: Bool?

            enum CodingKeys: String, CodingKey {
                case restantQuotidien = "dailyRemainingPercent"
                case restantHebdomadaire = "weeklyRemainingPercent"
                case rechargeQuotidienne = "dailyResetAt"
                case rechargeQuotidienneUnix = "dailyResetAtUnix"
                case rechargeHebdomadaire = "weeklyResetAt"
                case rechargeHebdomadaireUnix = "weeklyResetAtUnix"
                case masquerQuotidienne = "hideDailyQuota"
            }
        }

        var usage: Usage?
        var plan: String?

        enum CodingKeys: String, CodingKey {
            case usage = "quotaUsage"
            case plan = "planName"
        }
    }

    static func mesureDuCache(_ donnees: Data) -> Mesure? {
        guard let usage = try? JSONDecoder().decode(PlanEnCache.self, from: donnees).usage else {
            return nil
        }
        return Mesure(restantQuotidien: usage.restantQuotidien,
                      restantHebdomadaire: usage.restantHebdomadaire,
                      // L'epoch et la date lisible disent la même chose ; le premier
                      // présent suffit, et `Horodatage` accepte les deux écritures.
                      rechargeQuotidienne: usage.rechargeQuotidienneUnix?.date ?? usage.rechargeQuotidienne?.date,
                      rechargeHebdomadaire: usage.rechargeHebdomadaireUnix?.date ?? usage.rechargeHebdomadaire?.date,
                      masquerQuotidienne: usage.masquerQuotidienne ?? false)
    }

    static func decoderCache(_ donnees: Data) -> Quota? {
        // Pas de garantie proto3 sur ce format : une absence reste une absence.
        if let quota = mesureDuCache(donnees).flatMap({ composer($0, absenceEstZero: false) }) {
            return quota
        }
        return fenetreDesMessages(donnees).map { Quota([$0]) }
    }

    private struct CompteursEnCache: Decodable {
        struct Usage: Decodable {
            var dotation: Double?
            var consommes: Double?
            var restants: Double?

            enum CodingKeys: String, CodingKey {
                case dotation = "messages"
                case consommes = "usedMessages"
                case restants = "remainingMessages"
            }
        }

        var usage: Usage?
    }

    /// Un cache sans `quotaUsage` peut encore porter les compteurs de messages du plan.
    /// Ils ne font qu'un repli : ni leur période ni leur échéance ne sont publiées, d'où
    /// un `.cycle` sans date ni durée. Une dotation nulle ou absente ne fait rien — un
    /// rapport sans dénominateur n'est pas une mesure à zéro.
    static func fenetreDesMessages(_ donnees: Data) -> Fenetre? {
        guard let usage = (try? JSONDecoder().decode(CompteursEnCache.self, from: donnees))?.usage,
              let dotation = usage.dotation, dotation.isFinite, dotation > 0,
              let consommes = usage.consommes ?? usage.restants.map({ dotation - $0 }),
              consommes.isFinite else { return nil }
        return Fenetre(libelle: Fenetre.libelleCycle, sorte: .cycle, utilisation: 100 * consommes / dotation)
    }

    static func decoderPlanEnCache(_ donnees: Data) -> String? {
        nonVide((try? JSONDecoder().decode(PlanEnCache.self, from: donnees))?.plan)
    }

    private struct IdentiteEnCache: Decodable {
        struct Config: Decodable {
            var dernierCourriel: String?

            enum CodingKeys: String, CodingKey {
                case dernierCourriel = "lastLoginEmail"
            }
        }

        var config: Config?

        enum CodingKeys: String, CodingKey {
            case config = "configInfo"
        }
    }

    static func decoderCourriel(_ donnees: Data) -> String? {
        nonVide((try? JSONDecoder().decode(IdentiteEnCache.self, from: donnees))?.config?.dernierCourriel)
    }

    // MARK: - Voie de l'appel direct

    /// ⚠️ Deux écritures plausibles de la même réponse : le descripteur du client
    /// officiel range les champs sous `userStatus.planStatus` (la formule sous
    /// `…planStatus.planInfo`), la première version de ce lecteur les lisait à la racine.
    /// Aucune réponse réelle n'a tranché : les deux sont acceptées, et se tromper coûte
    /// une fenêtre absente, jamais une fenêtre fausse. Les champs : `BlocStatut`, plus bas.
    private struct ReponseStatut: Decodable {
        var imbrique: BlocStatut?
        var racine: BlocStatut?

        init(from decodeur: Decoder) throws {
            let conteneur = try decodeur.container(keyedBy: Cles.self)
            // Chaque écriture à part : à la racine, `planStatus` peut être une chaîne.
            racine = try? BlocStatut(from: decodeur)
            imbrique = (try? conteneur.nestedContainer(keyedBy: Cles.self, forKey: .statutUtilisateur))
                .flatMap { try? $0.decode(BlocStatut.self, forKey: .statutPlan) }
        }

        enum Cles: String, CodingKey { case statutUtilisateur = "userStatus", statutPlan = "planStatus" }

        /// ⛔ En bloc, jamais champ par champ : proto3 omet un restant nul, et compléter
        /// l'imbriqué par la racine apparierait une échéance et un pourcentage étrangers.
        var bloc: BlocStatut? { imbrique?.porteUneMesure == true ? imbrique : racine }
        var plan: String? { nonVide(imbrique?.infoPlan?.plan) ?? nonVide(racine?.plan) }
    }

    static func mesureDuStatut(_ donnees: Data) -> Mesure? {
        (try? JSONDecoder().decode(ReponseStatut.self, from: donnees))?.bloc?.mesure
    }

    static func decoderStatut(_ donnees: Data) -> Quota? {
        // Corps Connect/protobuf : proto3 fonde ici la lecture d'une absence en zéro.
        mesureDuStatut(donnees).flatMap { composer($0, absenceEstZero: true) }
    }

    static func decoderPlan(_ donnees: Data) -> String? {
        (try? JSONDecoder().decode(ReponseStatut.self, from: donnees))?.plan
    }

    // MARK: - Requête

    enum ReponseAPI: Sendable, Equatable {
        case donnees(Data)
        case cleRefusee
        case echec
    }

    /// ⚠️ La clé voyage **dans le corps**, sous `metadata.apiKey` : cet endpoint
    /// n'attend pas d'`Authorization`. Ce n'est pas un contournement de la garde
    /// maison, c'en est le prolongement — aucun identifiant ne se pose dans la
    /// configuration de session, et celui-ci ne se pose même pas en en-tête.
    static func requete(cle: CleWindsurf, delai: TimeInterval) -> URLRequest? {
        guard let url = adresse(cle: cle), let corps = corps(cle: cle) else { return nil }
        var requete = URLRequest(url: url)
        requete.httpMethod = "POST"
        requete.timeoutInterval = delai
        requete.httpBody = corps
        requete.setValue("application/json", forHTTPHeaderField: "Content-Type")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        requete.setValue(agent, forHTTPHeaderField: "User-Agent")
        return requete
    }

    /// Domaines à qui la clé peut partir. ⛔ Une allowlist, jamais une liste noire :
    /// `api_server_url` vient d'un fichier du disque, et la clé voyage **dans le corps**
    /// de la requête. Un hôte non reconnu la livrerait à un tiers.
    static let domainesAutorises = ["codeium.com", "windsurf.com", "devin.ai"]

    /// Le serveur déclaré dans `credentials.toml` prime, mais il n'est **pas** une
    /// autorisation d'envoyer la clé n'importe où.
    ///
    /// ⚠️ Vérifier le seul schéma ne suffit pas : `https://server.codeium.com@evil.example`
    /// a l'air légitime dans le fichier, et son hôte est pourtant `evil.example` — le
    /// reste est un userinfo. D'où le refus de tout identifiant d'utilisateur, et le
    /// point exigé devant le domaine, sans lequel `evilcodeium.com` passerait.
    static func adresse(cle: CleWindsurf) -> URL? {
        let racine = nonVide(cle.hote) ?? hote
        guard let url = URL(string: racine + chemin), urlAutorisee(url) else { return nil }
        return url
    }

    static func urlAutorisee(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user(percentEncoded: true) == nil,
              url.password(percentEncoded: true) == nil,
              url.query(percentEncoded: true) == nil,
              url.fragment(percentEncoded: true) == nil,
              let hote = url.host(percentEncoded: true),
              // Un hôte percent-encodé se lit différemment selon qui le décode : le
              // refuser supprime l'écart entre ce qui est validé ici et ce que la pile
              // réseau joindra.
              hote == url.host(percentEncoded: false),
              hoteAutorise(hote),
              url.port.map((1...65_535).contains) ?? true
        else { return false }
        return true
    }

    static func hoteAutorise(_ hote: String) -> Bool {
        let bas = hote.lowercased()
        return domainesAutorises.contains { bas == $0 || bas.hasSuffix("." + $0) }
    }

    static func corps(cle: CleWindsurf) -> Data? {
        let metadonnees = ["apiKey": cle.valeur,
                           "ideName": agentProtocole,
                           "ideVersion": versionProtocole,
                           "extensionName": agentProtocole,
                           "extensionVersion": versionProtocole,
                           "locale": "fr"]
        return try? JSONSerialization.data(withJSONObject: ["metadata": metadonnees])
    }

    /// Un corps de requête est **rejoué** sur la cible d'une redirection 307/308 —
    /// ici, la clé d'API de l'utilisateur, chez un hôte que personne n'a choisi.
    /// Aucune redirection n'est donc suivie : l'appel échoue, et c'est le bon échec.
    final class RefusDeRedirection: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            Journal.donnees.notice("Quota Windsurf : redirection refusée (statut \(response.statusCode))")
            completionHandler(nil)
        }
    }

    static func interpreter(code: Int, donnees: Data) -> ReponseAPI {
        switch code {
        case 200: .donnees(donnees)
        // Le protocole Connect rend l'échec d'authentification en statut HTTP, et
        // seul le 401 dit que la clé est morte. ⚠️ Le 403 est un refus de permission —
        // côté Anthropic c'est le statut d'un jeton valide auquel il manque un scope,
        // et Warp le traite pareil. Réclamer une reconnexion dessus enverrait
        // l'utilisateur refaire un geste qui n'y changerait rien.
        case 401: .cleRefusee
        default: .echec
        }
    }

    private static func charger(cle: CleWindsurf,
                                session: URLSession,
                                delai: TimeInterval) async -> ReponseAPI {
        guard let requete = requete(cle: cle, delai: delai) else { return .echec }
        do {
            let (donnees, reponse) = try await session.data(for: requete,
                                                            delegate: RefusDeRedirection())
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            journaliser(code: code)
            return interpreter(code: code, donnees: donnees)
        } catch {
            Journal.donnees.debug("Quota Windsurf : serveur injoignable")
            return .echec
        }
    }

    private static func journaliser(code: Int) {
        switch code {
        case 200:
            break
        case 401:
            Journal.donnees.notice("Quota Windsurf : clé refusée (401), reconnexion à faire dans l'IDE")
        case 403:
            Journal.donnees.notice("Quota Windsurf : permission refusée (403) — la clé, elle, est valable")
        default:
            Journal.donnees.notice("Quota Windsurf : statut HTTP \(code)")
        }
    }

    // MARK: - Identifiants sur le disque

    /// Une valeur de `credentials.toml`. Le format n'est pas analysé dans sa
    /// généralité : on cherche une affectation de premier niveau, ce que le fichier
    /// contient réellement. Les chaînes multilignes et les échappements ne sont pas
    /// couverts — une clé d'API n'en porte pas.
    static func valeurTOML(_ texte: String, cle nom: String) -> String? {
        for ligne in texte.split(separator: "\n", omittingEmptySubsequences: false) {
            let coupe = ligne.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !coupe.hasPrefix("#"), let egal = coupe.firstIndex(of: "=") else { continue }
            guard coupe[coupe.startIndex..<egal].trimmingCharacters(in: .whitespaces) == nom else { continue }
            return valeurNue(String(coupe[coupe.index(after: egal)...]))
        }
        return nil
    }

    private static func valeurNue(_ brut: String) -> String? {
        let coupe = brut.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ouvrant = coupe.first, ouvrant == "\"" || ouvrant == "'" else {
            // Valeur nue : ce qui suit un dièse est un commentaire de fin de ligne.
            return nonVide(coupe.split(separator: "#", maxSplits: 1).first.map(String.init))
        }
        let apresOuvrant = coupe.index(after: coupe.startIndex)
        guard let fermant = coupe[apresOuvrant...].firstIndex(of: ouvrant) else { return nil }
        return nonVide(String(coupe[apresOuvrant..<fermant]))
    }

    static func cleDuFichier(_ url: URL) -> LectureCleWindsurf {
        let texte: String
        do {
            texte = try String(contentsOf: url, encoding: .utf8)
        } catch {
            guard estAbsence(error) else {
                Journal.donnees.notice("Windsurf : credentials.toml illisible (\(error))")
                return .empechee
            }
            return .absent
        }
        guard let valeur = valeurTOML(texte, cle: "windsurf_api_key") else { return .absent }
        return .cle(CleWindsurf(valeur: valeur, hote: valeurTOML(texte, cle: "api_server_url")))
    }

    private struct EtatAuthentification: Decodable {
        var cle: String?

        enum CodingKeys: String, CodingKey {
            case cle = "apiKey"
        }
    }

    static func cleDeLaBase(_ donnees: Data) -> String? {
        nonVide((try? JSONDecoder().decode(EtatAuthentification.self, from: donnees))?.cle)
    }

    // MARK: - Relevé

    /// Ce que la base d'état de l'éditeur a livré. `lisible` sépare « la base n'a
    /// rien » de « la base n'a pas pu s'ouvrir » : le premier conclut, le second non.
    /// `presente` distingue à son tour « n'a pas pu s'ouvrir » d'« absente » : les
    /// deux ne relisent pas `lisible = false`, mais seule l'absence dit que l'éditeur
    /// n'est pas sur cette machine — une base présente et illisible reste indéterminée.
    struct ContenuBase: Sendable, Equatable {
        var lisible = false
        var presente = false
        var cache: Data?
        var identite: Data?
        var jeton: Data?
        /// Dernière écriture du fichier — la seule date disponible pour horodater le
        /// cache. Elle majore sa fraîcheur, ce qui suffit à ne pas le dire frais.
        var modifieA: Date?
    }

    static func lireBase(_ url: URL) -> ContenuBase {
        let presente = FileManager.default.fileExists(atPath: url.path)
        guard let valeurs = BaseEtat.valeurs([cleCache, cleIdentite, cleJeton], base: url) else {
            return ContenuBase(presente: presente)
        }
        let attributs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ContenuBase(lisible: true,
                           presente: presente,
                           cache: valeurs[cleCache],
                           identite: valeurs[cleIdentite],
                           jeton: valeurs[cleJeton],
                           modifieA: attributs?[.modificationDate] as? Date)
    }

    /// La clé du fichier prime sur celle de la base : elle porte aussi le serveur.
    static func choisirCle(fichier: LectureCleWindsurf, base: ContenuBase) -> LectureCleWindsurf {
        if case .cle = fichier { return fichier }
        guard let jeton = base.jeton, let valeur = cleDeLaBase(jeton) else { return fichier }
        return .cle(CleWindsurf(valeur: valeur, hote: nil))
    }

    static func releveDuCache(_ base: ContenuBase) -> ReleveWindsurf? {
        guard let donnees = base.cache, let quota = decoderCache(donnees) else { return nil }
        return ReleveWindsurf(quota: quota,
                              mesureA: base.modifieA ?? .now,
                              courriel: base.identite.flatMap(decoderCourriel),
                              plan: decoderPlanEnCache(donnees))
    }

    /// Après le renommage, les deux dossiers coexistent souvent : l'ancienne base,
    /// déconnectée, ne doit pas masquer celle où vit la session. Une base qui porte une
    /// clé l'emporte, puis une base qui porte un cache, puis la première présente ; à
    /// égalité, la plus récemment écrite, puis l'ordre de `dossiersApplication`.
    static func choisirBase(_ contenus: [ContenuBase]) -> ContenuBase {
        let avecCle = contenus.filter { $0.jeton.flatMap(cleDeLaBase) != nil }
        let avecCache = contenus.filter { $0.cache.flatMap(decoderCache) != nil }
        for candidates in [avecCle, avecCache] {
            if let choisie = plusRecente(candidates) { return choisie }
        }
        return contenus.first(where: \.presente) ?? ContenuBase()
    }

    private static func plusRecente(_ contenus: [ContenuBase]) -> ContenuBase? {
        contenus.enumerated().min { a, b in
            let dateA = a.element.modifieA ?? .distantPast
            let dateB = b.element.modifieA ?? .distantPast
            return dateA != dateB ? dateA > dateB : a.offset < b.offset
        }?.element
    }

    static func relever(session: URLSession = Reseau.session,
                        delai: TimeInterval = 8,
                        accueil: URL = FileManager.default.homeDirectoryForCurrentUser,
                        environnement: [String: String] = ProcessInfo.processInfo.environment) async -> ResultatWindsurf {
        let bases = basesEtat(accueil: accueil)
        let fichier = fichierIdentifiants(environnement: environnement, accueil: accueil)
        let local = await HorsFil.executer { () -> (base: ContenuBase, fichier: LectureCleWindsurf) in
            let presentes = bases.filter { FileManager.default.fileExists(atPath: $0.path) }
            return (choisirBase(presentes.map(lireBase)), cleDuFichier(fichier))
        }

        guard case .cle(let cle) = choisirCle(fichier: local.fichier, base: local.base) else {
            // Sans clé, il reste le cache — et s'il n'y a ni base présente ni fichier,
            // c'est que l'outil n'est pas sur cette machine. Une base présente mais
            // illisible ne conclut pas à cette absence : `presente` la distingue.
            if let repli = releveDuCache(local.base) { return .releve(repli) }
            return local.base.presente || local.fichier == .empechee ? .indetermine : .aucun
        }

        let direct = await relever(cle: cle, session: session, delai: delai, base: local.base)
        // Un appel qui n'a rien établi ne doit pas effacer une mesure qui existe :
        // le cache est vieux, il n'est pas faux, et il porte sa date.
        if direct == .indetermine, let repli = releveDuCache(local.base) { return .releve(repli) }
        return direct
    }

    static func relever(cle: CleWindsurf,
                        session: URLSession = Reseau.session,
                        delai: TimeInterval = 8,
                        base: ContenuBase = ContenuBase()) async -> ResultatWindsurf {
        let reponse = await charger(cle: cle, session: session, delai: delai)
        let mesureA = Date()

        switch reponse {
        case .cleRefusee:
            return .reconnexionNecessaire
        case .echec:
            return .indetermine
        case .donnees(let donnees):
            guard let quota = decoderStatut(donnees) else { return .indetermine }
            return .releve(ReleveWindsurf(quota: quota,
                                          mesureA: mesureA,
                                          // Le statut ne nomme pas le compte : seul le
                                          // cache de l'éditeur porte le courriel.
                                          courriel: base.identite.flatMap(decoderCourriel),
                                          plan: decoderPlan(donnees)))
        }
    }

    // MARK: - Base d'état de l'éditeur

    /// Lecture en place de la base SQLite d'un éditeur dérivé de VS Code. Aucune
    /// dépendance : `libsqlite3` vient du SDK.
    enum BaseEtat {
        static let table = "ItemTable"

        /// Les valeurs demandées, ou `nil` si la base n'a pas pu s'ouvrir — la
        /// distinction porte du sens : une base vide conclut, une base illisible non.
        static func valeurs(_ cles: [String], base url: URL) -> [String: Data]? {
            guard let base = ouvrir(url) else { return nil }
            defer { sqlite3_close(base) }

            var requete: OpaquePointer?
            guard sqlite3_prepare_v2(base, "SELECT value FROM \(table) WHERE key = ?", -1, &requete, nil)
                == SQLITE_OK else {
                Journal.donnees.notice("Windsurf : table \(table) absente de la base d'état")
                sqlite3_finalize(requete)
                return nil
            }
            defer { sqlite3_finalize(requete) }

            var trouvees: [String: Data] = [:]
            for cle in cles {
                sqlite3_reset(requete)
                sqlite3_clear_bindings(requete)
                if let valeur = lire(requete, cle: cle) { trouvees[cle] = valeur }
            }
            return trouvees
        }

        private static func lire(_ requete: OpaquePointer?, cle: String) -> Data? {
            cle.withCString { pointeur -> Data? in
                // Le pointeur vit le temps de la fermeture, qui couvre le `step` :
                // SQLite n'a donc pas à copier la clé.
                guard sqlite3_bind_text(requete, 1, pointeur, -1, nil) == SQLITE_OK,
                      sqlite3_step(requete) == SQLITE_ROW else { return nil }
                let longueur = Int(sqlite3_column_bytes(requete, 0))
                guard longueur > 0, let octets = sqlite3_column_blob(requete, 0) else { return nil }
                return Data(bytes: octets, count: longueur)
            }
        }

        /// Deux tentatives, et l'ordre compte. La lecture ordinaire d'abord : elle
        /// tient compte du journal `-wal`, donc des dernières écritures de l'IDE.
        /// Elle échoue quand le `-shm` a disparu et que le dossier n'est pas
        /// inscriptible ; `immutable=1` passe alors outre le verrouillage — au prix
        /// d'ignorer le journal, donc de lire un état un peu plus ancien. Dans cet
        /// ordre, on ne perd de fraîcheur que là où il n'y avait rien à lire.
        private static func ouvrir(_ url: URL) -> OpaquePointer? {
            for immuable in [false, true] {
                var base: OpaquePointer?
                if sqlite3_open_v2(uri(url, immuable: immuable), &base,
                                   SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
                   let base {
                    sqlite3_busy_timeout(base, 250)
                    return base
                }
                sqlite3_close(base)
            }
            return nil
        }

        static func uri(_ url: URL, immuable: Bool) -> String {
            let adresse = URL(fileURLWithPath: url.path(percentEncoded: false)).absoluteString
            return immuable ? adresse + "?immutable=1" : adresse
        }
    }

    // MARK: - Menu

    private static func estAbsence(_ erreur: Error) -> Bool {
        let brute = erreur as NSError
        guard brute.domain == NSCocoaErrorDomain else { return false }
        return brute.code == NSFileReadNoSuchFileError || brute.code == NSFileNoSuchFileError
    }

    private static func nonVide(_ valeur: String?) -> String? {
        guard let coupe = valeur?.trimmingCharacters(in: .whitespacesAndNewlines), !coupe.isEmpty else {
            return nil
        }
        return coupe
    }
}

// MARK: - Champs de `GetUserStatus`

extension QuotaWindsurf {
    /// Les champs de quota, sous les mêmes noms aux deux endroits où ils peuvent se
    /// trouver. `planName` ne se lit qu'à la racine, `planInfo` que sous `planStatus`.
    fileprivate struct BlocStatut: Decodable {
        struct InfoPlan: Decodable {
            var plan: String?

            enum CodingKeys: String, CodingKey {
                case plan = "planName"
            }
        }

        var restantQuotidien: Double?
        var restantHebdomadaire: Double?
        var rechargeQuotidienne: Horodatage?
        var rechargeHebdomadaire: Horodatage?
        var masquerQuotidienne: Bool?
        var plan: String?
        var infoPlan: InfoPlan?

        enum CodingKeys: String, CodingKey {
            case restantQuotidien = "dailyQuotaRemainingPercent"
            case restantHebdomadaire = "weeklyQuotaRemainingPercent"
            case rechargeQuotidienne = "dailyQuotaResetAtUnix"
            case rechargeHebdomadaire = "weeklyQuotaResetAtUnix"
            case masquerQuotidienne = "hideDailyQuota"
            case plan = "planName"
            case infoPlan = "planInfo"
        }

        /// Les fenêtres restent strictes — une valeur mal typée y vaut un bloc illisible,
        /// jamais une fenêtre à moitié lue. La formule, elle, est annexe : `planName: 3` ne
        /// coûte qu'elle-même, pas les fenêtres valides du même bloc.
        init(from decoder: Decoder) throws {
            let boite = try decoder.container(keyedBy: CodingKeys.self)
            restantQuotidien = try boite.decodeIfPresent(Double.self, forKey: .restantQuotidien)
            restantHebdomadaire = try boite.decodeIfPresent(Double.self, forKey: .restantHebdomadaire)
            rechargeQuotidienne = try boite.decodeIfPresent(Horodatage.self, forKey: .rechargeQuotidienne)
            rechargeHebdomadaire = try boite.decodeIfPresent(Horodatage.self, forKey: .rechargeHebdomadaire)
            masquerQuotidienne = try boite.decodeIfPresent(Bool.self, forKey: .masquerQuotidienne)
            plan = (try? boite.decodeIfPresent(String.self, forKey: .plan)) ?? nil
            infoPlan = (try? boite.decodeIfPresent(InfoPlan.self, forKey: .infoPlan)) ?? nil
        }

        var porteUneMesure: Bool {
            restantQuotidien != nil || restantHebdomadaire != nil
                || rechargeQuotidienne?.date != nil || rechargeHebdomadaire?.date != nil
        }

        var mesure: Mesure {
            Mesure(restantQuotidien: restantQuotidien,
                   restantHebdomadaire: restantHebdomadaire,
                   rechargeQuotidienne: rechargeQuotidienne?.date,
                   rechargeHebdomadaire: rechargeHebdomadaire?.date,
                   masquerQuotidienne: masquerQuotidienne ?? false)
        }
    }
}
