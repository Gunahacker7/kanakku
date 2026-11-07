/// App lock (Walnut parity, v0.5; hardened v1.0.4). The PIN itself
/// never lives in Dart: it is set and verified natively, where it is
/// stored only as a salted PBKDF2 hash (see PinStore.kt).
///
/// v1.0.4 (audit F1): the old "Reset lock" escape hatch is GONE —
/// after 5 wrong PINs the lock screen used to offer to delete the
/// PIN outright. Failed attempts are now counted natively (shared
/// by every PIN prompt) and trigger a growing lockout instead; the
/// PIN can only be changed or disabled from Settings after a
/// successful unlock. This file keeps the pieces that are testable
/// here: the PIN format rules and the pure lockout schedule, which
/// mirrors PinStore.lockoutSeconds in Kotlin exactly.
library;

/// PINs are 4–6 digits.
bool isValidPinFormat(String pin) =>
    pin.length >= 4 &&
    pin.length <= 6 &&
    pin.codeUnits.every((c) => c >= 0x30 && c <= 0x39);

/// Consecutive failures that trip a lockout.
const pinMaxFailures = 5;

/// Lockout for the first offence, in seconds.
const pinBaseLockoutSeconds = 30;

/// No lockout ever exceeds this (15 minutes).
const pinMaxLockoutSeconds = 900;

/// Lockout length in seconds for the [lockoutIndex]-th lockout
/// (0-based): 30 s, doubling each time (60, 120, 240, 480), capped
/// at [pinMaxLockoutSeconds].
int pinLockoutSeconds(int lockoutIndex) {
  var s = pinBaseLockoutSeconds;
  var i = 0;
  while (i < lockoutIndex && s < pinMaxLockoutSeconds) {
    s = s * 2;
    if (s > pinMaxLockoutSeconds) s = pinMaxLockoutSeconds;
    i++;
  }
  return s;
}
