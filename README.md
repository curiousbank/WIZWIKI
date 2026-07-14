# WIZWIKI

WIZWIKI is a human-guided automation system for organization-scoped CRM operations,
Thumper von AUTOS communications, report generation, local AI workers, and
weather-market research. It turns call blocks, conversation history, call memory, and
approved organization knowledge into useful work while people remain the teachers,
reviewers, and release authority.

The repository starts with fresh history and contains code, neutral configuration
templates, and synthetic test fixtures. It does not ship customer records, production
credentials, proprietary knowledge packs, live product claims, or runtime exports.

## What it does

- manages organization-scoped contacts, companies, deals, call blocks, and artifacts
- imports and stages HubSpot or CSV call blocks into claimable operator queues
- turns call-block context and SMS history into drafts, client reports, internal action
  reports, copy packages, editable DOCX output, and Canva build kits
- runs manual, COPILOT, and tightly gated FULL AUTO SMS workflows
- receives and sends SMS through Twilio-compatible paths and maps Aircall routing
  identities back to the responsible operator
- runs multi-turn Recursive DOJO batches with PASS/REVIEW scorecards and timing telemetry
- publishes session and daily learning scrolls without promoting unreviewed lessons
- coordinates authenticated local or hosted generation workers
- supports optional retrieval over documents an organization owns and approves
- imports approved call memory for search, summaries, digests, and future operator context
- keeps active and challenger weather policies in separate paper lanes
- records forecast snapshots, decisions, outcomes, and calibration measurements
- exposes a scrollable wager ledger for retrospective review
- requires independent runtime controls before any external message or live order

## Human-guided automation

Human guidance is the core process, not a fallback. WIZWIKI separates assistance,
learning, and external action into an observable loop:

1. **Scope the batch.** An operator chooses the visible call blocks, records, source
   documents, conversation history, and objective that belong in the run.
2. **Build useful work.** Workers prepare SMS/email drafts, reports, proposal material,
   campaign copy, or paper-strategy decisions with source and timing metadata attached.
3. **Review the result.** Operators edit drafts, approve handoffs, reject unsupported
   claims, and grade complete DOJO conversations as PASS or REVIEW.
4. **Capture the lesson.** Questions, answers, model routes, gates, feedback, and timing
   are preserved. Only explicitly approved lessons can return to future context.
5. **Promote carefully.** COPILOT work remains queued for human approval. Automated SMS
   or live market action requires separate eligibility, safety, and runtime gates.

This makes automation teachable in batches: the system can move faster as its evidence
and reviews improve without silently granting a model more authority.

## CRM, communications, and reports

The communications workspace combines owner queues, call-block claiming, deduplication,
opt-out handling, multilingual preparation, scheduled follow-ups, and human handoff.
Pre-send verification blocks unreviewed prices, links, promises, or unsafe content;
post-send supervision records outcomes and can return a conversation to an operator.

The report pipeline can use the CRM record, call-block notes, SMS thread, approved call
memory, campaign context, and supplied media to produce several distinct outputs:

- buyer-facing strategy reports
- internal account-manager notes, risks, and next actions
- SMS/email COMM KIT batches for review
- ads, postcards, and campaign copy
- editable DOCX reports and structured Canva handoff kits

Report and design output remains a draft until the assigned operator or designer
approves it.

## Operating model

Rails owns authorization, queues, context boundaries, audit records, and persistence.
Generation workers run separately and authenticate to narrow worker endpoints. A local
weather lane can use Qwen 8B through Ollama; other surfaces can use a configured hosted
provider. The application remains bootable when no model provider is connected.

Retrieval and embeddings are optional. The public configuration is empty by default.
Only reviewed, organization-owned source material should be added, and operators should
define retention and access boundaries before enabling ingestion.

## Weather research

Weather experiments are designed around versioned policies and immutable decision-time
snapshots. The active and challenger paper lanes are isolated from the live lane, and
each policy is limited to one position per event day. Evaluation includes exact
forecast-date alignment, official settlement sources, fee-aware sizing, walk-forward
calibration, Brier score, and comparison with market-implied probabilities.

Paper trading does not establish profitability. Keep live execution disabled until a
policy beats its baseline out of sample, prospective results remain positive after
fees, the loss guard is healthy, and an operator explicitly promotes that version.

Primary references:

- [Kalshi weather-market settlement guidance](https://help.kalshi.com/en/articles/13823837-weather-markets)
- [Kalshi fee schedule](https://kalshi.com/docs/kalshi-fee-schedule.pdf)
- [National Weather Service API documentation](https://www.weather.gov/documentation/services-web-api)

## Safety boundary

- Drafting is not sending; customer communications require the configured review path.
- COPILOT batches prepare drafts but do not send them.
- FULL AUTO can contact real people only when provider credentials, eligibility,
  recipient, opt-out, turn-limit, pre-send, and runtime gates all allow it.
- Human-handoff requests and unsupported claims return the conversation to an operator.
- Paper weather lanes never place external orders.
- Live weather actions require separate enablement, validation, risk checks, and a
  non-latched loss guard.
- Unknown product prices, offers, and checkout links fail closed instead of being guessed.
- Logs, storage, database dumps, generated media, and environment files are private
  runtime artifacts and must remain outside Git.

## Stack

- Ruby 3.4.9 and Rails 8.1
- PostgreSQL 17 with optional `pgvector`
- Solid Queue, Solid Cache, and Solid Cable
- Turbo, Stimulus, Importmap, and Tailwind CSS
- Ollama/Qwen workers and configurable hosted model providers
- optional HubSpot, Fathom, Twilio, Aircall routing, Postmark, Slack, Shopify, Canva,
  Cloudinary, and S3-compatible storage integrations

## Quick start

Install the Ruby version from `.ruby-version`, Bundler, PostgreSQL 17, and the native
libraries required by `pg` and `ruby-vips`.

Use an untracked local environment file or a development-only `DATABASE_URL`. Never run
tests against production services or a production database.

```sh
bundle install
DATABASE_URL=postgresql:///wizwiki_development bin/rails db:prepare
DATABASE_URL=postgresql:///wizwiki_development bin/dev
```

Run the test suite with an isolated test database:

```sh
RAILS_ENV=test DATABASE_URL=postgresql:///wizwiki_test bin/rails db:prepare
RAILS_ENV=test DATABASE_URL=postgresql:///wizwiki_test bin/rails test
```

Provider settings are documented in `config/application.yml.example`. Leave credentials
and live switches unset until the relevant integration and side effects have been
reviewed.

## Release checks

```sh
bin/brakeman --no-pager
bin/bundler-audit
bin/importmap audit
bin/rubocop
RAILS_ENV=test DATABASE_URL=postgresql:///wizwiki_test bin/rails test
```

Before each push, inspect the staged diff, confirm the repository visibility and remote,
and scan tracked content and paths for credentials, private data, and obsolete names.

## Contribution rules

- Use synthetic fixtures and examples.
- Keep humans in the loop for customer communications and policy promotion.
- Add regression coverage for both allowed and blocked side-effect paths.
- Record a rollback point before migrations or external-state changes.
- Never commit `.env*`, Rails keys, production snapshots, logs, storage, or exports.
