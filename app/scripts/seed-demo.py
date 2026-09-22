#!/usr/bin/env python3
"""Seed the demo practice the screen tour walks through, via the Sankalpa REST API.

This used to be Swift inside the app, writing straight into a local file. With the practice living
in the service there is no local store to seed, and an app that could seed itself would be an app
that can write example data into someone's real history. So the fixture moved out here: it is built
the way any client would build it — declare, begin, log, pause, complete — which also means it
cannot contain a state the service's own rules would refuse.

Point it at a throwaway service. It adds to whatever is already there and removes nothing, because
the API has no delete.

    ./seed-demo.py [--base-url http://localhost:8080]
"""

import argparse
import json
import sys
import urllib.error
import urllib.request
from datetime import date, datetime, timedelta


class Service:
    def __init__(self, base_url):
        self.base_url = base_url.rstrip("/")

    def post(self, path, body=None):
        data = json.dumps(body or {}).encode()
        request = urllib.request.Request(
            f"{self.base_url}/api/v1/sankalpas{path}",
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            raise SystemExit(f"POST {path} failed ({error.code}): {detail}") from error


def wall_clock(day, hour, minute=0):
    """The service reads offset-free local date-times in its configured zone."""
    return f"{day.isoformat()}T{hour:02d}:{minute:02d}:00"


def log(service, sankalpa_id, day, hour, minute=0, *, now):
    """Records a session, unless that moment has not happened yet.

    The fixture places sessions at fixed times of day, which on today's date can be later than the
    clock — seeding just after midnight would otherwise ask the service to accept a session at
    06:15 this morning. The service is right to refuse that, so the fixture does not ask.
    """
    moment = datetime(day.year, day.month, day.day, hour, minute)
    if moment > now:
        return False
    service.post(f"/{sankalpa_id}/sessions", {"occurredAt": wall_clock(day, hour, minute)})
    return True


def declare(service, *, title, description, action_type, start, unit, times, count=None):
    body = {
        "title": title,
        "description": description,
        "actionType": action_type,
        "startDate": start.isoformat(),
        "periodUnit": unit,
        "timesPerPeriod": times,
    }
    if count is not None:
        body["periodCount"] = count
    return service.post("", body)["id"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://localhost:8080")
    arguments = parser.parse_args()

    service = Service(arguments.base_url)
    today = date.today()
    # A minute behind the clock, so a session placed "now" is still in the past by the time the
    # request arrives however long seeding takes.
    now = datetime.now() - timedelta(minutes=1)

    # The requirement's first example: "Do Vipassana twice everyday for 6 months."
    start = today - timedelta(days=40)
    vipassana = declare(
        service,
        title="Vipassana",
        description="Two sittings a day, morning and evening, for six months.",
        action_type="MEDITATION",
        start=start,
        unit="DAY",
        times=2,
        count=180,
    )
    service.post(f"/{vipassana}/begin", {"effectiveAt": wall_clock(start, 6)})
    # A convincing record rather than a perfect one: most days both sittings, some only the
    # morning, a few missed entirely — so closed periods show satisfied and missed.
    for offset in range(41):
        day = start + timedelta(days=offset)
        if day > today or offset % 13 == 6:
            continue
        log(service, vipassana, day, 6, 15, now=now)
        if offset % 7 != 3 and offset % 11 != 5:
            log(service, vipassana, day, 19, 30, now=now)

    # The second example: "Go to the gym for 4 times per week" — no duration, so it runs until
    # it is stopped.
    start = today - timedelta(days=28)
    gym = declare(
        service,
        title="Gym",
        description="Four sessions a week, whichever days they land on.",
        action_type="PHYSICAL_ACTIVITY",
        start=start,
        unit="WEEK",
        times=4,
    )
    service.post(f"/{gym}/begin", {"effectiveAt": wall_clock(start, 7)})
    for offset in range(0, 28, 2):
        log(service, gym, start + timedelta(days=offset), 7, 30, now=now)

    # Paused, which is a state of its own: the current period is neither satisfied nor missed
    # while it lasts, and a fully paused period is reported rather than judged.
    start = today - timedelta(days=21)
    kriya = declare(
        service,
        title="Sudarshan Kriya",
        description="Once every morning.",
        action_type="PRANAYAMA",
        start=start,
        unit="DAY",
        times=1,
        count=90,
    )
    service.post(f"/{kriya}/begin", {"effectiveAt": wall_clock(start, 6)})
    for offset in range(10):
        log(service, kriya, start + timedelta(days=offset), 6, 30, now=now)
    service.post(f"/{kriya}/pause")

    # Finished, so the tour has something under the Finished filter. The user decides which way it
    # went; the tallies do not.
    start = today - timedelta(days=60)
    journal = declare(
        service,
        title="Dream journaling",
        description="Write the dream down before getting out of bed.",
        action_type="OBSERVANCE",
        start=start,
        unit="DAY",
        times=1,
        count=30,
    )
    service.post(f"/{journal}/begin", {"effectiveAt": wall_clock(start, 7)})
    for offset in range(30):
        if offset % 5 != 4:
            log(service, journal, start + timedelta(days=offset), 7, 15, now=now)
    service.post(f"/{journal}/complete", {"outcome": "SUCCESSFUL"})

    # Declared but not begun, and not due to start yet — so Begin is offered but unavailable.
    declare(
        service,
        title="Morning walk",
        description="Thirty minutes before anything else.",
        action_type="PHYSICAL_ACTIVITY",
        start=today + timedelta(days=3),
        unit="DAY",
        times=1,
        count=60,
    )

    print(f"Seeded the demo practice into {service.base_url}", file=sys.stderr)


if __name__ == "__main__":
    main()
