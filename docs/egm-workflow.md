# EGM Workflow for Kanakku (adopted 2026-11-06)

Source: google/elephant-goldfish-model (Apache 2.0), cloned at `../egm-reference/`.
Reference skills: `egm-reference/skills/{egm-brainstorm,egm-draft,egm-review,egm-resolve,egm-bootstrap,egm-drift-report,egm-review-loop}`.

## How we run it here

- **Elephant = Jarvis (this agent).** Holds full Kanakku context: KANAKKU-SPEC.md,
  security audit, offline build constraints (no new pub deps, local maven only).
  Design ONLY — no code during Phases 1–2.
- **Goldfish = fresh subagents with zero conversation context.** They receive ONLY
  the design document + referenced source files, never the design discussion.
- **Human = Guna.** Resolves trade-offs, approves the spec before any code is written.

## Phases

1. **Brainstorm (Elephant):** explore the feature, debate trade-offs, challenge
   assumptions → `docs/designs/<feature>/concepts_brief.md`. No code.
2. **Draft (Elephant):** section-by-section design doc → `design_draft.md`
   (problem, technical plan, alternatives, exact files to change, data structures,
   function signatures). Guna feedback after each section.
3. **Goldfish review (zero-context subagents):**
   - Comprehension check — Goldfish must explain the design back; failure = doc is ambiguous.
   - Antagonistic review — hostile reviewers hunt edge cases, hidden dependencies, gaps.
   - Implementation readiness — strict go/no-go: file paths, data structures, signatures
     all present and unambiguous.
4. **Resolve + approve:** findings funnel back to the Elephant; Guna approves the
   final spec → saved under `docs/designs/<feature>/`. Only then implementation starts.

## Kanakku-specific review lenses for Goldfish

- Money correctness: paise-level rounding, no float drift, reversal/duplicate SMS handling.
- Security: Keystore encryption at rest, backup encryption, no plaintext finance data.
- Offline build: no new pub dependencies, Gradle via local maven only.
- Data safety: migrations must never lose existing user transactions.

## First run (proposed)

Kanakku v1.1 feature set: recurring transactions, budget alerts (80%/100%),
biometric unlock — design phase only, no code until Guna approves the spec.
