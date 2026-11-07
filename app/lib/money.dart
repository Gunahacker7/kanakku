/// Money in integer paise (v1.1, final_spec §1).
///
/// This file is the ONLY rupees↔paise conversion boundary in the
/// app. Everything the v1.1 features store or compare — recurring
/// rule amounts, occurrence snapshots, budget caps for alerts, the
/// overall monthly cap — is an integer number of paise in a field
/// whose name ends in `Paise`. Floating-point money drifts
/// (0.1 + 0.2 != 0.3), and exact-paise equality is what recurring
/// matching and budget thresholds rely on; legacy double-rupee
/// values cross into paise only through these two functions.
library;

/// Rupees → paise, rounding to the nearest paise. The single
/// sanctioned conversion INTO paise (spec §1).
int paiseFromRupees(double r) => (r * 100).round();

/// Paise → rupees, for the surfaces that still speak rupees
/// (display, the legacy double `amount` on manual entries). The
/// single sanctioned conversion OUT of paise (spec §1).
double rupeesFromPaise(int p) => p / 100;
