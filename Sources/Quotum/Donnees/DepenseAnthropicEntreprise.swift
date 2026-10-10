import Foundation

/// Ce que la garde de saisie refuse, avant tout appel.
enum RefusCleLecture: Error, Sendable, Equatable {
    case vide
    case tropLongue
    /// Espace intérieur, caractère de contrôle, lettre hors ASCII : aucune clé n'en porte.
    case caracteres
    /// Une clé d'API de la Console (`prefixeConsole`, sauf le préfixe Enterprise) : elle génère
    /// des réponses, donc dépense.
    case cleQuiGenere
    /// Une clé d'administration de la Console : sans portée, elle crée et réactive des clés qui
    /// dépensent.
    case cleAdministrationConsole
    /// Un jeton OAuth de Claude Code ou de claude.ai : il génère des réponses.
    case connexionOAuth
    case formeInconnue
    case membreInvalide
}

/// Le membre dont on lit la dépense. Une adresse ne sert qu'une fois, à l'ajout, pour trouver
/// l'identifiant ; c'est l'identifiant qui est gardé et envoyé ensuite.
enum MembreSuivi: Sendable, Equatable {
    case identifiant(String)
    case courriel(String)
}

/// Une clé Claude Enterprise passée par la garde. ⛔ Sa description ne montre jamais la
/// valeur : une interpolation dans un journal ou une alerte n'en écrit que le préfixe.
struct CleAnthropicEntreprise: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let valeur: String

    fileprivate init(valeur: String) { self.valeur = valeur }

    var description: String { DepenseAnthropicEntreprise.prefixe + "…" }
    var debugDescription: String { description }
}

/// Ce qui accompagne la clé au Trousseau, sans être secret : de quoi poser la ligne et la
/// feuille sans lire la clé.
struct EnregistrementAnthropic: Codable, Sendable, Equatable {
    static let versionCourante = 1

    let version: Int
    let membre: String
    let courriel: String?

    init(membre: String, courriel: String?) {
        version = Self.versionCourante
        self.membre = membre
        self.courriel = courriel
    }

    func encoder() -> Data? {
        let encodeur = JSONEncoder()
        encodeur.outputFormatting = .sortedKeys
        return try? encodeur.encode(self)
    }

    /// ⛔ Un attribut retouché qui nommerait un autre format, ou un « membre » qui n'a pas la
    /// forme d'un identifiant, ne fait pas d'enregistrement : il finirait dans une requête.
    static func decoder(_ donnees: Data) -> EnregistrementAnthropic? {
        guard let lu = try? JSONDecoder().decode(EnregistrementAnthropic.self, from: donnees),
              lu.version == versionCourante,
              DepenseAnthropicEntreprise.estIdentifiantMembre(lu.membre),
              lu.courriel.map(DepenseAnthropicEntreprise.estCourriel) ?? true
        else { return nil }
        return lu
    }
}

/// La dépense du mois d'un membre, telle qu'Anthropic la publie.
struct DepenseMembre: Sendable, Equatable {
    let membre: String
    let courriel: String?
    let usage: UsagePayant
}

enum ReleveCleAnthropic: Sendable, Equatable {
    case mesure(DepenseMembre)
    /// 401 : clé révoquée, expirée ou mal copiée.
    case cleRefusee
    /// 403 ou 404 : la clé ne lit pas cette route — portée absente, ou organisation qui
    /// n'est pas Claude Enterprise.
    case porteeRefusee
    /// La route répond, et le membre n'y figure plus.
    case membreAbsent
    /// Réseau, redirection refusée, 429, 5xx, corps illisible : rien n'est établi.
    case indetermine
}

