# apdu_pos — Flutter app for UICC/eSIM APDU access

A minimal Flutter app that calls Android's `TelephonyManager` to:

1. Open a logical channel against a SIM/eSIM applet (`iccOpenLogicalChannel`)
2. Transmit APDUs on that channel (`iccTransmitApduLogicalChannel`)
3. Close the logical channel (`iccCloseLogicalChannel`)

It targets POS devices with a removable IoT eSIM (MFF2 or 2FF eUICC).

## Can I just test in debug mode without carrier signing?

**No — Android does not bypass the permission check based on build type.** A
debuggable APK gets the same `SecurityException` as a release APK if it is
neither carrier-privileged nor system-signed. There is no `adb` flag or
manifest setting that opens this up.

What you can do for development:

1. **Add your debug keystore's SHA-256 to the eSIM profile's ARA-M rules
   (recommended).** If you (or your MNO/MVNO/SM-DP+) can provision a test
   profile that contains an access rule whose `REF-DO` carries the SHA-256
   of `~/.android/debug.keystore`, the app gets carrier privileges
   automatically — `hasCarrierPrivileges()` returns `true` and the icc*
   methods work with no special platform permission.
2. **Push as a privileged system app.** On a rooted / `userdebug` POS image,
   install the APK to `/system/priv-app/apdu_pos/` and allowlist
   `android.permission.MODIFY_PHONE_STATE` in
   `/etc/permissions/privapp-permissions-*.xml`.
3. **Vendor SDK detour.** A few POS OEMs (Sunmi, PAX, Verifone, Newland)
   expose their own SIM/SE APIs that bypass the Android UICC layer. If
   neither (1) nor (2) is feasible, check whether the device ships such an
   SDK.

The app deliberately surfaces `SecurityException` in the UI log so you can
verify wiring on any phone, then unblock the privilege side separately.

## Compute your debug-keystore SHA-256 (for option 1)

```bash
keytool -list -v -alias androiddebugkey \
        -keystore ~/.android/debug.keystore \
        -storepass android -keypass android \
  | grep "SHA-256"
```

Take the 32-byte hex value and have it embedded in the profile's ARA-M rule
under an `AR-DO` whose `REF-DO` contains your APK certificate hash and the
AID(s) you want to address (or `FF FF FF FF FF FF FF` for any AID, if the
issuer permits).

Verify in-app: tap the refresh icon in the AppBar. The privilege banner
turns green when ARA-M loads the rule and the subscription matches.

## Build & run

```bash
cd apdu_pos
flutter create .                  # only on first checkout — fills in
                                  # gradle wrapper, MainActivity stub etc.
                                  # The files in this repo will be kept;
                                  # answer 'n' if it asks to overwrite
                                  # AndroidManifest.xml, MainActivity.kt,
                                  # main.dart, build.gradle.
flutter pub get
flutter run                        # plug in a POS device with eSIM
```

If `flutter create .` does overwrite the files above, restore them from
this repo (only the four custom files matter — everything else is stock).

## Layout

```
apdu_pos/
├── pubspec.yaml
├── lib/main.dart                              # Flutter UI + MethodChannel
├── android/app/build.gradle                   # namespace, minSdk=26
├── android/app/src/main/AndroidManifest.xml   # permissions
└── android/app/src/main/kotlin/com/example/apdu_pos/
    └── MainActivity.kt                        # TelephonyManager bridge
```

## Default values in the UI

- **AID** `A00000015141434C00` — ARA-M (Access Rule Application Master).
  Selecting it is a useful smoke test if the eSIM exposes one.
- **APDU** `80CA00A000` — `GET DATA` with tag `00A0`. Replace with whatever
  your applet expects (e.g., `00A4040007 <AID>` to SELECT, or vendor
  proprietary commands).

## Permissions in the manifest

- `READ_PHONE_STATE` — normal runtime permission; the app requests it at
  first run via `SubscriptionManager.getActiveSubscriptionInfoForSimSlotIndex`.
  If denied, the app still works on the default subscription.
- `MODIFY_PHONE_STATE` — declared for the platform-signed path. Normal
  apps will see it as **not granted**, which is expected; carrier
  privileges via ARA-M is the path forward for unprivileged builds.

## What the three calls map to in Android

| Flutter | Kotlin | Android API |
| --- | --- | --- |
| `Telephony.openLogicalChannel` | `tm.iccOpenLogicalChannel(aid, p2)` | API 26+ |
| `Telephony.transmitApdu` | `tm.iccTransmitApduLogicalChannel(ch, cla, ins, p1, p2, p3, data)` | API 21+ |
| `Telephony.closeLogicalChannel` | `tm.iccCloseLogicalChannel(ch)` | API 21+ |
| `Telephony.hasCarrierPrivileges` | `tm.hasCarrierPrivileges()` | API 22+ |

The Kotlin layer resolves a per-slot `TelephonyManager` via
`SubscriptionManager.getActiveSubscriptionInfoForSimSlotIndex(slot)` →
`createForSubscriptionId(subId)`, so multi-SIM POS devices behave
deterministically.

## Known errors and what they mean

| Error | Most likely cause |
| --- | --- |
| `SECURITY: No Carrier Privilege` | ARA-M rule absent / cert mismatch — app neither carrier-privileged nor system-signed |
| `STATE: status=2 (NO_SUCH_ELEMENT)` from `openLogicalChannel` | AID not present on the card — wrong AID, or the applet isn't installed on this profile |
| `STATE: status=3 (MISSING_RESOURCE)` | Card has no free logical channels — close one first |
| Empty response, status=0, channel=-1 | UICC link not yet ready — wait a few seconds after boot / SIM swap |

## Notes for an OEM-signed build

If you can platform-sign the APK, you may want to switch the Kotlin
implementation to the `BySlot` variants (`iccOpenLogicalChannelBySlot`,
`iccTransmitApduLogicalChannelBySlot`, `iccCloseLogicalChannelBySlot`).
They're `@SystemApi` and require `MODIFY_PHONE_STATE`, but skip the
subscription resolution step entirely. The Kotlin file in this repo
already isolates that swap to `tmForSlot()` + the three handlers — only a
few lines need to change.



Device[POS] => attached => IOT eSIM
flutter app => APDU => IOT eSIM
TelephonyManager => Access => IOT eSIM
carier app => sha265 => IOT eSIM [ara-m]


connect = open
disconnect = close
transmit = transmit