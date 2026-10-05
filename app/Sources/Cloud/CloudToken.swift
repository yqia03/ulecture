import Foundation
import Security

// Only explicitly pasted credentials are accepted. No ADC, environment,
// filesystem credential discovery, browser login, or ambient Keychain lookup.
actor CloudTokenBroker {
    private var cached: [String: (token: String, expires: Date)] = [:]
    func token(for credential: String, session: URLSession) async throws -> String {
        guard credential.trimmingCharacters(in: .whitespacesAndNewlines).first == "{" else { return credential }
        let key = cloudHash(credential)
        if let entry = cached[key], entry.expires.timeIntervalSinceNow > 60 { return entry.token }
        guard let object = try? JSONSerialization.jsonObject(with: Data(credential.utf8)) as? [String: Any] else { throw CloudFailure.authentication }
        // The JSON's token_uri cannot redirect credentials to an arbitrary host.
        if let uri = object["token_uri"] as? String, uri != "https://oauth2.googleapis.com/token" { throw CloudFailure.invalidConfiguration }
        var fields: [String: String]
        if object["type"] as? String == "service_account" {
            guard let email = object["client_email"] as? String, email.hasSuffix(".gserviceaccount.com"), let pem = object["private_key"] as? String else { throw CloudFailure.authentication }
            let now = Int(Date().timeIntervalSince1970)
            let header = try encodeJSON(["alg": "RS256", "typ": "JWT"])
            let payload = try encodeJSON(["iss": email, "scope": "https://www.googleapis.com/auth/cloud-platform", "aud": "https://oauth2.googleapis.com/token", "iat": now, "exp": now + 3600])
            let message = header + "." + payload
            let key = try privateKey(pem)
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(message.utf8) as CFData, &error) as Data? else { throw CloudFailure.authentication }
            fields = ["grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": message + "." + base64URL(signature)]
        } else if let refresh = object["refresh_token"] as? String, let clientID = object["client_id"] as? String, let clientSecret = object["client_secret"] as? String {
            fields = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID, "client_secret": clientSecret]
        } else { throw CloudFailure.authentication }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&").utf8)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw CloudRequestError(failure: Task.isCancelled ? .cancelled : .network) }
        guard let http = response as? HTTPURLResponse else { throw CloudFailure.authentication }
        guard http.statusCode == 200 else { throw CloudRequestError(failure: http.statusCode == 429 ? .rateLimited : (http.statusCode >= 500 ? .unavailable : .authentication)) }
        guard data.count < 64_000, let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], let access = result["access_token"] as? String, !access.isEmpty, let expiry = result["expires_in"] as? Int, expiry > 60 else { throw CloudFailure.authentication }
        // Bounded to the explicitly used configurations in this process.
        if cached.count >= 4 { cached.removeAll() }
        cached[key] = (access, Date().addingTimeInterval(Double(min(expiry, 3600))))
        return access
    }
    func clear() { cached.removeAll() }
    private func encodeJSON(_ object: [String: Any]) throws -> String { base64URL(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) }
    private func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    private func privateKey(_ pem: String) throws -> SecKey {
        let body = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body) else { throw CloudFailure.authentication }
        // SecKey accepts PKCS#1. Standard Google credentials use PKCS#8, whose
        // third sequence child is the RSA private-key octet string.
        let bytes = [UInt8](der)
        func element(_ offset: Int) throws -> (tag: UInt8, body: Range<Int>, end: Int) {
            guard offset + 2 <= bytes.count else { throw CloudFailure.authentication }
            let tag = bytes[offset], first = Int(bytes[offset + 1]); var cursor = offset + 2; var length = first
            if first & 0x80 != 0 {
                let width = first & 0x7f; guard (1...4).contains(width), cursor + width <= bytes.count else { throw CloudFailure.authentication }
                length = 0; for byte in bytes[cursor..<(cursor + width)] { length = length * 256 + Int(byte) }; cursor += width
            }
            guard length > 0, cursor + length <= bytes.count else { throw CloudFailure.authentication }
            return (tag, cursor..<(cursor + length), cursor + length)
        }
        let outer = try element(0); let version = try element(outer.body.lowerBound); let next = try element(version.end)
        let material: Data
        if next.tag == 0x30 { let octet = try element(next.end); guard octet.tag == 0x04 else { throw CloudFailure.authentication }; material = Data(bytes[octet.body]) }
        else { material = der }
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(material as CFData, attributes as CFDictionary, &error) else { throw CloudFailure.authentication }
        return key
    }
}
