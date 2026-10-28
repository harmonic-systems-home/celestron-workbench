# ADR 0002: Coordinate frames, units and quaternion convention

**Status:** Accepted

## Decision

### Units

SI is used throughout, with the unit in the field name where it isn't obvious:

| Quantity | Unit | Notes |
|---|---|---|
| Angle | rad | Reports may add degrees |
| Angular rate | rad/s | |
| Acceleration | m/s² | Core Motion reports in g. The phone converts using standard gravity g₀ = 9.80665 m/s² (exact, by definition). The constant is recorded in `hello`. |
| Magnetic field | µT | Field names end in `_ut` |
| Time | ns (integer) | See [ADR 0001](0001-timestamp-domains.md) |

### Vectors

Three-vectors are JSON arrays `[x, y, z]` and SQL columns `*_x`, `*_y`, `*_z`, all in the **phone body frame** unless the name says otherwise.

### Phone body frame

Apple's device frame, as Core Motion reports it: with the phone held face up in portrait,

- +X points to the right edge of the screen,
- +Y points to the top of the screen,
- +Z points out of the screen, toward the viewer.

This is right-handed. Rotation follows the right-hand rule about each axis.

### Quaternions

- Always stored with **named components** `w, x, y, z` (`{"w":…, "x":…, "y":…, "z":…}` on the wire; `q_w, q_x, q_y, q_z` columns). Never an anonymous array.
- Hamilton convention, `w` is the scalar part, unit length.
- **Attitude** `q` rotates vectors from the phone body frame into the Core Motion reference frame recorded for that session (`attitude_reference_frame`). Core Motion's `CMQuaternion` is used as-is, without reordering.
- `q` and `−q` are the same rotation. Comparisons must handle sign equivalence; storage does not canonicalize the sign, so raw data stays raw.
- Readers renormalize before use and flag samples whose norm differs from 1 by more than a configured tolerance.

### Reference frames

The attitude reference frame (`x_arbitrary_z_vertical`, `x_arbitrary_corrected_z_vertical`, `x_magnetic_north_z_vertical`, `x_true_north_z_vertical`) is recorded per session. Bench work prefers `x_arbitrary_z_vertical` or the corrected variant. The magnetic and true-north frames are experimental channels, not truth.

### Phone → telescope (OTA) frame

The OTA frame is defined at the attachment milestone. Each attachment revision stores a unit quaternion `phone_to_ota` (same convention: rotates phone-body vectors into the OTA frame), plus a human-readable description and a repeatability estimate. Attachment photos go in the private data store, not this repo.

## Consequences

- Every frame transform names its source and destination frame in code, e.g. `q_ota_from_phone`.
- Tests must cover angle wrapping, quaternion normalization and sign equivalence.
