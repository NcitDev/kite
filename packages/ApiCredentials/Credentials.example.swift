//
//  Credentials.example.swift
//
//  Template for the Telegram API credentials Kite builds against.
//
//  Copy this file to Sources/ApiCredentials/Credentials.swift and fill in the pair issued
//  to you at https://my.telegram.org → API development tools. That destination is
//  gitignored, so your api_hash never lands in the repository.
//
//      cp packages/ApiCredentials/Credentials.example.swift \
//         packages/ApiCredentials/Sources/ApiCredentials/Credentials.swift
//
//  The build fails without it, deliberately: a client shipped on someone else's api_id
//  gets that key rate-limited or banned, and the failure lands on whoever installed it.
//

import Foundation

enum KiteCredentials {
    static let apiId: Int32 = 0
    static let apiHash: String = ""
}
