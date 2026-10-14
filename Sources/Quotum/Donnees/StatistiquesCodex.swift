import Foundation

/// Un jour du calendrier tel que le serveur l'écrit, « AAAA-MM-JJ », sans fuseau. ⛔ Il ne
/// devient jamais un instant : le convertir à l'heure locale le décalerait d'un jour sous
/// les fuseaux éloignés d'UTC, et toute l'arithmétique se fait en grégorien UTC.
struct JourCivil: Sendable, Hashable, Comparable, CustomStringConvertible {
    let annee: Int
    let mois: Int
    let jour: Int

    static let calendrier: Calendar = {
        var calendrier = Calendar(identifier: .gregorian)
        calendrier.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendrier
    }()

    /// `nil` pour un jour qui n'existe pas : le 30 février ne revient pas du calendrier
    /// sous la forme où il y est entré.
    init?(annee: Int, mois: Int, jour: Int) {
        guard (1...9999).contains(annee),
              let date = Self.calendrier.date(from: DateComponents(year: annee, month: mois, day: jour)) else {
            return nil
        }
        let relu = Self.calendrier.dateComponents([.year, .month, .day], from: date)
        guard relu.year == annee, relu.month == mois, relu.day == jour else { return nil }
        self.annee = annee
        self.mois = mois
        self.jour = jour
    }

    /// Strictement « AAAA-MM-JJ », en chiffres ASCII : ni heure, ni fuseau, ni chiffres
    /// d'une autre écriture, qu'un motif `\d` laisserait passer.
    init?(texte: String) {
        let octets = Array(texte.utf8)
        guard octets.count == 10, octets[4] == UInt8(ascii: "-"), octets[7] == UInt8(ascii: "-") else { return nil }
        func nombre(_ plage: Range<Int>) -> Int? {
            var valeur = 0
            for octet in octets[plage] {
                guard octet >= UInt8(ascii: "0"), octet <= UInt8(ascii: "9") else { return nil }
                valeur = valeur * 10 + Int(octet - UInt8(ascii: "0"))
            }
            return valeur
        }
        guard let annee = nombre(0..<4), let mois = nombre(5..<7), let jour = nombre(8..<10) else { return nil }
        self.init(annee: annee, mois: mois, jour: jour)
    }

    private var instantUTC: Date? {
        Self.calendrier.date(from: DateComponents(year: annee, month: mois, day: jour))
    }

    func decale(jours: Int) -> JourCivil? {
        guard let instant = instantUTC,
              let decale = Self.calendrier.date(byAdding: .day, value: jours, to: instant) else { return nil }
        // Avant l'an 1, le calendrier passe à l'ère précédente et compte ses années à rebours :
        // sans l'ère, la veille du 1er janvier de l'an 1 deviendrait le 31 décembre de l'an 1.
        let relu = Self.calendrier.dateComponents([.era, .year, .month, .day], from: decale)
        guard relu.era == 1, let annee = relu.year, let mois = relu.month, let jour = relu.day else { return nil }
        return JourCivil(annee: annee, mois: mois, jour: jour)
    }

    /// Lundi 0 … dimanche 6.
    var rangDansLaSemaine: Int? {
        guard let instant = instantUTC else { return nil }
        let jourSemaine = Self.calendrier.component(.weekday, from: instant)
        return (jourSemaine + 5) % 7
    }

    var description: String { String(format: "%04d-%02d-%02d", annee, mois, jour) }

    static func < (gauche: JourCivil, droite: JourCivil) -> Bool {
        (gauche.annee, gauche.mois, gauche.jour) < (droite.annee, droite.mois, droite.jour)
    }
}

/// L'usage Codex d'un compte, jour par jour, tel que `wham/profiles/me` le publie.
///
/// ⛔ Minimisation : rien d'autre n'est gardé de la réponse — ni le nom, ni la photo, ni
/// les compétences, ni aucune autre statistique. Le corps brut n'est gardé nulle part.
struct UsageCodex: Sendable, Equatable {
    enum Jour: Sendable, Equatable {
        case connu(Int64)
        /// Dans la période connue, mais rien n'établit ni une valeur ni l'absence d'usage.
        case inconnu
        /// Avant tout ce qui est connu, ou après le jour de la mesure.
        case horsPeriode
    }

