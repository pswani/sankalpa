# Functional requirements guidelines
Use these guidelines when writing or reviewing the functional requirements.

## Scope
Functional requirements describe what the product must do, not how it is built.
Leave out implementation, architecture, platform allocation, UI layout, visual design, database schema, API, build, deployment, testing, and operational detail.

- Instead of: "Sessions are stored with a timestamp so the period rollup can be
  computed on read."
- Write: "Each session records the date and time the action was performed."

### Intention
- Avoid getting into rabbit holes
- Clarify and detail out to the extent it adds value.  Don't stretch thin on things or invent new concepts just to clarify a low value edge case.


## Human-readable language
The content must make sense to human readers. It should be pleasant to read, and its ideas should arrive in an order that carries the reader forward — purpose first, then the shape of the thing, then its rules and edges.

- Use plain, direct, and neutral language.
- Avoid legalistic, defensive, or unnecessarily technical wording.
- Write for readers who understand the product domain but not its implementation.
- Prefer short sentences and concrete terms.

## Simplicity
Write plainly. Do not hedge, do not write defensively, and do not add a sentence that rules on how to read an earlier one — fix the earlier sentence instead. You do not need legal-sounding language to be precise.

- Instead of: "The start date can be in the past 1 year. For the avoidance of
  doubt, 'past 1 year' here means the 365 days preceding the current date."
- Write: "The start date can be up to one year in the past."

## Clarity
Each requirement should say who does what, under what conditions, in language a reader can check: given a system, they can decide whether it satisfies the requirement. Keep one requirement to a statement — compound sentences hide requirements from reviewers.

- Instead of: "Absence of session log will be assumed to be missed action once
  the period has ended."
- Write: "When a period ends, each session not logged as performed counts as
  missed."


## Consistency
Define each term once and then use it exactly — in the prose, in the examples, and in state and field names. One concept gets one name; do not alternate between session, entry, and log for the same thing.

- Use the same term for the same concept throughout the document and its examples.
- Use capitalization, status names, units, and date terminology consistently.
- Maintain a single source of truth for each rule.


- Instead of: "In Progress" in one place and "In progress" in another.
- Write: the state name exactly as the lifecycle defines it, everywhere.


## Examples

- Use examples to clarify requirements, not to introduce unstated behavior.
- Ensure every example conforms to the documented rules.
- Include boundary or exceptional examples when they clarify important behavior.

## Unwanted and irrelevant
Ensure that there is no Unwanted and irrelevant content hanging in the document.

<!-- Ignore the rest of this document
## Requirement structure

- State observable product behavior, rules, or outcomes—not implementation details.
- Each requirement should express one rule.
- Identify the actor, relevant precondition or trigger, expected behavior, and outcome.
- Use `must` for required behavior and `may` for permitted or optional behavior.
- Avoid ambiguous words such as normally, recently, appropriate, quickly, or whenever possible.

## Precision and completeness

- Define domain-specific terms before using them.
- Quantify dates, durations, limits, frequencies, and boundary conditions.
- Specify defaults, validation rules, exceptional cases, and consequences of invalid input.
- Define allowed state transitions explicitly.
- State how derived values are calculated.
- Ensure that requirements do not contradict or duplicate one another.


## Verifiability

- Write every requirement so that its fulfillment can be objectively demonstrated.
- Replace subjective statements with observable outcomes.
- During review, ask whether two independent readers would interpret the requirement in the same way.
-->