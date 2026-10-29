-- Where a session took place, as the phone reported it (ADR 0012).
-- Never edit this file after it is committed; add a new migration instead.
--
-- Coordinates are private: this database and the private data store hold
-- them, never the public repo. The sanitizer must replace them before a
-- session becomes a fixture (docs/privacy.md).
CREATE TABLE session_sites (
    site_id                TEXT PRIMARY KEY,  -- random UUID from the phone
    session_id             TEXT NOT NULL REFERENCES sessions (session_id),
    device_id              TEXT NOT NULL,
    source_ns              INTEGER NOT NULL,  -- phone clock
    receive_mac_ns         INTEGER NOT NULL,
    environment            TEXT NOT NULL CHECK (environment IN ('indoor', 'outdoor', 'unspecified')),
    location_status        TEXT NOT NULL CHECK (location_status IN ('fix', 'off', 'denied', 'unavailable')),
    latitude               REAL,              -- degrees, WGS 84
    longitude              REAL,
    horizontal_accuracy_m  REAL,
    altitude_m             REAL,
    vertical_accuracy_m    REAL,
    precise                INTEGER,           -- 0 when only approximate location was allowed
    fix_age_s              REAL,
    CHECK ((location_status = 'fix') = (latitude IS NOT NULL)),
    FOREIGN KEY (session_id, device_id) REFERENCES devices (session_id, device_id)
) STRICT;
