"""Test for infra/netris/roles/gather-vmaas/files/drop_secret_fields.py."""
import json
import pathlib
import subprocess
import sys

FILTER = pathlib.Path(__file__).resolve().parents[2] / "infra/netris/roles/gather-vmaas/files/drop_secret_fields.py"


def run(text: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-I", str(FILTER)], input=text, capture_output=True, text=True, check=False)


def main() -> None:
    # Shaped like the REST gateway output of ComputeInstance (proto field names).
    body = {"items": [{
        "id": "ci-1",
        "spec": {
            "template": "123",
            "template_parameters": {"pull_secret": {"@type": "type.googleapis.com/google.protobuf.Value", "value": "SECRET1"}},
            "user_data_source": {"inline": "#cloud-config\npassword: SECRET2"},
            "ssh_key": {"name": "key"},
        },
        "status": {"state": "RUNNING"},
    }, {"id": "ci-2", "spec": {"templateParameters": {"a": "SECRET3"}, "userDataSource": {"inline": "SECRET4"}}}]}
    done = run(json.dumps(body))
    assert done.returncode == 0, done.stderr
    for secret in ("SECRET1", "SECRET2", "SECRET3", "SECRET4", "template_parameters", "user_data_source", "templateParameters", "userDataSource"):
        assert secret not in done.stdout, f"{secret} survived the filter"
    kept = json.loads(done.stdout)["items"]
    assert kept[0]["spec"]["template"] == "123" and kept[0]["spec"]["ssh_key"] == {"name": "key"}, "other spec fields were lost"
    assert kept[0]["status"] == {"state": "RUNNING"} and kept[1]["id"] == "ci-2", "other fields were lost"

    bad = run("<html>502</html>")
    assert bad.returncode == 1 and bad.stdout == "", "a non-JSON body must produce no output"
    print("drop_secret_fields_test.py: ok")


if __name__ == "__main__":
    main()
