# Related timeline — a root record's feed, widened to its related records

**Status: PROPOSAL. Not designed in full, not built, no `DESIGN.md` section yet.**
Sketched 2026-09-10 against `../ngen-ipc` at commit `20bb68b2a`, where the whole
audit install is still uncommitted on `main`. Milestone 0 below is DONE in that
app; everything from milestone 1 on is unwritten.

This file exists so the reasoning is recoverable rather than re-derived. When it
reaches the stage §23 reached — designed in full, alternatives rejected with
their reasons — it becomes `DESIGN.md` §26 and this file goes away, and the
terse entries move into `CLAUDE.md` per the rule at the bottom of that document.

## The question

"Show me everything that happened to this NGEN Job" — one feed, one root record,
including the activity of the records that hang off it: its loan, its
certificates, its files, its equipment, its discussion messages, its alerts.

`AuditLog::Timeline` answers it for the root row alone. `AuditLog::DimensionTimeline`
answers it for a facet, with no root row. Neither answers it for a root row AND
its related rows, and that is the whole of the gap.

## State as of 2026-09-10

Gem: nothing. `Timeline`, `DimensionTimeline` and `RecordTimeline` are as
shipped in 0.6.3.

`../ngen-ipc` has the recording half already, which is the half that is not
retroactive and therefore the half worth having early:

- engine mounted at `/audit`, `AuditLog::ControllerContext` included after the
  last `before_action`, `AuditLog::JobContext` on `ApplicationJob`
- two registry entries — `job.updated` (`dimensions: %i[job_id]`) and
  `discussion.message` (`dimensions: %i[discussable_type discussable_id]`)
- `20260910181320_audit_job_dimensions` — `job_id` as a facet on ELEVEN tables:
  certificate_of_completions, contractor_ratings, corrective_action_requests,
  external_reviews, job_campaigns, job_contractors, job_equipments, job_files,
  loan_applications, loans, qa_files
- `20260910165454_audit_messages_by_discussable` — `messages` on the polymorphic
  pair, because `messages` has no `job_id` column to read

**Verified rather than assumed:** twelve tables in that database carry a
`job_id` column. The twelfth is `mi_irb_agreements`, which is in
`unaudited_tables` as a deprecated Michigan table. The row-derived half of the
facet is complete; there is nothing missing from that list.

### Milestone 0 — done, and it needed no gem code

`config.dimension_filters` was unset, which is why `/audit/dimensions` hid its
nav link (the `record_url`-defaults-to-nil discipline). Declaring it turned on a
working, incomplete job feed at `/audit/dimensions?d[job_id]=17487`:

```ruby
config.dimension_filters = {
  job_id:           { label: "Job", options: -> { Job.order(created_at: :desc).limit(200).pluck(:ref_id, :id) } },
  discussable_type: { label: "Discussion parent type" },
  discussable_id:   { label: "Discussion parent" }
}
```

Every unit of work that wrote any of the eleven tables, plus the `job.updated`
events, hydrated whole, with the disclosed 30-day default and the date filter.
Worth doing first on its own merits: it validates the facet data against real
traffic before any gem code exists, and it costs one inert config entry.

## The three gaps a pure facet feed cannot close

Each is named in the migrations' own comments, and each is why this needs a
query object rather than more configuration.

| Gap | Why | What closes it |
|---|---|---|
| The job's own change-only edits | there is no `jobs.job_id`, so `dimensions @> '{"job_id": …}'` can never match a `jobs` change row. The narrative arrives (via `job.updated`'s facet); an edit nobody registered does not. | a **record predicate OR'd with the containment** — what neither existing class does |
| Polymorphic children | `messages` files under `discussable_*`, `alerts` under `subject_*`, `documents` under `documentable_*`. `@>` is ONE containment and the dimension screen ANDs its keys, so no single query reaches them and `job_id` together. | **several facet sets, OR'd** |
| Two-hop children edited alone | a facet is a scalar off the changed row, so `document_reviews`, `loan_disbursements`, `llr_entries`, `certificate_of_completion_documents` and `ct_interest_rate_buydowns` cannot reach a job. They arrive anyway when written in the same request as a row that did match, because a unit hydrates whole. | layer 2 — register the action with `dimensions: %i[job_id]`. Nothing else, short of denormalising a column. |

**The shape follows from this: it is a DISJUNCTION.** §23's "Limits" rejected
cross-table *intersection* (match each facet, intersect the `request_id`s) as
more expensive, semantically distinct and unbuilt. Union is the cheap direction —
the existing query is already `UNION ALL … GROUP BY "key"`, and `max(occurred_at)`
over a row that arrived twice is idempotent, so extra legs de-duplicate for free
and no page-boundary rule appears.

## Where the code goes

