# Thumper Runtime Architecture

Thumper von AUTOS is WIZWIKI's customer-communication runtime. It combines current
thread state, organization-owned facts, model drafting, deterministic guardrails, and
operator handoff rules.

## Components

- `DealReports::CommsDraftWriter` assembles the current thread and requests a draft.
- `Comms::SmsLaneResolver` identifies the active customer intent.
- PostgreSQL stores CRM records, artifacts, calls, scorecards, and message state.
- Optional retrieval is scoped to operator-approved documents owned by the organization.
- SMS/email providers deliver only after the applicable authorization and safety gates.
- `Comms::SmsBodySafety`, `Comms::DraftValidator`, and post-send supervision reject
  internal leaks, unsupported claims, stale answers, and opt-out violations.

## State boundaries

Conversation state belongs in named services when it is reusable or testable. Reset
actions must clear stale lane, contact preference, handoff, draft, and thread state.
External sends, retrieval mutation, and provider calls require explicit configuration
and regression coverage for allowed and blocked paths.