    /// Les jours publiés et lus, chacun à au moins zéro.
    let parJour: [JourCivil: Int64]
    /// Les jours publiés dont l'usage n'a pas pu être lu : ni zéro, ni une valeur.
    let illisibles: Set<JourCivil>
    /// Les plages où un jour absent de la réponse est établi sans usage. ⚠️ Le serveur n'écrit
    /// pas les zéros, mais l'absence ne vaut zéro que là où la réponse le prouve : entre le
    /// premier seau quotidien et la mesure, ou dans une semaine que ses jours publiés épuisent.
    let sansUsage: [ClosedRange<JourCivil>]
    let auJour: JourCivil
    /// `false` quand un seau publié n'a pas pu être lu ou situé, que la borne d'examen est
    /// atteinte, ou qu'une semaine porte un usage qu'aucun jour ne place : ce qui est montré
    /// est vrai, ce qui manque n'est pas « rien ».
    let complet: Bool

    /// Le plus ancien jour dont quelque chose est établi ; `nil` quand rien ne l'est.
    var debutConnu: JourCivil? {
        (Array(parJour.keys) + Array(illisibles) + sansUsage.map(\.lowerBound)).min()
    }

    func jour(_ jour: JourCivil) -> Jour {
        guard jour <= auJour else { return .horsPeriode }
        if illisibles.contains(jour) { return .inconnu }
        if let valeur = parJour[jour] { return .connu(valeur) }
        if sansUsage.contains(where: { $0.contains(jour) }) { return .connu(0) }
        guard let debut = debutConnu, jour >= debut else { return .horsPeriode }
        return .inconnu
    }
}

/// L'usage par jour d'un compte Codex sur les semaines récentes — un `GET` sur
/// `chatgpt.com/backend-api/wham/profiles/me`, mesuré le 13/10/2026.
///
/// ⛔ Lu sur geste seulement (dépli du tiroir), sous le consentement Codex, avec la porte
/// de la réserve (`ReserveCodex.jetonAutorise`) et sans aucun déguisement : la requête dit
/// « Quotum », jamais `originator` ni un en-tête du client officiel.
enum StatistiquesCodex {
    static let chemin = "/backend-api/wham/profiles/me"
    static let delaiParDefaut: TimeInterval = 8
    /// La réponse mesurée pèse 10 400 octets : au-delà d'un mébioctet, ce n'est plus elle.
    static let octetsMax = 1 << 20
    /// Douze semaines n'en demandent que 84 ; la borne protège d'un tableau sans fin.
    static let seauxMax = 400

    typealias Executeur = ReserveCodex.Executeur

    private static let hote = URL(string: QuotaCodex.hote)?.host() ?? ""

    /// Au-delà de `delai`, qui ne mesure que le silence entre deux paquets : un serveur qui
    /// distille son corps octet par octet ne retient pas le tiroir plus longtemps que ça.
    static let delaiTotal: TimeInterval = 20

    enum RefusCorps: Error, Equatable {
        case tropLourd
        case echeance
    }

    /// Ce qu'une requête a ouvert : la réponse, le corps à lire en flux, et de quoi relâcher
    /// la connexion quand la lecture s'arrête avant la fin.
    struct FluxOuvert<Flux: AsyncSequence & Sendable>: Sendable where Flux.Element == UInt8 {
        let flux: Flux
        let reponse: URLResponse
        let relacher: @Sendable () -> Void
    }

    private struct Corps: Sendable {
        let donnees: Data
        let reponse: URLResponse
    }

    static let appelReel: Executeur = { requete in
        try await lireBorne(delaiTotal: delaiTotal) {
            let (flux, reponse) = try await Reseau.session.bytes(for: requete,
                                                                 delegate: RedirectionMemeHoteSeulement(hote: hote))
            return FluxOuvert(flux: flux, reponse: reponse, relacher: { flux.task.cancel() })
        }
    }

