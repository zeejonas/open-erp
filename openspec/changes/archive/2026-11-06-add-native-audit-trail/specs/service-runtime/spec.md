## ADDED Requirements

### Requirement: Trusted client IP resolution
The system SHALL read `TRUSTED_PROXY_COUNT` as a non-negative integer, defaulting to `0`. Any other value SHALL fail startup. With `0`, the client IP SHALL be the socket remote address, ignoring forwarding headers. With N greater than 0, it SHALL be the Nth address from the right across `X-Forwarded-For` values. If that address is missing or invalid, it SHALL fall back to the socket remote address. `Forwarded` SHALL be ignored.

#### Scenario: Direct client spoofs header
- **WHEN** `TRUSTED_PROXY_COUNT` is `0` and a client sends `X-Forwarded-For`
- **THEN** the socket remote address is used

#### Scenario: One trusted proxy
- **WHEN** `TRUSTED_PROXY_COUNT` is `1` and the header is `198.51.100.9, 203.0.113.7`
- **THEN** the client IP is `203.0.113.7`

#### Scenario: Header too short
- **WHEN** `TRUSTED_PROXY_COUNT` is `2` and the header contains one address
- **THEN** the socket remote address is used

#### Scenario: Invalid count
- **WHEN** `TRUSTED_PROXY_COUNT` is `-1` or not an integer
- **THEN** startup fails
