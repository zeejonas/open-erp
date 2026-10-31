## 1. Problem formatting

- [x] 1.1 Add the Problem DTO, code enum and typed AbortError; map `verifiedAccessToken()` failures to invalid_access_token.
- [x] 1.2 Replace the default error middleware with route logging plus the problem middleware; test status fallbacks, invalid_access_token with WWW-Authenticate, header preservation, generic 5xx detail, validation parameter names and one log per failure.
- [x] 1.3 Update existing tests that assert the old body, keeping status, tenant-enumeration and validation behavior unchanged.

## 2. Contract

- [x] 2.1 Add a reusable problem response annotation and apply it to existing routes; assert the media type/schema in APIDocumentationTests.
- [x] 2.2 Document the code catalog and "branch on code, not text" in the README; run strict OpenSpec validation.
