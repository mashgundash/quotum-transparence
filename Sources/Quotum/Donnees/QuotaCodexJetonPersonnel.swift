import Foundation

/// Le jeton personnel qu'un `auth.json` porte à la place de la connexion OAuth
/// (`personal_access_token`, `LectureCodex.jetonPersonnel`). Il ne nomme aucun compte : la
/// route d'identité d'OpenAI dit à qui il appartient. ⛔ Il ne sert qu'à la mesure : ne
/// prouvant aucun compte, il n'ouvre ni la réserve ni une réinitialisation.
struct JetonPersonnelCodex: Sendable {
    let valeur: String
}

/// La mesure d'un compte Codex connecté par jeton personnel (`personal_access_token` dans
/// `auth.json`) : la route d'identité d'OpenAI dit à quel compte le jeton appartient, puis
/// `wham/usage` en donne le quota, comme pour la connexion OAuth.
///
/// ⛔ **La seule exception à la règle « aucune requête ne se déguise en client officiel »**
/// (décision produit du 2026-10-03, prise en connaissance de cause). Ces deux requêtes, et
/// elles seules, portent `User-Agent: codex_cli_rs/<version>` et `originator: codex_cli_rs`,
/// les en-têtes du CLI officiel : rien n'établit que la route d'identité réponde sans eux.
/// `GardesReseauTests` nomme l'exception — ces deux adresses, ces deux en-têtes — et échoue
/// pour toute autre requête qui imiterait un client.
///
/// Fait relevé dans le code de CodexBar (MIT), jamais observé ici : route, en-têtes et forme
/// de la réponse d'identité (`chatgpt_account_id`, `chatgpt_plan_type`, `email`).
///
/// ⛔ Le jeton ne part que vers ces deux hôtes figés, sans suivre une redirection qui en sort,
/// il n'est jamais renouvelé, et `auth.json` n'est jamais écrit.
enum QuotaCodexJetonPersonnel {
    static let adresseIdentite = "https://auth.openai.com/api/accounts/v1/user-auth-credential/whoami"
    static var adresseUsage: String { QuotaCodex.hote + QuotaCodex.chemin }

    static let originator = "codex_cli_rs"
    /// La version du CLI officiel relevée sur la machine de développement le 2026-10-03
    /// (`codex --version`). Figée : Quotum n'exécute pas `codex` pour la lire.
    static let versionClient = "0.159.2"
    static var agent: String { "\(originator)/\(versionClient)" }

    /// Le compte que la route d'identité attribue au jeton. C'est lui qui pose la ligne,
    /// jamais un identifiant qu'on aurait envoyé.
    struct Identite: Sendable, Equatable {
        let compte: String
        var courriel: String?
        var plan: String?
    }

    static func relever(jeton: JetonPersonnelCodex,
                        session: URLSession = Reseau.session,
                        delai: TimeInterval = 8) async -> ReleveCodex {
        guard let requeteIdentite = requeteIdentite(jeton: jeton, delai: delai) else { return .indetermine }
        let identite: Identite
        switch await charger(requeteIdentite, session: session, sujet: "identité") {
        case .jetonRefuse: return .reconnexionNecessaire
        case .echec: return .indetermine
        case .donnees(let donnees):
            // Sans compte nommé par le serveur, la mesure ne saurait sur quelle ligne se poser.
            guard let lue = decoderIdentite(donnees) else {
                Journal.donnees.notice("Quota Codex (jeton personnel) : identité sans compte")
                return .indetermine
            }
            identite = lue
        }

        guard let requeteUsage = requeteUsage(jeton: jeton, compte: identite.compte, delai: delai) else {
            return .indetermine
        }
        switch await charger(requeteUsage, session: session, sujet: "mesure") {
        case .jetonRefuse: return .reconnexionNecessaire
        case .echec: return .indetermine
        case .donnees(let donnees):
            return poser(QuotaCodex.analyser(donnees, mesureA: Date()), sur: identite)
        }
    }