| Piece | Home | Why |
|---|---|---|
| the union query, keyed on the unit of work | **gem** | "Do not copy the union query" — it has already lost the events leg once and the `COALESCE` once. A host copy also re-derives `ActivityKey`'s three requirements and `Pagination::FULL_PRECISION`. |
| anchor derivation, value objects | **gem** | `DimensionTimeline#anchor_for` exists because anchoring on nothing renders "nothing changed" on a screen whose job is saying what did. A third hand-rolled copy is the `ActorLabel.display` divergence again. |
| WHICH facets name a Job | **host** | library knowledge is the query shape; the relationship list is host knowledge. Same boundary as `dimension_filters` and `record_url`. |
| the feed's markup, authorization, audience | **host** | §21.3 — generated views are the host's outright. |

## Milestone 1, gem — `AuditLog::RelatedTimeline`

A third `Timeline` subclass, ~70 lines, sharing the union, the unit-of-work key,
the batched hydration, the bounding and every value object.

```ruby
AuditLog::RelatedTimeline.for(job, facets: [
  { job_id: job.id },
  { discussable_type: "Job", discussable_id: job.id },   # messages
  { subject_type: "Job", subject_id: job.id },           # alerts
  { documentable_type: "Job", documentable_id: job.id }   # documents
])
```

`facets:` is an ARRAY of dimension hashes: each hash is AND'ed within one row
(`@>`), the array is OR'd across rows. Deliberately not spelled `dimensions:` —
that keyword takes one hash on `DimensionTimeline`, and a same-named option with
a different shape is a trap of exactly the `correlated_databases` kind.

Four load-bearing details:

1. **One leg per predicate, not one `WHERE` with `OR`s.** `changes_predicate` /
   `events_predicate` become plural, and `activity_keys_sql` emits a leg per
   entry; `GROUP BY "key"` already collapses a row that matched two legs.
   `DimensionTimeline` becomes the single-element case. The alternative — those
   methods returning `"(record) OR (containment) OR …"` — is a smaller diff and
   asks the planner to prove a disjunction of a btree equality and a GIN
   containment selective on each of 84 partitions; per-leg predicates keep each
   one on its own index. **Settle it with `EXPLAIN` at ngen-ipc volume**, not by
   argument. Note the bookkeeping: this renames three private methods that
   `CLAUDE.md` and DESIGN §23 both describe BY NAME.
2. **`anchor_for` must be overridden, preferring the ROOT.** Inherited unchanged
   it anchors every activity on the job, so a loan edited alone renders with
   `mine` empty — "nothing changed" on the screen whose job is saying what did.
   Order: the root if the unit wrote it or subjected an event to it → the event's
   subject → the first change row that matched a facet → the first change row.
   Whatever is not the anchor stays in `also_touched`, which already carries
   `field_changes` per touched record, so a child's before-and-after is on the
   card without a query.
3. **Unbounded by default**, unlike `DimensionTimeline`. This is anchored on one
   record, which is `Timeline`'s precedent for unbounded, and `job_id = 17487` is
   a handful of rows rather than a third of the table. But plan size now grows as
   *legs × partitions*, so keep the facet list to a handful, keep the `?days=`
   escape visible, and measure before this drives a screen in the auditor UI.
4. **An empty `facets:` degrades to exactly `Timeline`, never to `1 = 0`.**
   `DimensionTimeline`'s `1 = 0` is right because a cleared filter must not
   become a scan of the whole log; here the record predicate is still a complete
   and correct answer. A spec asserting `RelatedTimeline` with no facets returns
   what `Timeline` returns is cheap and pins it.

Facet handling shared with `DimensionTimeline` — normalisation through
`Record.normalize_dimensions`, the containment SQL, `matched?`, the description —
wants extracting into one small collaborator. Otherwise this ships a second
hand-rolled containment and a second `matched?`, which is the duplication this
library keeps paying for.

**What it still will not reach, to be STATED rather than discovered:** rows
written before the facet was declared (`dimensions IS NULL`, never matchable by
`@>`); departures (a loan moved off the job shows up to but not including the row
that took it away); a two-hop child edited alone with no registered action; and
facet keys are a FLAT NAMESPACE across every table, so declaring
`subject_type`/`subject_id` on `alerts` means any other table declaring that
pair joins the same feed.

## Milestone 1, host — `../ngen-ipc`

1. **Two more facet migrations**, same shape as the messages one:
   `alerts` on `%i[subject_type subject_id]`, `documents` on
   `%i[documentable_type documentable_id]`. Detach-then-attach, `SET LOCAL
   lock_timeout` off `config.maintenance_lock_timeout`, model names taken from
   `pg_trigger.tgargs` rather than from the table name.
2. **Generate the feed**: `rails generate audit_log:views:activity Job Loan
   CertificateOfCompletion`. ERB renders fine in a HAML app. Expect the show-page
   wiring to DECLINE — job shows live at `organization_app/contractors/jobs`,
   `contractor_app/jobs`, `lender_app/jobs`, `qa_app/jobs` and
   `sponsor_app/jobs`, so there is no bare `def show` to anchor on. It prints the
   two lines; wire them per audience.
3. **Edit the generated `RecordActivity` to use `RelatedTimeline` for a Job** and
   leave `Timeline` for everything else. The concern is host-owned, which is
   exactly why this does not need a generator flag yet.
