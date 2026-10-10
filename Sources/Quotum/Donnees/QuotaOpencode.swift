import Foundation

/// Ce qu'un relevé direct d'opencode établit. ⚠️ Rien n'y nomme le compte : l'endpoint
/// ne publie aucune identité, l'entrée du fichier d'identifiants ne porte qu'une clé,
/// et la requête n'envoie ni en-tête de compte ni en-tête d'organisation. La ligne se
/// nommera donc d'après le fournisseur, jamais d'après un courriel qu'on n'a pas.
struct MesureOpencode: Sendable, Equatable {
    var quota: Quota
    var mesureA: Date = .now
    /// Le serveur a refusé une fenêtre faute de quota. ✅ Ici c'est une **constatation
    /// publiée** — `status` vaut `rate-limited` — et non une déduction sur le
    /// pourcentage. C'est le seul des fournisseurs implémentés à le dire en toutes
    /// lettres.
    var limiteAtteinte = false
    /// Échéance de la dernière fenêtre bloquante à se rouvrir.
    var retour: Date?
}

/// Ce que la lecture d'`auth.json` puis l'appel à l'API ont pu établir. Même partition
/// que `ReleveCodebuff`, augmentée d'un cas qui n'existe nulle part ailleurs : un
/// compte parfaitement authentifié mais **hors abonnement**, qui n'aura jamais de
/// mesure et que nulle reconnexion ne débloquera.
enum ReleveOpencode: Sendable, Equatable {
    case releve(MesureOpencode)
    /// Clé présente mais refusée. Ne dit rien du quota : le compte peut être plein,
    /// c'est l'accès qui manque. ⚠️ Il se retrouve en **recollant une clé** dans
    /// opencode, pas en refaisant un login — cette clé n'est pas obtenue par OAuth.
    case reconnexionNecessaire
    /// La clé est valable, mais le compte n'a pas l'abonnement qui ouvre cette route.
    /// Rien à mesurer, aujourd'hui ni demain : le distinguer de `.indetermine` évite
    /// de faire réessayer indéfiniment ce qui ne réussira pas.
    case sansAbonnement
    /// L'appel n'a rien établi — réseau coupé, statut inattendu, corps illisible.
    case indetermine
    /// Aucune clé opencode sur cette machine : rien à relever.
    case aucun
}

/// La clé qu'opencode garde sur le disque. ⚠️ Elle n'est pas posée par un login : c'est
/// l'utilisateur qui l'a collée une fois dans opencode. Elle sert à un appel et n'est
/// ni copiée sur disque, ni journalisée, ni conservée au-delà du relevé.
struct CleOpencode: Sendable {
    let valeur: String
}

/// Ce qu'une lecture d'`auth.json` a établi — même partition que `LectureCodebuff`,
/// pour la même raison : un fichier illisible et un poste sans clé se ressemblent, et
/// un seul des deux dit quelque chose du compte.
enum LectureOpencode: Sendable {
    case cle(CleOpencode)
    /// Aucun fichier, ou un fichier lisible sans entrée `opencode-go`.
    case absent
    /// Lecture empêchée — droits refusés, contenu inexploitable. Rien n'est établi.
    case empechee
}

/// Le fichier d'identifiants d'opencode. Il range **un fournisseur par clé** — la clé
/// d'opencode y voisine avec celles d'Anthropic, d'OpenAI et des autres.
enum IdentifiantsOpencode {
    /// Le nom de l'entrée qui porte l'abonnement d'opencode, et la seule qu'on lise.
    static let fournisseur = "opencode-go"