    /// La mesure posée sur le compte que l'identité nomme. ⛔ Une réponse qui décrit un autre
    /// compte ne se pose nulle part. La réserve et les réinitialisations en sont retirées : un
    /// jeton personnel ne prouve aucun compte, et n'ouvre aucune lecture ni dépense ciblée.
    static func poser(_ releve: ReleveCodex, sur identite: Identite) -> ReleveCodex {
        guard case .releve(var mesure) = releve else { return releve }
        if let annonce = mesure.compteIdentifiant, annonce.lowercased() != identite.compte.lowercased() {
            Journal.donnees.notice("Quota Codex (jeton personnel) : la mesure décrit un autre compte que l'identité")
            return .indetermine
        }
        mesure.compteIdentifiant = identite.compte
        mesure.courriel = identite.courriel ?? mesure.courriel
        mesure.plan = identite.plan ?? mesure.plan
        mesure.reinitialisationsDisponibles = nil
        mesure.horsQuota.reserve = nil
        guard mesure.quota != nil || !mesure.horsQuota.usages.isEmpty else { return .indetermine }
        return .releve(mesure)
    }

    static func requeteIdentite(jeton: JetonPersonnelCodex, delai: TimeInterval) -> URLRequest? {
        requete(adresseIdentite, jeton: jeton, delai: delai)
    }

    /// `ChatGPT-Account-Id` reprend le compte **rendu** par l'identité, jamais celui que
    /// `auth.json` déclarerait.
    static func requeteUsage(jeton: JetonPersonnelCodex, compte: String, delai: TimeInterval) -> URLRequest? {
        var requete = requete(adresseUsage, jeton: jeton, delai: delai)
        requete?.setValue(compte, forHTTPHeaderField: "ChatGPT-Account-Id")
        return requete
    }

    private static func requete(_ adresse: String, jeton: JetonPersonnelCodex, delai: TimeInterval) -> URLRequest? {
        guard let url = URL(string: adresse) else { return nil }
        var requete = URLRequest(url: url)
        requete.httpMethod = "GET"
        requete.timeoutInterval = delai
        requete.setValue("Bearer \(jeton.valeur)", forHTTPHeaderField: "Authorization")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue(agent, forHTTPHeaderField: "User-Agent")
        requete.setValue(originator, forHTTPHeaderField: "originator")
        return requete
    }

    private static func charger(_ requete: URLRequest, session: URLSession, sujet: String) async -> QuotaCodex.ReponseAPI {
        guard let hote = requete.url?.host() else { return .echec }
        do {
            let (donnees, reponse) = try await session.data(for: requete,
                                                            delegate: RedirectionMemeHoteSeulement(hote: hote))
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            if code != 200 { Journal.donnees.notice("Quota Codex (jeton personnel, \(sujet)) : statut HTTP \(code)") }
            return QuotaCodex.interpreter(code: code, donnees: donnees)
        } catch {
            Journal.donnees.debug("Quota Codex (jeton personnel, \(sujet)) : \(hote) injoignable")
            return .echec
        }
    }

    private struct ReponseIdentite: Decodable {
        var compte: Souple<String>?
        var plan: Souple<String>?
        var courriel: Souple<String>?

        enum CodingKeys: String, CodingKey {
            case compte = "chatgpt_account_id"
            case plan = "chatgpt_plan_type"
            case courriel = "email"
        }
    }

    /// `nil` quand la réponse ne nomme aucun compte.
    static func decoderIdentite(_ donnees: Data) -> Identite? {
        guard let reponse = try? JSONDecoder().decode(ReponseIdentite.self, from: donnees),
              let compte = nonVide(reponse.compte?.valeur) else { return nil }
        return Identite(compte: compte, courriel: nonVide(reponse.courriel?.valeur), plan: nonVide(reponse.plan?.valeur))
    }

    private static func nonVide(_ valeur: String?) -> String? {
        guard let coupe = valeur?.trimmingCharacters(in: .whitespacesAndNewlines), !coupe.isEmpty else { return nil }
        return coupe
    }
}
