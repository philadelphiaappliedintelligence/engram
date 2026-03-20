import Foundation
import Contacts

/// Native macOS Contacts access via Contacts.framework.
/// "What's Leo's email?" answered from the system contact store.
public struct ContactsTool: Tool {
    private let store = CNContactStore()

    public init() {}

    public var name: String { "contacts" }
    public var description: String {
        "Search the macOS Contacts. Find phone numbers, emails, addresses by name."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "query": Schema.string(description: "Name or keyword to search for"),
        ], required: ["query"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let query = input["query"]?.stringValue else {
            return "{\"error\": \"Missing query\"}"
        }

        // Request access
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = (try? await store.requestAccess(for: .contacts)) ?? false
        } else {
            granted = await withCheckedContinuation { cont in
                store.requestAccess(for: .contacts) { g, _ in cont.resume(returning: g) }
            }
        }
        guard granted else {
            return "{\"error\": \"Contacts access denied. Grant access in System Settings > Privacy > Contacts.\"}"
        }

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
        ]

        let predicate = CNContact.predicateForContacts(matchingName: query)
        let contacts: [CNContact]
        do {
            contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
        } catch {
            return "{\"error\": \"Search failed: \(error.localizedDescription)\"}"
        }

        if contacts.isEmpty { return "No contacts matching '\(query)'." }

        return contacts.prefix(5).map { contact in
            var lines: [String] = []
            let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
            lines.append("**\(name)**")

            if !contact.organizationName.isEmpty {
                let title = contact.jobTitle.isEmpty ? "" : "\(contact.jobTitle), "
                lines.append("  \(title)\(contact.organizationName)")
            }

            for email in contact.emailAddresses {
                lines.append("  Email: \(email.value)")
            }
            for phone in contact.phoneNumbers {
                lines.append("  Phone: \(phone.value.stringValue)")
            }

            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