    /// Le corps lu en flux, jamais plus de `octetsMax` octets gardés : l'octet de trop arrête la
    /// lecture, et l'échéance totale aussi, qui l'annule.
    static func lireBorne<Flux>(delaiTotal: TimeInterval,
                                ouvrir: @escaping @Sendable () async throws -> FluxOuvert<Flux>)
        async throws -> (Data, URLResponse) {
        let issue = await Reseau.avantEcheance(delaiTotal) { () -> Result<Corps, Error> in
            do {
                let ouvert = try await ouvrir()
                defer { ouvert.relacher() }
                return try await withTaskCancellationHandler {
                    if ouvert.reponse.expectedContentLength > Int64(octetsMax) { throw RefusCorps.tropLourd }
                    var donnees = Data()
                    for try await octet in ouvert.flux {
                        // Un flux qui ignore l'annulation ne doit pas retenir l'échéance.
                        try Task.checkCancellation()
                        donnees.append(octet)
                        if donnees.count > octetsMax { throw RefusCorps.tropLourd }
                    }
                    try Task.checkCancellation()
                    return .success(Corps(donnees: donnees, reponse: ouvert.reponse))
                } onCancel: {
                    ouvert.relacher()
                }
            } catch {
                return .failure(error)
            }
        }
        guard let issue else { throw RefusCorps.echeance }
        let corps = try issue.get()
        return (corps.donnees, corps.reponse)
    }

