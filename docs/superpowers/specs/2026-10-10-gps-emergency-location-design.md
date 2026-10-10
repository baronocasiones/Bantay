# Emergency SMS location design

## Goal

Include the phone's location in Bantay emergency SMS messages so the emergency
contact can find the user. Keep the SMS path independent of GPS availability.

## Existing behavior

- Fall detection starts a 15-second native countdown and sends SMS at its
  deadline.
- Manual SOS sends immediately.
- The SMS templates currently omit coordinates (manual SOS says location is
  unavailable).
- The Android manifest has `SEND_SMS`, but no location permission. `SPEC.md`
  calls for coordinates only and no reverse geocoding.

## Approaches considered

1. **Fresh fix during the fall countdown (recommended).** Request a current
   location when the fall is confirmed. Use the countdown window to acquire it.
   At the deadline, send with coordinates if available; otherwise send the SMS
   without location. GPS never extends the countdown.
2. **Last-known location only.** Fast and low-power, but may direct the contact
   to an old location after the user has moved.
3. **Wait for a fresh fix before sending.** Could improve location freshness,
   but delays an emergency SMS and can fail indoors. Rejected.

## Proposed behavior

- Explain and request location permission during emergency-contact setup. Allow
  approximate location if the user declines precise location.
- Add the Android `location` foreground-service type and its manifest
  permission to the existing sensor service. Start that service while the app
  is visible, after the user grants location permission. Do not request
  `ACCESS_BACKGROUND_LOCATION`.
- On confirmed fall, request a fresh device location in parallel with the
  existing 15-second countdown.
- At the existing deadline, append latitude, longitude, and a tap-to-open Maps
  URL when a usable fix has arrived. Otherwise send the existing alert text
  with `Location unavailable`.
- Manual SOS remains immediate. Include a last-known location only if it is
  recent (at most two minutes old) and usable; otherwise send immediately with
  `Location unavailable`.
- Do not reverse-geocode, use an online location API, or wait for location in
  any path that sends SMS.
- Send coordinates only to the configured emergency contact. Keep the same
  contact, countdown, outbox, and delivery-state behavior.

## Failure handling

Permission denied, location services disabled, no fix, stale location, and
provider errors all degrade to the current SMS wording. They must never cancel,
delay, or suppress SMS. Do not label a queued or carrier-accepted SMS as
delivered just because it contains a location.

## Verification

- Unit-check message formatting with and without a location.
- Check that a delayed or missing location cannot move the 15-second SMS
  deadline.
- Build and install the arm64 Android app; confirm the permission prompt and
  location capture on the SM-A127F.
- With permission granted, verify the emergency text contains usable
  coordinates and accuracy, without a Maps URL. With permission denied or location unavailable,
  verify the SMS still sends without coordinates.
- Verify screen-off operation on Android 13 and inspect the location
  foreground-service declaration for newer Android versions.

## Scope

Android and Flutter alert path only. No model changes, server, reverse
geocoding, or continuous location tracking. All changes and verification
artifacts stay local; do not commit or push.

## Platform constraint

Android requires a location foreground-service type and its manifest
permission for location access from a foreground service on newer Android
versions. The service must be started while the app is visible when relying on
foreground location permission; this design adds the location type to the
existing service at startup rather than trying to create a location service
after a background fall. This avoids requesting background-location permission.
See [Android foreground-service types](https://developer.android.com/develop/background-work/services/fgs/service-types?hl=en)
and [background-start restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start?authuser=111).
