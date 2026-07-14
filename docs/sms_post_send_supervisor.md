# SMS Post-Send Supervisor

## Working name

`Comms::PostSendSupervisor`

This is also known as a post-send reconciliation loop, outbound QA supervisor, or corrective follow-up policy.

## Purpose

After an outbound SMS is sent, scan the actual sent body against the current thread, selected product lane, retrieved RAG facts, and delivery metadata. If the message was incomplete, stale, wrong, or blocked important context, decide whether to log it, queue review, or send a short corrective follow-up.

## Responsibilities

- Confirm the outbound body matches the latest full thread, not just the latest single inbound sentence.
- Detect stale product lane, stale quantity, stale contact preference, wrong link, wrong price, missing answer, or internal/system-style wording.
- Detect when the customer sent more messages while Thumper was drafting and decide whether a second response is needed.
- Send a correction only when high-confidence, customer-safe, and useful.
- Prefer a concise correction over an apology loop.
- Keep a cooldown so Thumper does not double-text repeatedly.
- Emit telemetry so operators can see why the supervisor did or did not send a follow-up.

## Worker Watchdog

Worker health should be handled separately by a watchdog/heartbeat monitor. The watchdog can check Alice/Qwen/SMS workers, queue age, stuck jobs, claimed jobs, and restart signals. It should not write customer-facing text.

## Correction Policy

Good corrective follow-up:

> Quick correction: I should have used the reviewed catalog value. I have paused this thread so an operator can confirm the price before anything else is sent.

Bad corrective follow-up:

> Sorry, my previous model output failed validation because metadata indicated LAWN_SIGNS.

## Send A Correction When

- The sent SMS quoted the wrong price or quantity.
- The sent SMS used the wrong product link.
- The sent SMS ignored a direct customer question.
- The sent SMS used stale metadata after a reset.
- The sent SMS responded to only one of multiple stacked customer messages.
- The customer sent a lane change while Thumper was drafting.
- The sent SMS promised a marketing consultant handoff before collecting contact preference/details.

## Do Not Auto-Correct When

- The issue is stylistic only.
- The correction would repeat the same content.
- The customer already replied after the sent SMS.
- The customer opted out with hard STOP.
- The issue requires human judgment, custom pricing, rush availability, route targeting, or account strategy.

## Minimum Telemetry

- supervisor_status: skipped, review_only, correction_sent, blocked
- issue_codes: wrong_price, wrong_link, stale_lane, missed_question, stacked_inbound, handoff_details_missing, worker_stale
- confidence: low, medium, high
- correction_body
- related_outbound_id
- latest_inbound_ids_seen
- worker_health_snapshot
