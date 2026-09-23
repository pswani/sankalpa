<!--
Sankalpa functional requirements
Functional requirements only. Do not add implementation, architecture, platform allocation, UI layout, visual design, database schema, API, build, deployment, testing, or operational details here.
-->

# Sankalpa

## Purpose
Sankalpa is a declaration of intent with a commitment to perform the intended action.  The intended action could be done for x number of times per y period for a z duration.
Ex: 
1. Do Vipassana twice everyday for 6 months.
2. Go to the gym for 4 times per week.


Key Information
- Title
- Description of the sankalpa
- Start date
- Duration (optional)
- End date (logically derived: Start date + duration; absent when no duration is specified)
- Action type {Meditation | Pranayama | Physical Activity | Observance}
  - Period {Day | Week | Month | Year}
  - Number of times (per Period)

Number of times is a minimum. Performing the action more often than committed still satisfies the period.

The period begins on the start date and builds up to the duration.  When a duration is specified, it must be a whole number of periods — with a Week period, a six-month commitment is expressed as 26 weeks.
Each period boundary is derived from the original start date plus a whole number of periods. When
the corresponding day does not exist in a month or year, the boundary uses the last valid day.

Example activities by action type
- Meditation: Vipassana, Sahaj
- Pranayama: Sudarshan Kriya, 1:2 Nadishodhan, 142 Pranayama
- Physical Activity: Gym, Walk, Run, Padmasadhana, Suryanamaskara
- Observance: Brahmacharya, Dream journaling

## Logging
The user shall be able to log a past session as performed on a sankalpa while it was In progress,
on or after its start date, and, when it has an end date, on or before that date.
When a period ends, each session not logged as performed counts as missed.

### Session
The user performs the intended actions in sessions.  Ex: Doing the Vipassana meditation for 45 minutes is one session.  Going to the gym on a given day is one session.
- Date time: the date and time the action was performed.

Sessions can be logged for past dates.

### Reliable Logging and Correction
A logging action is one confirmed attempt by the user to record a session. Each logging action
shall record at most one session, including when the system must retry that action. The same
logging action cannot be submitted again while it is still being processed.

The user shall be given a clear status for each logging action: being processed, retained as
pending, accepted, or rejected. If a pending logging action is ultimately rejected, the user shall
be informed and the displayed practice shall be corrected.

When the user starts another logging action for the same sankalpa within one minute after a prior
logging action was accepted or retained as pending, the user shall be asked to confirm that it is
an additional session. Confirming records a distinct session; cancelling has no effect. Time
proximity alone shall not silently merge or reject confirmed sessions, including sessions with the
same performed date and time.

Immediately after logging a session, the user shall be able to undo that session. The user shall
also be able to permanently delete any logged session later. A deleted session shall no longer
appear in session history or contribute to session totals, period outcomes, or missed-session
calculations. Outcomes for both open and closed periods shall be derived again from the sessions
that remain.

Undoing or deleting a pending session shall also cancel its pending logging action. If a deletion
cannot be finalized immediately, it shall be retained as pending, the session shall be excluded
from the displayed practice, and the deletion shall complete automatically when possible. Once the
deletion is accepted, the session shall not appear later as a result of an earlier pending logging
action. If a pending deletion is ultimately rejected, the user shall be informed and the displayed
practice shall be corrected.

## Start and End
The sankalpa will have a definite start date and optional duration (end date implied).

- The start date can be up to one year in the past.
- If the duration is not specified like in Example 2 above, then the sankalpa will be observed and tracked till it is stopped.
- Reaching the end date does not automatically change the lifecycle state.
- No session can be logged after the end date.
- When a sankalpa is Completed or Stopped, only periods that ended before the terminal transition
  are evaluated. The interrupted period and later periods are not evaluated.

### Lifecycle
The sankalpa can be in one of the following states in the one-way order, except for Paused to In progress, Completed, and Stopped.  The intermediate states can be bypassed.  Ex: Not started -> Stopped, or In progress -> Completed.
1. Not started
2. In progress
3. Paused
4. Completed - Successfully
5. Completed - Unsuccessfully
6. Stopped

Constraints:
- Not started → Paused is not a legal transition
- Completed - Successfully, Completed - Unsuccessfully, and Stopped are terminal.

The transitions are performed by the user.  Ex: the user determines if the sankalpa completed successfully or unsuccessfully.  The lifecycle stage transitions shall be audit logged.
Time spent Paused does not automatically extend the end date.
The Paused interval begins when the user pauses the sankalpa and ends at the next Resume, Completed,
or Stopped transition. Period boundaries do not shift during this interval. If the user resumes
partway through a period, tracking continues in the same period. A period containing both In
progress and Paused time is evaluated normally without prorating the Number of times. A period that
was Paused for its entire duration is reported as Paused and is neither satisfied nor missed.
The transition from Not started to In progress can be backdated, but not before the start date or
in the future. All other lifecycle transitions take effect when the user performs them.
A session can be recorded only when the sankalpa was In progress at the time the session occurred.

Application:
1. Single user
