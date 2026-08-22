from __future__ import annotations

import subprocess
import tempfile
import uuid
from pathlib import Path

import pytest

from tests.core.grpc_client import GRPCClient
from tests.core.runner import env


@pytest.fixture(scope="session")
def network_class() -> str:
    return env("OSAC_NETWORK_CLASS", "netris")


@pytest.fixture(scope="session")
def external_ip_pool_id(private_grpc: GRPCClient) -> str:
    pool_name = env("OSAC_EXTERNAL_IP_POOL", "tenant-external-pool")
    pools = private_grpc.call(service="osac.private.v1.ExternalIPPools/List")
    for item in pools.get("items", []):
        if item.get("metadata", {}).get("name") == pool_name:
            return item["id"]
    raise RuntimeError(f"ExternalIPPool '{pool_name}' not found")


@pytest.fixture(scope="session")
def mgmt_cluster_ip() -> str:
    return env("OSAC_MGMT_CLUSTER_IP", "192.168.40.2")


@pytest.fixture(scope="session")
def net_test_run_id() -> str:
    return uuid.uuid4().hex[:8]


@pytest.fixture(scope="session")
def bmi_template() -> str:
    return env("OSAC_BMI_TEMPLATE", "bm-host-provisioning")


@pytest.fixture(scope="session")
def bmh_namespace() -> str:
    return env("OSAC_BMH_NAMESPACE", "host-inventory")


@pytest.fixture(scope="session")
def catalog_item_name() -> str:
    return env("OSAC_BMI_CATALOG_ITEM", "ci-bm-default")


@pytest.fixture(scope="session")
def auto_eip_catalog_item(private_grpc: GRPCClient, bmi_template: str, net_test_run_id: str):
    name = f"auto-eip-ci-{net_test_run_id}"
    item_id = private_grpc.create_baremetal_instance_catalog_item(
        name=name,
        title=f"Auto EIP Test ({net_test_run_id})",
        description="Catalog item with auto_external_ip_attachment for E2E test",
        template=bmi_template,
        field_definitions=[
            {"path": "ssh_public_key", "display_name": "SSH Public Key", "editable": True},
            {"path": "network_attachments", "display_name": "Network Attachments", "editable": True},
            {"path": "auto_external_ip_attachment", "display_name": "Auto External IP", "editable": True},
        ],
    )
    yield {"id": item_id, "name": name}
    try:
        private_grpc.delete_baremetal_instance_catalog_item(item_id=item_id)
    except Exception as e:
        print(f"WARNING: Failed to delete auto-eip catalog item {item_id}: {e}")


@pytest.fixture(scope="session")
def net_ssh_public_key():
    with tempfile.TemporaryDirectory() as tmpdir:
        key_path = Path(tmpdir) / "bmaas-net-test-key"
        subprocess.run(
            ["ssh-keygen", "-t", "ed25519", "-f", str(key_path), "-N", "", "-C", "bmaas-net-e2e"],
            capture_output=True,
            check=True,
        )
        yield key_path.with_suffix(".pub").read_text().strip()