    /// Les en-têtes posés **sur la requête** : un `Authorization` mis dans la session serait
    /// rejoué chez le destinataire d'une redirection.
    static func requete(jeton: JetonCodex, delai: TimeInterval = delaiParDefaut) -> URLRequest? {
        guard let url = URL(string: QuotaCodex.hote + chemin) else { return nil }
        var requete = URLRequest(url: url)
        requete.httpMethod = "GET"
        requete.timeoutInterval = delai
        requete.setValue("Bearer \(jeton.valeur)", forHTTPHeaderField: "Authorization")
        requete.setValue("application/json", forHTTPHeaderField: "Accept")
        requete.setValue(QuotaCodex.agent, forHTTPHeaderField: "User-Agent")
        if let compte = jeton.compteIdentifiant {
            requete.setValue(compte, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return requete
    }

    /// ⛔ `consentement`, `compteAttendu`, `lireJeton` et `executer` n'ont pas de valeur par
    /// défaut : un appelant qui oublierait l'un d'eux ne compile pas, au lieu de lire le
    /// vrai `auth.json` ou de partir sur le réseau.
    static func lire(consentement: @escaping ReserveCodex.LecteurConsentement,
                     compteAttendu: String,
                     lireJeton: ReserveCodex.LecteurJeton,
                     executer: Executeur,
                     delai: TimeInterval = delaiParDefaut) async -> LectureReserveCodex<UsageCodex> {
        let geste = await consentement()
        guard geste[.chatgpt] else { return .sansConsentement }
        // Un retrait suivi d'un réarmement pendant une attente reste un retrait : l'accord relu
        // doit être celui du geste, révocations comprises, pas seulement un suivi rallumé.
        let toujoursAccorde: ReserveCodex.LecteurConsentement = { geste.restreint(a: await consentement()) }
        let jeton: JetonCodex
        switch await ReserveCodex.jetonAutorise(consentement: toujoursAccorde, compteAttendu: compteAttendu,
                                                lireJeton: lireJeton) {
        case .success(let lu): jeton = lu
        case .failure(let refus): return refus.lecture()
        }
        guard let requete = requete(jeton: jeton, delai: delai) else { return .indetermine }
        let reponse = await charger(requete, executer: executer)
        guard await toujoursAccorde()[.chatgpt] else { return .sansConsentement }
        switch reponse {
        case .donnees(let donnees):
            guard ReserveCodex.reponseDuCompte(donnees, compteAttendu) else { return .compteDifferent }
            guard let usage = decoder(donnees) else { return .indetermine }
            return .lu(usage)
        case .jetonRefuse: return .reconnexionNecessaire
        case .echec: return .indetermine
        }
    }

    private static func charger(_ requete: URLRequest, executer: Executeur) async -> QuotaCodex.ReponseAPI {
        do {
            let (donnees, reponse) = try await executer(requete)
            let code = (reponse as? HTTPURLResponse)?.statusCode ?? -1
            if code != 200 { Journal.donnees.notice("Usage Codex : statut HTTP \(code)") }
            if code == 200, donnees.count > octetsMax {
                Journal.donnees.notice("Usage Codex : réponse de plus de \(octetsMax) octets refusée")
                return .echec
            }
            return QuotaCodex.interpreter(code: code, donnees: donnees)
        } catch {
            Journal.donnees.debug("Usage Codex : chatgpt.com injoignable")
            return .echec
        }
    }

    // MARK: - Décodage

    private struct Seau: Decodable {
        let date: String?
        let tokens: Int64?

        enum CodingKeys: String, CodingKey {
            case date = "start_date"
            case tokens
        }

        init(from decoder: Decoder) throws {
            let boite = try decoder.container(keyedBy: CodingKeys.self)
            date = (try? boite.decodeIfPresent(String.self, forKey: .date)) ?? nil
            tokens = (try? boite.decodeIfPresent(Int64.self, forKey: .tokens)) ?? nil
        }
    }

    /// Seules les clés lues sont déclarées : `profile`, `top_invocations` et les autres
    /// statistiques ne sont jamais décodées.
    private struct Reponse: Decodable {
        struct Statistiques: Decodable {
            let quotidiens: [Souple<Seau>]
            let hebdomadaires: Souple<[Souple<Seau>]>?

            enum CodingKeys: String, CodingKey {
                case quotidiens = "daily_usage_buckets"
                case hebdomadaires = "weekly_usage_buckets"
            }
        }

        struct Metadonnees: Decodable {
            let auJour: String
            let erreur: Bool

            enum CodingKeys: String, CodingKey {
                case auJour = "stats_as_of"
                case erreur = "stats_error"
            }

            init(from decoder: Decoder) throws {
                let boite = try decoder.container(keyedBy: CodingKeys.self)
                auJour = try boite.decode(String.self, forKey: .auJour)
                erreur = boite.contains(.erreur) && !((try? boite.decodeNil(forKey: .erreur)) ?? false)
            }
        }

        let stats: Statistiques
        let metadata: Metadonnees
    }

    private struct SeauSitue {
        let jour: JourCivil
        /// `nil` : le jour est publié, sa valeur est illisible.
        let tokens: Int64?
    }

    /// Les seaux situés au plus tard le jour de la mesure, un par jour, les plus récents d'abord
    /// et au plus `seauxMax`. `tousSitues` à faux dès qu'un seau publié ne dit pas son jour : l'un
    /// des jours absents est peut-être le sien. Un jour publié deux fois avec deux valeurs est
    /// `conteste` et perd sa valeur : garder la première dépendrait de l'ordre de la réponse.
    private static func situer(_ seaux: [Souple<Seau>], auJour: JourCivil)
        -> (retenus: [SeauSitue], tousSitues: Bool, complet: Bool, contestes: Set<JourCivil>) {
        var tousSitues = true
        var complet = true
        var contestes = Set<JourCivil>()
        var parJour: [JourCivil: SeauSitue] = [:]
        for souple in seaux {
            guard let seau = souple.valeur, let texte = seau.date, let jour = JourCivil(texte: texte) else {
                tousSitues = false
                complet = false
                continue
            }
            guard jour <= auJour else {
                complet = false
                continue
            }
            let tokens = seau.tokens.flatMap { $0 >= 0 ? $0 : nil }
            if let deja = parJour[jour] {
                complet = false
                if deja.tokens != tokens || tokens == nil {
                    contestes.insert(jour)
                    parJour[jour] = SeauSitue(jour: jour, tokens: nil)
                }
                continue
            }
            if tokens == nil { complet = false }
            parJour[jour] = SeauSitue(jour: jour, tokens: tokens)
        }
        var retenus = parJour.values.sorted { $0.jour > $1.jour }
        if retenus.count > seauxMax {
            retenus = Array(retenus.prefix(seauxMax))
            complet = false
        }
        return (retenus, tousSitues, complet, contestes)
    }

    /// ⚠️ `stats_error` publié, ou `stats_as_of` illisible, et rien n'est lu : la date de
    /// référence porte toute la carte. Un seau illisible, lui, ne coûte que son jour.
    static func decoder(_ donnees: Data) -> UsageCodex? {
        // Une date de mesure au bord du calendrier ne laisserait aucune semaine entière à montrer :
        // ni l'année d'avant, ni le dimanche de sa propre semaine.
        guard let reponse = try? JSONDecoder().decode(Reponse.self, from: donnees),
              !reponse.metadata.erreur,
              let auJour = JourCivil(texte: reponse.metadata.auJour),
              auJour.decale(jours: -366) != nil,
              let rang = auJour.rangDansLaSemaine,
              auJour.decale(jours: 6 - rang) != nil else { return nil }

        let quotidiens = situer(reponse.stats.quotidiens, auJour: auJour)
        var complet = quotidiens.complet
        var parJour: [JourCivil: Int64] = [:]
        var illisibles = Set<JourCivil>()
        for seau in quotidiens.retenus {
            if let tokens = seau.tokens { parJour[seau.jour] = tokens } else { illisibles.insert(seau.jour) }
        }
        var sansUsage: [ClosedRange<JourCivil>] = []
        let debutQuotidien = quotidiens.tousSitues ? quotidiens.retenus.last?.jour : nil
        if let debutQuotidien { sansUsage.append(debutQuotidien...auJour) }

        if let hebdomadaires = reponse.stats.hebdomadaires {
            guard let seaux = hebdomadaires.valeur else {
                return UsageCodex(parJour: parJour, illisibles: illisibles, sansUsage: sansUsage,
                                  auJour: auJour, complet: false)
            }
            let semaines = situer(seaux, auJour: auJour)
            complet = complet && semaines.complet
            var contredites: [ClosedRange<JourCivil>] = []
            for semaine in semaines.retenus {
                guard let total = semaine.tokens else {
                    if semaines.contestes.contains(semaine.jour) {
                        contredites.append(semaine.jour...min(semaine.jour.decale(jours: 6) ?? auJour, auJour))
                    }
                    continue
                }
                let plage = semaine.jour...min(semaine.jour.decale(jours: 6) ?? auJour, auJour)
                var place: Int128 = 0
                var jour: JourCivil? = plage.lowerBound
                while let courant = jour, plage.contains(courant) {
                    place += Int128(parJour[courant] ?? 0)
                    jour = courant.decale(jours: 1)
                }
                if place == Int128(total) {
                    sansUsage.append(plage)
                } else {
                    // Où qu'elle commence, une semaine que ses jours ne totalisent pas ne prouve
                    // aucun de ses jours absents, pas même ceux couverts par les seaux quotidiens.
                    contredites.append(plage)
                    complet = false
                }
            }
            sansUsage = contredites.reduce(sansUsage) { plages, trou in plages.flatMap { $0.privee(de: trou) } }
        }
        return UsageCodex(parJour: parJour, illisibles: illisibles, sansUsage: sansUsage,
                          auJour: auJour, complet: complet)
    }
}

private extension ClosedRange where Bound == JourCivil {
    /// Ce qui reste de la plage hors du trou : rien, elle-même, ou un ou deux morceaux.
    func privee(de trou: ClosedRange<JourCivil>) -> [ClosedRange<JourCivil>] {
        guard overlaps(trou) else { return [self] }
        var morceaux: [ClosedRange<JourCivil>] = []
        if lowerBound < trou.lowerBound, let veille = trou.lowerBound.decale(jours: -1) {
            morceaux.append(lowerBound...veille)
        }
        if trou.upperBound < upperBound, let lendemain = trou.upperBound.decale(jours: 1) {
            morceaux.append(lendemain...upperBound)
        }
        return morceaux
    }
}
