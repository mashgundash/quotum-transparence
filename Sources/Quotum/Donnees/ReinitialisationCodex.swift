import Foundation

/// Ce qu'une demande de réinitialisation a établi.
///
/// ⚠️ `.indetermine` ne dit **pas** que le crédit est intact : si la requête est partie
/// et que la réponse s'est perdue, il a pu être consommé quand même. C'est la seule
/// issue dont on ne peut rien conclure, et l'interface doit le dire ainsi — « on ne sait
/// pas » — plutôt que de laisser croire à un échec sans conséquence.
///
/// ⚠️ Écrite sur disque, dans les annonces en attente du registre : renommer un cas rend
/// le registre illisible, et désarme tout.
enum IssueReinitialisation: Sendable, Equatable, Codable {
    /// Le serveur a remis des fenêtres à zéro, et dit combien.
    case reinitialise(fenetres: Int)
    /// Rien à réinitialiser : le quota n'était pas entamé. ⚠️ Que le crédit soit épargné
    /// dans ce cas **n'est pas établi** — le vérifier en coûterait un.
    case rienAReinitialiser
    /// Plus aucun crédit disponible.
    case aucunCredit
    /// Ce crédit-là a déjà servi.
    case dejaConsomme
    /// Le jeton n'est plus valable.
    case reconnexionNecessaire
    /// Le jeton relu ne porte pas le compte qui a autorisé la dépense — ou n'en nomme
    /// aucun. ⚠️ **Rien n'est parti**, et c'est tout ce qui la sépare d'`.indetermine` :
    /// l'une invite à corriger sa session, l'autre à aller vérifier un compteur.
    case compteDifferent
    /// Juste avant l'envoi, les conditions ne tenaient plus — mesure vieillie, échéance
    /// passée, réglage ou consentement retiré. ⚠️ **Rien n'est parti.**
    case abandonnee
    /// Rien n'est établi. Voir l'avertissement ci-dessus.
    case indetermine
}

extension IssueReinitialisation {
    /// Les issues où il est **établi** qu'aucune requête de consommation n'a atteint le
    /// serveur, ou qu'il l'a refusée sans rien consommer. Elles seules lèvent la trace.
    var rienNEstParti: Bool {
        switch self {
        case .compteDifferent, .abandonnee, .reconnexionNecessaire: true
        case .reinitialise, .rienAReinitialiser, .aucunCredit, .dejaConsomme, .indetermine: false
        }
    }
}

/// Consomme une **réinitialisation anticipée** de quota — les « rate limit reset
/// credits » d'OpenAI, seul fournisseur du parc à en proposer.
///
/// ⛔ **C'est la seule écriture que Quotum fait sur un compte.** Tout le reste du produit
/// observe sans agir. Ce qui se joue ici n'est pas réversible : ces crédits sont offerts
/// par OpenAI ou gagnés par parrainage, trois au maximum, et ils périment à trente jours.
/// Un crédit dépensé à tort est perdu.
///
/// D'où trois règles, qui sont celles du client officiel d'OpenAI :
/// l'appel ne part **jamais** sans un geste humain explicite ; chaque geste porte un
/// identifiant de demande **neuf** ; et deux gestes ne peuvent pas se chevaucher.
enum ReinitialisationCodex {
    static let chemin = "/backend-api/wham/rate-limit-reset-credits/consume"

    /// Le client officiel attend dix secondes. Plus court couperait une réponse lente
    /// sur une action qu'on ne veut surtout pas rejouer à l'aveugle.
    static let delaiParDefaut: TimeInterval = 10

