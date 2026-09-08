# None CDN Config Collector - Project Status

Updated: 2026-09-08T17:50:38+00:00

## Infrastructure

- [x] GitHub development repository
- [x] Development audit runner
- [x] Isolated runtime user
- [x] Isolated directories
- [x] PHP
- [x] SQLite
- [x] SQLite WAL

## Core Stage 1

- [x] Database connection engine
- [x] SQLite WAL configuration
- [x] Foreign key enforcement
- [x] Migration engine
- [x] Main database schema
- [x] Typed Settings Engine
- [x] Default application settings
- [x] Source Manager
- [x] Per-source interval support
- [x] Per-source TTL support
- [x] Custom headers storage
- [x] TLS verification setting
- [x] last_seen TTL model
- [x] Integration tests
- [x] SQLite integrity check

## Database entities

- settings
- sources
- configs
- config_sources
- config_observations
- fetch_cycles
- fetch_results
- cdn_rules
- overrides
- system_health
- audit_events
- migrations

## Status

CORE STAGE 1 COMPLETE

## Next

Panel v0.1

The next stage will provide:

- Login
- Dashboard
- Global settings
- Add/Edit/Delete Sources
- Enable/Disable Sources
- Per-source TTL
- Per-source fetch interval
- Request timeout
- TLS setting
- Custom request headers

## Panel Stage 2

Completed: 2026-09-08T17:56:13+00:00

- [x] Admin authentication
- [x] Session isolation
- [x] CSRF protection
- [x] Dashboard
- [x] Global Settings UI
- [x] Sources UI
- [x] Add/Edit/Delete source
- [x] Enable/Disable source
- [x] Per-source fetch interval
- [x] Per-source TTL
- [x] Request timeout
- [x] TLS verification
- [x] Custom headers
- [x] Dedicated PHP-FPM pool
- [x] Dedicated Nginx listener
- [x] HTTP integration test
- [x] Hard SQLite foreign-key enforcement test

Status:

PANEL v0.1 COMPLETE

Panel port:

18088

## Snapshot UI/FETCH Base - Stage 3

Completed: 2026-09-08T18:09:28+00:00

- [x] Config Location snapshot imported as reference
- [x] Original panel UI preserved
- [x] Original Source management actions preserved
- [x] Fetch Now preserved
- [x] Reset Runtime preserved
- [x] Rebuild preserved
- [x] Clear Data preserved
- [x] Bulk source tools preserved
- [x] Independent-worker fetcher imported
- [x] Paths isolated to /var/lib/nonecdn
- [x] Production path isolated to /opt/nonecdn
- [x] TTL backend added
- [x] Last-seen TTL helper added
- [x] Python virtual environment installed
- [x] Import/syntax tests passed

Status:

SNAPSHOT BASE IMPORTED

Next:

Adapt Config Store for TTL + Non-CDN classification
and connect the new Python panel to the NoneCDN runtime.

## Stage 4 - Fetcher + TTL + CDN

Completed: 2026-09-08T18:15:51+00:00

- [x] CDN detector
- [x] Address extraction
- [x] Host/SNI inspection
- [x] A/AAAA resolution
- [x] CNAME resolution
- [x] Cloudflare CIDR matching
- [x] Conservative CDN ASN matching
- [x] Unknown classification
- [x] Only NON_CDN configs stored
- [x] CDN configs rejected
- [x] Unknown configs rejected
- [x] Raw configs preserved
- [x] Per-source TTL
- [x] last_seen TTL refresh
- [x] Shared config source expiry
- [x] Automatic expired cleanup
- [x] Missing-on-next-fetch does NOT instantly delete config
- [x] Fetch interval anchored to cycle start
- [x] Independent source workers preserved
- [x] systemd automatic restart
- [x] Unit/integration tests
- [x] Isolated NoneCDN service

Status:

FETCHER + TTL + CDN ENGINE ACTIVE

Next:

Snapshot Panel Runtime Integration
+
Output Subscription API
+
CDN/Direct statistics in UI
