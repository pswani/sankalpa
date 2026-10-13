#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 -m venv "$root/.venv"
"$root/.venv/bin/python" -m pip install -r "$root/scripts/aws-requirements.txt"
printf 'Deployment tools installed in %s/.venv\n' "$root"
