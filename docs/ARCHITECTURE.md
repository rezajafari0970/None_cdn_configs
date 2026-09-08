# None CDN Config Collector Architecture

## Project philosophy

The application is:

- Panel driven
- Modular
- Isolated
- Continuously running
- Self recovering
- Independent from unrelated server projects

## Runtime locations

Source repository:

    /root/None_cdn_configs

Production application:

    /opt/nonecdn

Database:

    /var/lib/nonecdn/database

Persistent state:

    /var/lib/nonecdn/state

Cache:

    /var/lib/nonecdn/cache

Logs:

    /var/log/nonecdn

Runtime locks:

    /run/nonecdn

Runtime user:

    nonecdn

## Planned modules

- Configuration Engine
- Database Engine
- Source Manager
- Fetch Scheduler
- Concurrent Fetcher
- Subscription Decoder
- Config Parser
- CDN Detector
- TTL Manager
- Deduplicator
- Storage Engine
- Cleanup Engine
- Health Monitor
- Watchdog
- Admin Panel
- Subscription API

## Scheduler

Scheduler cadence is based on absolute / monotonic timing.

Example for 10 seconds:

    12:00:00
    12:00:10
    12:00:20
    12:00:30

Request execution duration must not permanently shift the schedule.

## TTL

TTL is based on last seen.

Example:

    TTL = 3600 seconds

    last_seen  = 20:00
    expires_at = 21:00

If seen again at 20:55:

    last_seen  = 20:55
    expires_at = 21:55

## GitHub

GitHub is a development/build audit facility.

It must not become a runtime dependency.

Production collector operation must continue even if GitHub is unavailable.
