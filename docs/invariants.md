# Contracts

| ID | Contract | Proof |
| --- | --- | --- |
| INV-MAIL-account-isolation | Provider IDs collide safely across accounts. | store contract tests |
| INV-MAIL-restart | Imported mail and full-text results survive reopening. | store contract tests |
| INV-MAIL-upsert | Header refresh preserves an already cached body. | store contract tests |
| INV-MAIL-bounded-list | A list returns only a bounded page, without bodies. | store contract tests |
| INV-MAIL-query-literal | User search text cannot become SQL or FTS syntax. | store contract tests |
| INV-MAIL-plain-text | MIME text and HTML alternatives remain separate. | MIME tests |
| INV-MAIL-html-passive | Cached HTML excludes scripts, forms and remote resources. | HTML tests and native policy self-test |
| INV-MAIL-oauth-state | OAuth callback state must match the pending login. | OAuth callback tests |
| INV-MAIL-main-thread | Database and provider calls run off the AppKit main thread. | bridge precondition and native self-test |
| INV-MAIL-latest-selection | Stale body responses cannot replace a newer selection. | native controller generation guard |

The native reader defaults to text and creates WebKit only on first HTML use. Tokens live in Keychain. Mail cache is local plaintext with user-only permissions. Provider access is read-only.