/// La dépense d'un membre d'une organisation Claude Enterprise, lue par une clé de lecture
/// (`GET /v1/organizations/spend_limits/effective`, portée `read:spend_limits`).
///
/// ⛔ **Aucun appel d'inférence, jamais, pas même pour éprouver la clé** : une clé qui
/// génère dépenserait à l'essai. La seule route appelée est celle de la dépense, qui n'existe
/// pas dans une organisation de la Console — une réponse 200 y prouve donc une clé Claude
/// Enterprise, et aucune portée de ces clés ne génère de réponse (DOCUMENTÉ, table des
/// portées d'`admin-api-keys`). Ce qu'aucune route ne permet de vérifier, c'est l'**absence**
/// d'autres portées, `write:spend_limits` comprise : l'interface le dit avant la saisie.
enum DepenseAnthropicEntreprise {
    /// Le même hôte que le quota de Claude : aucune adresse de plus dans le code.
    static let hote = QuotaAnthropic.hote
    static let chemin = "/v1/organizations/spend_limits/effective"
    static let versionAPI = "2023-06-01"
    /// Le seul préfixe des clés créées dans claude.ai → Réglages de l'organisation → API.
    static let prefixe = "sk-ant-api01-"
    static let prefixeAdministrationConsole = "sk-ant-admin"
    static let prefixeConsole = "sk-ant-api"
    static let prefixesOAuth = ["sk-ant-oat", "sk-ant-ort"]
    /// Large devant les clés publiées (une centaine de caractères), étroit devant un collage
    /// accidentel d'un paragraphe entier.
    static let longueurMaximale = 256
    /// Sous ce compte, ce n'est qu'un préfixe suivi de presque rien.
    static let longueurMinimale = prefixe.count + 16
    /// Une adresse se cherche dans la liste des membres, à mille par page : au-delà de dix
    /// pages, on demande l'identifiant plutôt que de tout parcourir.
    static let membresParPage = 1_000
    static let pagesMaximales = 10

    // MARK: - Garde de saisie

    static func valider(cle brute: String) -> Result<CleAnthropicEntreprise, RefusCleLecture> {
        let cle = brute.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cle.isEmpty else { return .failure(.vide) }
        guard cle.utf8.count <= longueurMaximale else { return .failure(.tropLongue) }
        guard cle.unicodeScalars.allSatisfy(estCaractereDeCle) else { return .failure(.caracteres) }
        if cle.hasPrefix(prefixe) {
            return cle.count >= longueurMinimale ? .success(CleAnthropicEntreprise(valeur: cle))
                                                 : .failure(.formeInconnue)
        }
        // Après le préfixe Enterprise, qui commence comme une clé de la Console : toute autre clé
        // d'API de la Console génère des réponses.
        if cle.hasPrefix(prefixeAdministrationConsole) { return .failure(.cleAdministrationConsole) }
        if cle.hasPrefix(prefixeConsole) { return .failure(.cleQuiGenere) }
        if prefixesOAuth.contains(where: cle.hasPrefix) { return .failure(.connexionOAuth) }
        return .failure(.formeInconnue)
    }

    static func valider(membre brut: String) -> Result<MembreSuivi, RefusCleLecture> {
        let membre = brut.trimmingCharacters(in: .whitespacesAndNewlines)
        if estIdentifiantMembre(membre) { return .success(.identifiant(membre)) }
        if estCourriel(membre) { return .success(.courriel(membre)) }
        return .failure(.membreInvalide)
    }

    private static func estCaractereDeCle(_ scalaire: Unicode.Scalar) -> Bool {
        switch scalaire {
        case "a"..."z", "A"..."Z", "0"..."9", "-", "_": true
        default: false
        }
    }