4. **`audit_activity_visible?` is generated as `false` and denies everyone.**
   This is the real decision in milestone 1, not a formality: the feed exposes
   previous values of every audited column across thirteen tables, plus whatever
   else shared the request. In a five-audience app that method almost certainly
   cannot be one predicate — staff and super-user yes, contractor and lender
   scoped or not at all.
5. **Set `config.record_url`** (still commented out) — a related feed's
   `also_touched` list is where it earns its keep — and add `to_audit_label` to
   `Loan`, `CertificateOfCompletion`, `JobFile`, `Message` and
   `CorrectiveActionRequest` so the cards read as names beside their recorded ids.
6. **Run `rake audit_log:reconcile`** against real traffic and register the top
   unnarrated units with `dimensions: %i[job_id]`. That is also the cheapest
   close on the two-hop gap, and it is what turns a change-only feed into a
   narrative one.
7. Minor, while in there: `JobForm#save` emits `AuditLog.notify` outside a
   transaction. Correlation still holds (same request, same `request_id`), but
   `AuditLog.audited("job.updated", on: @job, …)` would give R3 in both
   directions.

## Later milestones, sketched only

- **The auditor UI's record screen gains an "include related activity" toggle.**
  Needs the facet list in config, since the engine cannot know it:
  `config.related_facets = ->(type, id) { … }` returning an array of hashes,
  defaulting to nil, and the toggle does not render when it is nil — the
  `dimension_filters`/`record_url` discipline. Measure the leg count first.
- **CSV export for the feed.** The dimension screen ships the changes leg alone;
  here it is `Change.for_record(...).or(Change.where_dimensions(...))` chained
  per facet. Same asymmetry note as the record timeline's export: a unit of work
  is a grouping this library derived, so the artifact ships recorded rows.
- **A `--related` flag on `audit_log:views:activity`**, only if the host edit in
  step 3 proves general. It is not general on one app.

## Specs owed

New `related_timeline_spec`, asserting the same property from the angles that
matter — that nothing goes missing without saying so:

- the root's own change-only edit appears (the thing `DimensionTimeline` cannot do)
- a child edited alone, with no registered action, appears
- a DELETED child's delete row appears (the facet is read from `OLD`)
- a unit matching two legs appears ONCE
- empty `facets:` returns exactly what `Timeline` returns
- `history_before?` moved with the predicates, so `older_than_window?` answers
  the same question the page above it asked
- the anchor prefers the root, and a child-only unit still renders field changes

`spec/dummy` needs one child facet: `dimensions: %i[order_id]` on `line_items`
ONLY. Leaving `shipments` unfaceted keeps the "a table declaring none pays
nothing" claim tested, and lets one example assert the reach while another
asserts the honest gap. A second shape needs no migration at all: `Customer` as
the root already has `orders.customer_id`.

## Docs owed

DESIGN §26 with the reasoning and the rejected alternatives below; a README
section in the LATER half (it is a topic reached with a reason, not on the way
in); an `llms.txt` routing row — `readme_spec` checks every anchor and every
`§n`; terse `CLAUDE.md` entries; CHANGELOG.

## Evaluated and rejected

- **`ALTER TABLE jobs ADD COLUMN job_id bigint GENERATED ALWAYS AS (id) STORED`.**
  This works — a generated column is present in `NEW`, so the trigger records it
  and `/audit/dimensions?d[job_id]=X` becomes complete for the job's own rows
  with no gem code at all. Rejected as a permanent answer: it puts a
  self-referential `jobs.job_id` in front of every developer who reads that
  table, and it does nothing for the polymorphic children, for the OR, or for any
  other root record. Available as a stopgap if milestone 0 has to be complete
  before milestone 1 lands.
- **`dimensions: %i[id]` on `jobs`.** Records `{"id": "17487"}`, which matches a
  loan, a message and a file with that id. This is the payload-key rule one level
  down: every id names its type.
- **Live enumeration** — `job.loans.ids`, `job.certificate_of_completions.ids`,
  and so on, OR'd into a record predicate. Needs no migration and works
  retroactively, and loses every `dependent: :destroy` child the moment it is
  destroyed, taking with it the DELETE row that snapshotted it. The audit_job_dimensions
  migration already makes this argument at length.
- **Intersecting `request_id`s across facets.** §23 rejected it, and it is the
  wrong operator here regardless.
- **A host-side copy of the union query.** The two documented ways it goes wrong.

## Open decisions

- The name. `RelatedTimeline` is the user's own term for it; `AggregateTimeline`
  matches DESIGN's prose ("the aggregate root") and is the alternative.
- Multi-leg versus one OR'd `WHERE`. Recommendation is multi-leg; the decision is
  an `EXPLAIN` at real volume, not a preference.
- Whether `config.related_facets` arrives with milestone 1 or waits for the
  auditor-UI toggle. Waiting keeps milestone 1 to a query object and a host edit.
