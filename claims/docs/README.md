# Claims

Module ID: `people/claims`. Claim catalog, effective-dated claim policies, and
employee claim requests.

## Ownership

This module owns five fresh Bilimbi-only tables: claim categories, claim
types, claim policies, claim requests, and the append-only request status
history. Call `Bilimbi.People.Claims` with a validated
`Bilimbi.Base.Tenancy.Scope` and an explicit platform company ID; callers do
not query its schemas. Core Company validates the company, Core User links a
login actor to an employee, the People workforce seam decides who is a working
employee, and Core Employee's affiliation lock serializes each employee's
claim writes. A login actor is never treated as an employee by itself.

## Currencies and policies

Claim currencies are the company-scoped Base Setting
`people.claims.currencies`. Its default is empty: a new company accepts no
claim until an operator chooses its currencies. Codes are three uppercase
letters (ISO 4217 shape); the module ships no currency list or default.

A claim type belongs to one category and declares a receipt rule: `always`,
`never`, or `above_threshold`. A policy gives one claim type an effective
period, a currency from the company's list, and optional per-claim, calendar
month, and calendar year limits. A threshold receipt rule needs the policy's
receipt threshold. Periods of one claim type never overlap; an open-ended
policy can be ended, but not before a live claim incurred under it. Submission
holds the effective policy row while it checks and records the claim, so ending
a policy waits for an in-flight claim and then sees it.

## Requests

`submit_request/5` records one claim for a working employee. It is checked
against the policy in effect on the expense date, which must not be in the
future in the company time zone. The claim currency must equal the policy
currency and still be allowed. Monthly and yearly limits count every live
claim of the same employee, type, and currency in that calendar period.
Refusals are explicit atoms, listed in the function documentation.

Duplicates:

- a receipt reference already on any live claim of the same employee in the
  company, whatever its type, is refused, comparing case-insensitively and
  ignoring extra spaces; a partial unique index enforces the same rule;
- a live claim with the same type, date, amount, and currency is refused as a
  possible duplicate unless the submitter confirms it, which is recorded.

`withdraw_request/5` withdraws the employee's own submitted claim. Withdrawn
claims keep their history, stop counting toward limits, and release their
receipt reference. Approval, reimbursement, assignment, and exports belong to
the later approval slice; this module does not claim them yet.

## Pages and menu

- **People > My work > My claims** opens `/people/claims` under
  `people.claims.submit`. The signed-in actor's company is the company axis;
  an actor without a linked working employee sees an unavailable state. The
  page lists open claim types with their currency, limits, and receipt rule,
  submits claims, and withdraws submitted ones.
- **People > Settings > Claim policies** opens `/people/claims/setup` under
  `people.claims.manage`. Operators choose one company they may manage and edit
  its claim currencies, categories, claim types, and policies. Each section has
  an empty state.

## Schema

Migration `20260930150101` is `:bilimbi_only` and must remain globally unique.
It creates no rows and copies no source table names or migration sequence.
Run `mix bilimbi.migrate` from a mounted Bilimbi root. The owned
`SchemaContract` describes the fresh tables, but the descriptor does not
register it with compatibility verification: that verifier also runs before
pending Bilimbi-only migrations, when these tables correctly do not exist.