    static func estIdentifiantMembre(_ texte: String) -> Bool {
        guard texte.hasPrefix("user_") else { return false }
        let reste = texte.dropFirst("user_".count)
        return (1...64).contains(reste.count) && reste.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
        }
    }

    static func estCourriel(_ texte: String) -> Bool {
        guard texte.utf8.count <= 254,
              !texte.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0)
                  || CharacterSet.controlCharacters.contains($0) }) else { return false }
        let parties = texte.split(separator: "@", omittingEmptySubsequences: false)
        guard parties.count == 2, !parties[0].isEmpty else { return false }
        let domaine = parties[1]
        return domaine.contains(".") && !domaine.hasPrefix(".") && !domaine.hasSuffix(".")
    }

    // MARK: - Requête

    /// `membre` restreint la réponse à sa propre ligne : passé l'ajout, aucune autre n'est
    /// demandée. Sans lui — la recherche d'une adresse, à l'ajout seulement —, la page porte
    /// mille membres.
    static func requete(cle: CleAnthropicEntreprise,
                        membre: String?,
                        page: String?,
                        delai: TimeInterval) -> URLRequest? {
        var parametres = [("period[]", "monthly"), ("limit", membre == nil ? String(membresParPage) : "1")]
        if let membre {
            guard estIdentifiantMembre(membre) else { return nil }
            parametres.append(("user_ids[]", membre))
        }
        if let page {
            guard estCurseur(page) else { return nil }
            parametres.append(("page", page))
        }
        let requeteTexte = parametres.map { "\(encoder($0.0))=\(encoder($0.1))" }.joined(separator: "&")
        guard let url = URL(string: hote + chemin + "?" + requeteTexte) else { return nil }
        var requete = URLRequest(url: url)
        requete.httpMethod = "GET"
        requete.timeoutInterval = delai
        requete.setValue(cle.valeur, forHTTPHeaderField: "x-api-key")
        requete.setValue(versionAPI, forHTTPHeaderField: "anthropic-version")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue("Quotum", forHTTPHeaderField: "User-Agent")
        return requete
    }

    /// Plus strict que `urlQueryAllowed`, qui laisse passer `+` et `&` : un curseur opaque
    /// qui en porterait ne doit ni devenir une espace, ni ouvrir un second paramètre.
    private static func encoder(_ texte: String) -> String {
        var permis = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        permis.insert(charactersIn: "-._~")
        return texte.addingPercentEncoding(withAllowedCharacters: permis) ?? ""
    }

    /// Le curseur vient du serveur et repart vers lui : borné, sans caractère de contrôle.
    static func estCurseur(_ texte: String) -> Bool {
        !texte.isEmpty && texte.utf8.count <= 2_048
            && !texte.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    // MARK: - Réponse

    struct LigneDepense: Sendable, Equatable {
        let membre: String
        let courriel: String?
        let usage: UsagePayant
    }

    struct Page: Sendable, Equatable {
        let lignes: [LigneDepense]
        let suivante: String?
    }

    enum Reponse: Sendable, Equatable {
        case page(Page)
        case cleRefusee
        case porteeRefusee
        case echec
    }

    static func interpreter(code: Int, donnees: Data, mesureA: Date) -> Reponse {
        switch code {
        case 200: decoder(donnees, mesureA: mesureA).map(Reponse.page) ?? .echec
        case 401: .cleRefusee
        case 403, 404: .porteeRefusee
        default: .echec
        }
    }

    private struct ReponseBrute: Decodable {
        let data: [Tolerante]
        let suivante: String?

        enum CodingKeys: String, CodingKey {
            case data
            case suivante = "next_page"
        }
    }

    /// Une ligne d'une forme inattendue ne fait pas tomber les autres.
    private struct Tolerante: Decodable {
        let ligne: LigneBrute?
        init(from decodeur: Decoder) throws { ligne = try? LigneBrute(from: decodeur) }
    }

    private struct LigneBrute: Decodable {
        struct Acteur: Decodable {
            let type: String?
            let membre: String?
            let courriel: String?

            enum CodingKeys: String, CodingKey {
                case type
                case membre = "user_id"
                case courriel = "email_address"
            }
        }

        let acteur: Acteur?
        /// `amount` absent n'est pas `amount: null` : le second dit « illimité », le premier
        /// ne dit rien, et la ligne tombe.
        let plafondPublie: Bool
        let plafond: String?
        let devise: String?
        let periode: String?
        let depense: String?

        enum CodingKeys: String, CodingKey {
            case acteur = "actor"
            case plafond = "amount"
            case devise = "currency"
            case periode = "period"
            case depense = "period_to_date_spend"
        }

        init(from decodeur: Decoder) throws {
            let conteneur = try decodeur.container(keyedBy: CodingKeys.self)
            acteur = try conteneur.decodeIfPresent(Acteur.self, forKey: .acteur)
            plafondPublie = conteneur.contains(.plafond)
            plafond = try conteneur.decodeIfPresent(String.self, forKey: .plafond)
            devise = try conteneur.decodeIfPresent(String.self, forKey: .devise)
            periode = try conteneur.decodeIfPresent(String.self, forKey: .periode)
            depense = try conteneur.decodeIfPresent(String.self, forKey: .depense)
        }
    }

    /// `nil` quand le corps n'a pas la forme publiée : un tableau `data`, un curseur nul ou
    /// valable. Les lignes qui ne font pas de dépense mensuelle lisible sont écartées.
    static func decoder(_ donnees: Data, mesureA: Date) -> Page? {
        guard let brute = try? JSONDecoder().decode(ReponseBrute.self, from: donnees) else { return nil }
        if let suivante = brute.suivante, !estCurseur(suivante) { return nil }
        let lignes = brute.data.compactMap(\.ligne).compactMap { ligne(depuis: $0, mesureA: mesureA) }
        return Page(lignes: lignes, suivante: brute.suivante)
    }

    private static func ligne(depuis brute: LigneBrute, mesureA: Date) -> LigneDepense? {
        guard brute.acteur?.type == "user_actor",
              let membre = brute.acteur?.membre, estIdentifiantMembre(membre),
              brute.periode == "monthly",
              let code = brute.devise, Montant.Unite.devise(code).estReconnue,
              let depense = brute.depense, let consomme = montantMineur(depense, code: code),
              brute.plafondPublie
        else { return nil }
        var plafond: Montant?
        if let publie = brute.plafond {
            // Le plafond est publié en entier ; une décimale dirait une autre forme.
            guard let lu = montantMineur(publie, code: code), lu.exposant == Formats.decimalesDevise(code)
            else { return nil }
            plafond = lu
        }
        guard let usage = UsagePayant(nature: .depense,
                                      unite: .devise(code),
                                      consomme: consomme,
                                      plafond: plafond,
                                      solde: nil,
                                      utilisation: nil,
                                      illimite: brute.plafond == nil,
                                      actif: nil,
                                      bloque: false,
                                      motif: nil,
                                      echeance: prochaineRemiseAZero(apres: mesureA),
                                      mesureA: mesureA)
        else { return nil }
        let courriel = brute.acteur?.courriel.flatMap { estCourriel($0) ? $0 : nil }
        return LigneDepense(membre: membre, courriel: courriel, usage: usage)
    }

    /// Un nombre d'unités mineures publié en texte (« 31402.5 » cents) : l'exposant est celui
    /// de l'unité mineure de la devise, plus les décimales écrites. Négatif, il ne fait pas
    /// de montant — la route n'en publie pas.
    static func montantMineur(_ texte: String, code: String) -> Montant? {
        guard !texte.hasPrefix("-"),
              let ecrit = Montant(texteDecimal: texte, unite: .devise(code)) else { return nil }
        let (exposant, deborde) = ecrit.exposant.addingReportingOverflow(Formats.decimalesDevise(code))
        guard !deborde else { return nil }
        return Montant(unitesMineures: ecrit.unitesMineures, unite: .devise(code), exposant: exposant)
    }

    /// Documenté : la dépense mensuelle repart à zéro le 1er de chaque mois, à 00:00 UTC.
    static func prochaineRemiseAZero(apres instant: Date) -> Date? {
        var calendrier = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else { return nil }
        calendrier.timeZone = utc
        let mois = calendrier.dateComponents([.year, .month], from: instant)
        guard let debut = calendrier.date(from: mois) else { return nil }
        return calendrier.date(byAdding: .month, value: 1, to: debut)
    }

    // MARK: - Appels

    private static func charger(_ requete: URLRequest, session: URLSession) async -> Reponse {
        do {
            let (donnees, reponse) = try await session.data(for: requete,
                                                            delegate: QuotaWindsurf.RefusDeRedirection())
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            if code != 200 {
                // Le statut seul : ni la clé, ni le corps, qui peut citer les portées.
                Journal.donnees.notice("Dépense Claude Enterprise : statut HTTP \(code)")
            }
            return interpreter(code: code, donnees: donnees, mesureA: Date())
        } catch {
            Journal.donnees.debug("Dépense Claude Enterprise : api.anthropic.com injoignable")
            return .echec
        }
    }

    /// Le relevé d'un cycle : une requête, restreinte au membre enregistré.
    static func relever(cle: CleAnthropicEntreprise,
                        enregistrement: EnregistrementAnthropic,
                        session: URLSession,
                        delai: TimeInterval = 8) async -> ReleveCleAnthropic {
        guard let requete = requete(cle: cle, membre: enregistrement.membre, page: nil, delai: delai)
        else { return .indetermine }
        switch await charger(requete, session: session) {
        case .cleRefusee: return .cleRefusee
        case .porteeRefusee: return .porteeRefusee
        case .echec: return .indetermine
        case .page(let page):
            guard let ligne = page.lignes.first(where: { $0.membre == enregistrement.membre }) else {
                return .membreAbsent
            }
            return .mesure(DepenseMembre(membre: ligne.membre,
                                         courriel: ligne.courriel ?? enregistrement.courriel,
                                         usage: ligne.usage))
        }
    }

    enum Resolution: Sendable, Equatable {
        case trouve(EnregistrementAnthropic)
        case cleRefusee
        case porteeRefusee
        case membreAbsent
        /// Deux membres sous la même adresse : on ne choisit pas au hasard.
        case membreAmbigu
        /// L'adresse n'est pas dans les `pagesMaximales` premières pages.
        case listeTropLongue
        case indetermine
    }

    /// À l'ajout : la clé passe-t-elle, et sous quel identifiant suivre le membre ?
    ///
    /// ⛔ Les lignes des autres membres, lues pour trouver une adresse, ne sortent jamais d'ici :
    /// seul l'identifiant trouvé est rendu.
    static func resoudre(cle: CleAnthropicEntreprise,
                         membre: MembreSuivi,
                         session: URLSession,
                         delai: TimeInterval = 15) async -> Resolution {
        switch membre {
        case .identifiant(let identifiant):
            switch await relever(cle: cle, enregistrement: EnregistrementAnthropic(membre: identifiant, courriel: nil),
                                 session: session, delai: delai) {
            case .mesure(let depense): return .trouve(EnregistrementAnthropic(membre: identifiant,
                                                                              courriel: depense.courriel))
            case .cleRefusee: return .cleRefusee
            case .porteeRefusee: return .porteeRefusee
            case .membreAbsent: return .membreAbsent
            case .indetermine: return .indetermine
            }
        case .courriel(let courriel):
            var page: String?
            var vus: Set<String> = []
            for _ in 0..<pagesMaximales {
                guard let requete = requete(cle: cle, membre: nil, page: page, delai: delai) else { return .indetermine }
                switch await charger(requete, session: session) {
                case .cleRefusee: return .cleRefusee
                case .porteeRefusee: return .porteeRefusee
                case .echec: return .indetermine
                case .page(let lue):
                    let trouves = Set(lue.lignes
                        .filter { $0.courriel?.caseInsensitiveCompare(courriel) == .orderedSame }
                        .map(\.membre))
                    // Arrêt au premier trouvé : chaque page de plus est la dépense d'autres
                    // membres, qu'on n'a pas à lire.
                    guard trouves.count <= 1 else { return .membreAmbigu }
                    if let trouve = trouves.first {
                        return .trouve(EnregistrementAnthropic(membre: trouve, courriel: courriel))
                    }
                    guard let suivante = lue.suivante, vus.insert(suivante).inserted else { return .membreAbsent }
                    page = suivante
                }
            }
            return .listeTropLongue
        }
    }
}