    static func requete(jeton: JetonCodex,
                        creditIdentifiant: String?,
                        demandeIdentifiant: UUID,
                        delai: TimeInterval = delaiParDefaut) -> URLRequest? {
        guard let url = URL(string: QuotaCodex.hote + chemin) else { return nil }
        // Le corps porte l'identifiant de demande : c'est lui qui rend l'appel
        // idempotent côté serveur si le réseau le rejoue.
        var corps: [String: String] = ["redeem_request_id": demandeIdentifiant.uuidString]
        // Omis, et non vide : le serveur choisit alors lui-même le crédit. Envoyer une
        // chaîne vide désignerait un crédit qui n'existe pas.
        if let creditIdentifiant, !creditIdentifiant.isEmpty {
            corps["credit_id"] = creditIdentifiant
        }
        guard let donnees = try? JSONSerialization.data(withJSONObject: corps) else { return nil }

        var requete = URLRequest(url: url)
        requete.httpMethod = "POST"
        requete.timeoutInterval = delai
        requete.httpBody = donnees
        requete.setValue("Bearer \(jeton.valeur)", forHTTPHeaderField: "Authorization")
        requete.setValue("application/json", forHTTPHeaderField: "Content-Type")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue(QuotaCodex.agent, forHTTPHeaderField: "User-Agent")
        if let compte = jeton.compteIdentifiant {
            requete.setValue(compte, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return requete
    }

    private struct Reponse: Decodable {
        var code: String?
        var fenetres: Int?

        enum CodingKeys: String, CodingKey {
            case code
            case fenetres = "windows_reset"
        }
    }

    /// ⚠️ Un code inconnu vaut `.indetermine`, jamais un succès : le serveur peut gagner
    /// un cas, et le ranger au hasard dirait à l'utilisateur que son crédit est intact
    /// — ou qu'il est parti — sans le savoir.
    static func classer(_ donnees: Data) -> IssueReinitialisation {
        guard let reponse = try? JSONDecoder().decode(Reponse.self, from: donnees),
              let code = reponse.code else { return .indetermine }
        switch code {
        case "reset": return .reinitialise(fenetres: max(0, reponse.fenetres ?? 0))
        case "nothing_to_reset": return .rienAReinitialiser
        case "no_credit": return .aucunCredit
        case "already_redeemed": return .dejaConsomme
        default:
            Journal.donnees.notice("Réinitialisation : code inconnu « \(code) »")
            return .indetermine
        }
    }

    /// ⛔ N'appeler qu'après une confirmation explicite de l'utilisateur.
    ///
    /// `demandeIdentifiant` doit être **neuf à chaque confirmation** : le réutiliser
    /// ferait retomber le serveur sur la réponse précédente, et un second geste
    /// délibéré n'aurait aucun effet sans que rien ne le dise.
    static func consommer(jeton: JetonCodex,
                          creditIdentifiant: String? = nil,
                          demandeIdentifiant: UUID = UUID(),
                          session: URLSession = Reseau.session,
                          delai: TimeInterval = delaiParDefaut) async -> IssueReinitialisation {
        guard let requete = requete(jeton: jeton,
                                    creditIdentifiant: creditIdentifiant,
                                    demandeIdentifiant: demandeIdentifiant,
                                    delai: delai) else { return .indetermine }
        do {
            let (donnees, reponse) = try await session.data(for: requete)
            guard let http = reponse as? HTTPURLResponse else { return .indetermine }
            if http.statusCode == 401 { return .reconnexionNecessaire }
            // Un code d'erreur ne dit pas que le crédit est intact — la demande a pu
            // aboutir côté serveur avant que la réponse ne tourne mal.
            guard (200..<300).contains(http.statusCode) else {
                Journal.donnees.notice("Réinitialisation : refus (code \(http.statusCode))")
                return .indetermine
            }
            return classer(donnees)
        } catch {
            Journal.donnees.notice("Réinitialisation : appel interrompu (\(error))")
            return .indetermine
        }
    }

    /// Ce que le tiroir déclenche. Le jeton est relu **au moment du geste** plutôt que
    /// gardé depuis le dernier relevé : il expire en quelques heures, et un jeton mis
    /// de côté ferait échouer l'appel là où une relecture le renouvelle.
    ///
    /// ⛔ Relire, c'est aussi risquer de relire **autre chose** : un `codex login` entre
    /// le relevé et le geste remplace la session, et la dépense partirait sur un compte
    /// que personne n'a désigné — irréversible, et annoncée sous le nom du premier.
    /// D'où `compteAttendu`, sans valeur par défaut, et `JetonCodex.estDuCompte`, la règle
    /// commune avec la réserve : ⛔ sans compte attendu, ou sans un jeton qui nomme lui-même
    /// ce compte, rien ne part — laisser passer le silence tirerait au sort le compte débité.
    ///
    /// ⛔ N'appeler qu'après une confirmation explicite de l'utilisateur, comme
    /// `consommer(jeton:…)` dont elle n'est qu'une façade.
    ///
    /// ⛔ `fichier` est l'auth.json dont vient le relevé de la rangée, sans valeur par défaut :
    /// retomber sur celui du terminal relirait la connexion d'un autre compte, et la rangée
    /// dont Quotum lit un second auth.json ne serait jamais servie.
    ///
    /// ⛔ `avantEnvoi` est la dernière garde, relue **après** la lecture du jeton, juste
    /// avant le POST : tout ce qui a été vérifié avant les attentes a pu tomber pendant.
    static func consommerAvecJetonLocal(demandeIdentifiant: UUID,
                                        compteAttendu: String?,
                                        fichier: URL,
                                        avantEnvoi: @Sendable () async -> Bool,
                                        session: URLSession = Reseau.session) async -> IssueReinitialisation {
        switch await IdentifiantsCodex.jeton(fichier: fichier) {
        case .jeton(let jeton):
            guard jeton.estDuCompte(compteAttendu) else { return .compteDifferent }
            guard await avantEnvoi() else { return .abandonnee }
            return await consommer(jeton: jeton,
                                   demandeIdentifiant: demandeIdentifiant,
                                   session: session)
        // Aucune session Codex sur cette machine : c'est un `codex login` qui manque,
        // pas une réinitialisation.
        case .absent:
            return .reconnexionNecessaire
        // Une lecture empêchée n'établit rien — surtout pas que le jeton soit absent. Un jeton
        // personnel ne prouve aucun compte : rien ne se dépense avec lui.
        case .empechee, .horsDePortee, .jetonPersonnel:
            return .indetermine
        }
    }
}
