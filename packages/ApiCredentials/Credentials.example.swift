//
//  Credentials.example.swift
//
//  Template for the Telegram API credentials Kite builds against.
//
//  Get a pair at https://my.telegram.org → API development tools, then keep the real file
//  outside the repository and symlink it into place:
//
//      mkdir -p ~/.config/kite && chmod 700 ~/.config/kite
//      cp packages/ApiCredentials/Credentials.example.swift ~/.config/kite/Credentials.swift
//      chmod 600 ~/.config/kite/Credentials.swift
//      $EDITOR ~/.config/kite/Credentials.swift
//      ln -s ~/.config/kite/Credentials.swift \
//            packages/ApiCredentials/Sources/ApiCredentials/Credentials.swift
//
//  tools/link_credentials.sh does all of that for you.
//
//  The link is gitignored, so an api_hash cannot be committed, and because the real file
//  lives outside the tree `git clean -fdx` cannot delete your credentials.
//
//  Note that these values are compiled into the binary and are recoverable from any build
//  with `strings`, as they are in every Telegram client. Keeping them out of the repository
//  avoids automated scraping of public git history; it does not make them secret.
//
//  The build fails without this file, deliberately: a client shipped on someone else's
//  api_id gets that key rate-limited or banned, and the failure lands on whoever installed
//  it rather than on you.
//

import Foundation

enum KiteCredentials {
    static let apiId: Int32 = 0
    static let apiHash: String = ""
}
