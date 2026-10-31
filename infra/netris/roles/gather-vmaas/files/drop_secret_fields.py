#!/usr/bin/env python3
"""Read a fulfillment API list on stdin and write it to stdout without the fields
that can hold secrets: template_parameters and user_data_source (snake and camel
case), removed at any depth (they sit under items[].spec). Exits 1 and writes
nothing if the input is not JSON, so the caller never keeps an unfiltered body."""
import json
import sys

DROP = {"template_parameters", "templateParameters", "user_data_source", "userDataSource"}


def clean(value):
    if isinstance(value, dict):
        return {key: clean(item) for key, item in value.items() if key not in DROP}
    if isinstance(value, list):
        return [clean(item) for item in value]
    return value


def main() -> int:
    try:
        document = json.load(sys.stdin)
    except ValueError:
        return 1
    json.dump(clean(document), sys.stdout, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