    /// ⚠️ C'est **`XDG_DATA_HOME`** qui déplace ce fichier, par définition de
    /// `~/.local/share` — et **non `OPENCODE_CONFIG_DIR`**, qui ne déplace que la
    /// configuration. Honorer la seconde ferait chercher la clé là où elle n'est
    /// jamais, et conclure à l'absence d'abonnement sur un poste équipé.
    ///
    /// Portée mesurée : cette lecture porte sur l'environnement de processus de
    /// Quotum, qui reflète l'environnement de session GUI (`launchctl setenv`), pas un
    /// profil de shell. Un `export XDG_DATA_HOME=…` dans `~/.zshrc` seul n'atteint
    /// donc pas l'app lancée depuis le Finder, le Dock ou le LaunchAgent — voir la note
    /// équivalente sur `QuotaGrok.variableCle`.
    static func fichier(environnement: [String: String] = ProcessInfo.processInfo.environment,
                        accueil: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let declare = environnement["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let declare, !declare.isEmpty else {
            return accueil.appendingPathComponent(".local/share/opencode/auth.json")
        }
        return URL(fileURLWithPath: (declare as NSString).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent("opencode/auth.json")
    }

    static func cle(fichier url: URL? = nil) async -> LectureOpencode {
        let cible = url ?? fichier()
        return await HorsFil.executer { lire(cible) }
    }

    static func lire(_ url: URL) -> LectureOpencode {
        let donnees: Data
        do {
            donnees = try Data(contentsOf: url)
        } catch {
            guard estAbsence(error) else {
                Journal.donnees.notice("opencode : auth.json illisible (\(error))")
                return .empechee
            }
            Journal.donnees.debug("opencode : aucun auth.json sur cette machine")
            return .absent
        }
        return classer(donnees)
    }

    /// ⛔ L'entrée `opencode-go` et elle seule. Se rabattre sur un voisin enverrait à
    /// opencode la clé d'un autre service — et le fichier en contient d'ordinaire
    /// plusieurs.
    static func classer(_ donnees: Data) -> LectureOpencode {
        guard let entrees = try? JSONDecoder().decode([String: Entree].self, from: donnees) else {
            Journal.donnees.notice("opencode : auth.json lu mais inexploitable")
            return .empechee
        }
        guard let valeur = nonVide(entrees[fournisseur]?.cle) else { return .absent }
        return .cle(CleOpencode(valeur: valeur))
    }

    /// Une entrée d'un autre fournisseur a une autre forme — jeton OAuth, date
    /// d'expiration, voire une valeur qui n'est pas un objet. Cette lecture ne jette
    /// donc jamais : sans cela, un voisin inattendu emporterait le fichier entier et
    /// ferait disparaître une clé parfaitement lisible.
    ///
    /// `type` n'est pas consulté : la seule chose dont l'appel ait besoin est `key`, et
    /// une entrée qui ne la porte pas ne mène nulle part de toute façon.
    private struct Entree: Decodable {
        var cle: String?

        init(from decodeur: Decoder) throws {
            guard let conteneur = try? decodeur.container(keyedBy: CodingKeys.self) else { return }
            cle = try? conteneur.decodeIfPresent(String.self, forKey: .cle)
        }

        enum CodingKeys: String, CodingKey {
            case cle = "key"
        }
    }

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

/// Relevé direct du quota opencode. Trois fenêtres — c'est le mieux doté des
/// fournisseurs implémentés — et le seul dont l'épuisement soit **publié** plutôt que
/// déduit d'un pourcentage.
enum QuotaOpencode {
    static let hote = "https://opencode.ai"
    static let chemin = "/zen/go/v1/usage"

    /// L'app s'annonce sous son propre nom. Se faire passer pour le client officiel
    /// stabiliserait peut-être l'accès — c'est une infraction d'une autre nature que
    /// de lire une clé qu'on a le droit de lire.
    static let agent = "Quotum"

    /// ⛔ Aucune durée n'est publiée : les trois fenêtres vivent côté serveur et la
    /// réponse ne donne que des noms de clés. « 5 h » pour la glissante serait une
    /// convention de client, pas une mesure — d'où un libellé qui ne chiffre rien.
    static let libelleGlissante = "Fenêtre glissante"
    static let libelleSemaine = "Cette semaine"
    static let libelleMois = "Ce mois"

    /// Les deux valeurs publiées par `status`. ✅ `rate-limited` établit l'épuisement
    /// sans qu'on ait à l'inférer d'un pourcentage à 100 — c'est rare et c'est précieux.
    /// ⚠️ Une troisième valeur ne se range pas au hasard avec l'une des deux : elle
    /// laisse la fenêtre vivre de son pourcentage, sans rien conclure sur le blocage.
    enum StatutFenetre: String, Sendable, CaseIterable {
        case ouverte = "ok"
        case epuisee = "rate-limited"
    }

    /// Le nom de l'erreur que la route rend au compte sans abonnement. Elle arrive en
    /// **403**, et ce statut-là ne se confond donc pas avec le 401 d'une clé refusée.
    static let erreurSansAbonnement = "EntitlementError"

    /// Ce qu'un appel a rapporté. Trois refus distincts, parce qu'ils appellent trois
    /// gestes différents : recoller une clé, souscrire, ou ne rien faire du tout.
    enum ReponseAPI: Sendable, Equatable {
        case donnees(Data)
        case cleRefusee
        case sansAbonnement
        case echec
    }

    static func relever(session: URLSession = Reseau.session,
                        delai: TimeInterval = 8) async -> ReleveOpencode {
        switch await IdentifiantsOpencode.cle() {
        case .cle(let cle):
            return await relever(cle: cle, session: session, delai: delai)
        case .absent:
            return .aucun
        // Une lecture empêchée n'établit pas l'absence de clé : la prendre pour telle
        // effacerait une mesure que rien n'a infirmée.
        case .empechee:
            return .indetermine
        }
    }

    static func relever(cle: CleOpencode,
                        session: URLSession = Reseau.session,
                        delai: TimeInterval = 8) async -> ReleveOpencode {
        let reponse = await charger(cle: cle, session: session, delai: delai)
        let mesureA = Date()

        switch reponse {
        case .cleRefusee:
            return .reconnexionNecessaire
        case .sansAbonnement:
            return .sansAbonnement
        case .echec:
            return .indetermine
        case .donnees(let donnees):
            guard let quota = decoderUsage(donnees, mesureA: mesureA) else { return .indetermine }
            let blocage = decoderBlocage(donnees, mesureA: mesureA)
            return .releve(MesureOpencode(quota: quota,
                                          mesureA: mesureA,
                                          limiteAtteinte: blocage.atteinte,
                                          retour: blocage.retour))
        }
    }

    static func requete(cle: CleOpencode, delai: TimeInterval) -> URLRequest? {
        guard let url = URL(string: hote + chemin), valeurDEnteteValide(cle.valeur) else {
            return nil
        }
        var requete = URLRequest(url: url)
        requete.httpMethod = "GET"
        requete.timeoutInterval = delai
        // ⚠️ La clé se pose **sur la requête** : un en-tête d'identification placé dans
        // la configuration de session est rejoué vers l'hôte cible d'une redirection,
        // autre domaine compris.
        requete.setValue("Bearer \(cle.valeur)", forHTTPHeaderField: "Authorization")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue(agent, forHTTPHeaderField: "User-Agent")
        // La route ne réclame ni en-tête de compte ni en-tête d'organisation : la clé
        // désigne à elle seule le compte, et rien d'autre n'a à partir avec elle.
        return requete
    }

    /// Un en-tête ne porte que de l'ASCII imprimable : un saut de ligne y ouvrirait une
    /// injection d'en-tête, et un caractère accentué en sortirait l'encodage. Une clé
    /// qui en sort n'est pas une clé — d'où le refus, plutôt qu'un échappement qui
    /// laisserait partir la valeur.
    static func valeurDEnteteValide(_ valeur: String) -> Bool {
        guard !valeur.isEmpty else { return false }
        return valeur.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }

    private static func charger(cle: CleOpencode,
                                session: URLSession,
                                delai: TimeInterval) async -> ReponseAPI {
        guard let requete = requete(cle: cle, delai: delai) else { return .echec }

        do {
            let (donnees, reponse) = try await session.data(for: requete)
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            journaliser(code: code, donnees: donnees)
            return interpreter(code: code, donnees: donnees)
        } catch {
            Journal.donnees.debug("Quota opencode : opencode.ai injoignable")
            return .echec
        }
    }

    /// ⚠️ Le 403 ne se replie pas sur le 401 : la clé y est valable, c'est
    /// l'abonnement qui manque, et proposer d'en recoller une n'y changerait rien.
    /// Un 403 qui ne nomme pas cette erreur-là n'établit rien — le ranger d'office
    /// avec les comptes sans abonnement affirmerait plus que ce qu'on sait.
    static func interpreter(code: Int, donnees: Data) -> ReponseAPI {
        switch code {
        case 200: .donnees(donnees)
        case 401: .cleRefusee
        case 403: estDefautDAbonnement(donnees) ? .sansAbonnement : .echec
        default: .echec
        }
    }

    /// L'enveloppe exacte de l'erreur n'est pas établie — seul son nom l'est. On
    /// cherche donc ce nom dans le corps plutôt que d'inventer un schéma qui ne
    /// décoderait rien. La lecture est bornée : un corps d'erreur tient en quelques
    /// lignes, et rien n'oblige à parcourir ce qui suivrait.
    static func estDefautDAbonnement(_ donnees: Data) -> Bool {
        String(decoding: donnees.prefix(8_192), as: UTF8.self).contains(erreurSansAbonnement)
    }

    private static func journaliser(code: Int, donnees: Data) {
        switch code {
        case 200:
            break
        case 401:
            Journal.donnees.notice("Quota opencode : clé refusée (401), une clé neuve est à coller")
        case 403 where estDefautDAbonnement(donnees):
            Journal.donnees.notice("Quota opencode : compte sans abonnement, rien à mesurer")
        default:
            Journal.donnees.notice("Quota opencode : statut HTTP \(code)")
        }
    }

    // MARK: - Analyses pures

    private struct Enveloppe: Decodable {
        /// ⛔ Les trois fenêtres se reconnaissent au **nom de leur clé**, jamais à leur
        /// place dans la réponse : c'est ce que ces trois lignes établissent, et rien
        /// dans la suite du fichier ne doit revenir à un classement par position.
        struct Usage: Decodable {
            var glissante: EtatFenetre?
            var semaine: EtatFenetre?
            var mois: EtatFenetre?

            enum CodingKeys: String, CodingKey {
                case glissante = "rolling"
                case semaine = "weekly"
                case mois = "monthly"
            }
        }

        var usage: Usage?
    }

    private struct EtatFenetre: Decodable {
        var statut: String?
        var pourcentage: Double?
        var seRechargeA: Horodatage?
        /// Secondes avant la recharge, comptées depuis la réponse. Lu seulement quand
        /// `resetsAt` manque : une date publiée ne dépend pas de l'heure de réception.
        var rechargeDansSecondes: Double?

        enum CodingKeys: String, CodingKey {
            case statut = "status"
            case pourcentage = "percent"
            case seRechargeA = "resetsAt"
            case rechargeDansSecondes = "resetInSec"
        }

        /// Les trois premiers champs gardent leur exigence de type ; un `resetInSec`
        /// inattendu ne coûte que lui-même.
        init(from decoder: Decoder) throws {
            let boite = try decoder.container(keyedBy: CodingKeys.self)
            statut = try boite.decodeIfPresent(String.self, forKey: .statut)
            pourcentage = try boite.decodeIfPresent(Double.self, forKey: .pourcentage)
            seRechargeA = try boite.decodeIfPresent(Horodatage.self, forKey: .seRechargeA)
            rechargeDansSecondes = (try? boite.decodeIfPresent(Double.self, forKey: .rechargeDansSecondes)) ?? nil
        }

        func echeance(mesureA: Date) -> Date? {
            if let date = seRechargeA?.date { return date }
            guard let secondes = rechargeDansSecondes, secondes.isFinite, secondes >= 0 else { return nil }
            return mesureA.addingTimeInterval(secondes)
        }
    }

    /// `Quota([])` et `nil` ne disent pas la même chose. Le premier est une réponse
    /// d'usage comprise dont aucune fenêtre n'est exploitable — et **aucune fenêtre à
    /// 0 % n'est fabriquée**, qui afficherait plein un compte dont on ignore le niveau.
    /// Le second est un corps qui n'était pas une réponse d'usage : page d'erreur,
    /// corps tronqué, objet sans `usage`.
    static func decoderUsage(_ donnees: Data, mesureA: Date = .now) -> Quota? {
        guard let usage = usage(donnees) else { return nil }
        return Quota(nommees(usage).compactMap {
            fenetre(libelle: $0.libelle, sorte: $0.sorte, etat: $0.etat, mesureA: mesureA)
        })
    }

    /// ✅ L'épuisement est **lu**, pas déduit. Plusieurs fenêtres peuvent bloquer
    /// ensemble : le compte n'est rendu qu'à la réouverture de la dernière, d'où
    /// l'échéance la plus lointaine et non la première rencontrée.
    static func decoderBlocage(_ donnees: Data, mesureA: Date = .now) -> (atteinte: Bool, retour: Date?) {
        guard let usage = usage(donnees) else { return (false, nil) }
        let epuisees = nommees(usage).map(\.etat).filter { statut($0) == .epuisee }
        guard !epuisees.isEmpty else { return (false, nil) }
        return (true, epuisees.compactMap { $0.echeance(mesureA: mesureA) }.max())
    }

    /// `percent` est un consommé sur **0 à 100** : `1` vaut 1 %, `0.5` vaut 0,5 %.
    /// Rapporté par l'utilisateur d'un client tiers, dont la lecture en fraction
    /// affichait à sec un compte entamé à 1 %.
    /// La bande `]0 ; 1]`, refusée tant que l'échelle n'était pas établie, se lit donc
    /// comme le reste.
    static func consommation(_ brut: Double?) -> Double? {
        guard let brut, brut.isFinite else { return nil }
        // Une valeur négative n'est pas un compte à zéro : la ramener à zéro
        // afficherait une grille pleine sur une mesure aberrante.
        guard brut >= 0 else { return nil }
        return brut
    }

    private static func usage(_ donnees: Data) -> Enveloppe.Usage? {
        try? JSONDecoder().decode(Enveloppe.self, from: donnees).usage
    }

    /// La table qui associe chaque libellé à sa clé, dans l'ordre d'affichage — de la
    /// plus courte à la plus longue. ⛔ Une fenêtre absente disparaît de la liste
    /// **sans décaler les autres** : distribuer les libellés sur les fenêtres présentes
    /// donnerait le chiffre du mois à « Cette semaine ».
    private static func nommees(
        _ usage: Enveloppe.Usage
    ) -> [(libelle: String, sorte: Fenetre.Sorte, etat: EtatFenetre)] {
        [(libelleGlissante, Fenetre.Sorte.glissante, usage.glissante),
         (libelleSemaine, .septJours, usage.semaine),
         (libelleMois, .mois, usage.mois)]
            .compactMap { triplet in triplet.2.map { (triplet.0, triplet.1, $0) } }
    }

    private static func fenetre(libelle: String, sorte: Fenetre.Sorte, etat: EtatFenetre,
                                mesureA: Date) -> Fenetre? {
        let statut = statut(etat)
        if statut == nil, let brut = etat.statut {
            Journal.donnees.notice("Quota opencode : statut inconnu « \(brut) » sur « \(libelle) »")
        }
        // Refusée pour quota : le niveau vaut zéro, que la réponse chiffre la fenêtre
        // ou non. C'est la constatation du serveur, et elle prime sur le pourcentage.
        if statut == .epuisee {
            return Fenetre(libelle: libelle, sorte: sorte, utilisation: 100,
                           seRechargeA: etat.echeance(mesureA: mesureA))
        }
        // ⛔ Contrairement à Windsurf, rien n'établit qu'un pourcentage omis vaille
        // zéro : sans chiffre exploitable, la fenêtre n'existe pas — elle ne s'affiche
        // pas intacte. La durée reste absente, aucun champ ne la publie.
        guard let consommation = consommation(etat.pourcentage) else {
            if let brut = etat.pourcentage {
                Journal.donnees.notice("Quota opencode : pourcentage « \(brut) » inexploitable sur « \(libelle) »")
            }
            return nil
        }
        return Fenetre(libelle: libelle,
                       sorte: sorte,
                       utilisation: consommation,
                       seRechargeA: etat.echeance(mesureA: mesureA))
    }

    private static func statut(_ etat: EtatFenetre) -> StatutFenetre? {
        etat.statut.flatMap(StatutFenetre.init(rawValue:))
    }
}
