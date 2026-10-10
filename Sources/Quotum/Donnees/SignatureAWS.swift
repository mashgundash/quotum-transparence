import CryptoKit
import Foundation

/// La clé secrète d'une identité IAM. ⛔ Sa description ne montre jamais la valeur : une
/// interpolation dans un journal ou une alerte n'en écrit que la forme.
struct SecretAWS: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let valeur: String

    var description: String { "secret AWS…" }
    var debugDescription: String { description }
}

/// La signature Version 4 d'AWS (`AWS4-HMAC-SHA256`), écrite sur CryptoKit, sans SDK.
///
/// Elle ne couvre que ce que Quotum envoie : un chemin `/`, une requête éventuelle, et les
/// en-têtes qu'on lui nomme. ⛔ Un autre chemin ne se signe pas — le double encodage des
/// segments, propre aux services autres que S3, n'est pas écrit, et une signature fausse
/// partirait plutôt que d'échouer ici.
enum SignatureAWS {
    static let algorithme = "AWS4-HMAC-SHA256"

    struct Signee: Sendable, Equatable {
        /// L'en-tête `Authorization` entier.
        let autorisation: String
        /// `X-Amz-Date`, à poser sur la requête avec la signature.
        let date: String
        /// Pour les tests sur les vecteurs publiés : chaque étape se vérifie à part.
        let requeteCanonique: String
        let chaineASigner: String
        let signature: String
    }

    /// `entetes` : ceux qui entrent dans la signature, en plus de `host` et `x-amz-date`.
    static func signer(methode: String,
                       url: URL,
                       entetes: [String: String],
                       corps: Data,
                       identifiant: String,
                       secret: SecretAWS,
                       region: String,
                       service: String,
                       instant: Date) -> Signee? {
        guard url.scheme == "https" || url.scheme == "http",
              let hote = url.host()?.lowercased(), !hote.isEmpty,
              url.path(percentEncoded: true).isEmpty || url.path(percentEncoded: true) == "/",
              let requete = requeteTriee(url),
              let (date, jour) = horodatages(instant)
        else { return nil }

        var signes: [String: String] = ["host": url.port.map { "\(hote):\($0)" } ?? hote, "x-amz-date": date]
        for (nom, valeur) in entetes {
            let cle = nom.lowercased().trimmingCharacters(in: .whitespaces)
            guard !cle.isEmpty, cle != "host", cle != "x-amz-date", cle != "authorization",
                  !valeur.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) })
            else { return nil }
            signes[cle] = valeur.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        }
        let noms = signes.keys.sorted()
        let entetesCanoniques = noms.map { "\($0):\(signes[$0] ?? "")\n" }.joined()
        let entetesSignes = noms.joined(separator: ";")

        let canonique = [methode.uppercased(), "/", requete, entetesCanoniques, entetesSignes,
                         hexa(SHA256.hash(data: corps))].joined(separator: "\n")
        let portee = "\(jour)/\(region)/\(service)/aws4_request"
        let chaine = [algorithme, date, portee, hexa(SHA256.hash(data: Data(canonique.utf8)))]
            .joined(separator: "\n")
        let cle = cleDeSignature(secret: secret, jour: jour, region: region, service: service)
        let signature = hexa(HMAC<SHA256>.authenticationCode(for: Data(chaine.utf8), using: cle))
        return Signee(autorisation: "\(algorithme) Credential=\(identifiant)/\(portee), "
                                    + "SignedHeaders=\(entetesSignes), Signature=\(signature)",
                      date: date,
                      requeteCanonique: canonique,
                      chaineASigner: chaine,
                      signature: signature)
    }

    static func cleDeSignature(secret: SecretAWS, jour: String, region: String, service: String) -> SymmetricKey {
        var cle = SymmetricKey(data: Data(("AWS4" + secret.valeur).utf8))
        for etape in [jour, region, service, "aws4_request"] {
            cle = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(etape.utf8), using: cle)))
        }
        return cle
    }

    /// `AAAAMMJJTHHMMSSZ` et `AAAAMMJJ`, en UTC et en chiffres latins quel que soit le réglage
    /// du Mac.
    static func horodatages(_ instant: Date) -> (date: String, jour: String)? {
        var calendrier = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else { return nil }
        calendrier.timeZone = utc
        let c = calendrier.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
        guard let a = c.year, let mo = c.month, let j = c.day, let h = c.hour, let mi = c.minute, let s = c.second,
              (1...9999).contains(a) else { return nil }
        let jour = String(format: "%04d%02d%02d", a, mo, j)
        return (jour + String(format: "T%02d%02d%02dZ", h, mi, s), jour)
    }

    /// Les paramètres triés par nom puis par valeur, chacun encodé selon la RFC 3986.
    private static func requeteTriee(_ url: URL) -> String? {
        guard let composants = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let paires = (composants.queryItems ?? []).map { (encoder($0.name), encoder($0.value ?? "")) }
        return paires.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            .map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    /// Les caractères non réservés de la RFC 3986 restent ; tout le reste s'encode, `+` et
    /// `/` compris.
    static func encoder(_ texte: String) -> String {
        var permis = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        permis.insert(charactersIn: "-._~")
        return texte.addingPercentEncoding(withAllowedCharacters: permis) ?? ""
    }

    private static func hexa<S: Sequence>(_ octets: S) -> String where S.Element == UInt8 {
        octets.map { String(format: "%02x", $0) }.joined()
    }
}
