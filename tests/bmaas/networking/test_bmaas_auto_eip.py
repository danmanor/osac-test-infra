from __future__ import annotations

from typing import Any, ClassVar

import pytest

from tests.core.grpc_client import GRPCClient
from tests.core.helpers import (
    wait_for_bmh_available,
    wait_for_bmi_cr,
    wait_for_bmi_deletion,
    wait_for_bmi_grpc_removal,
    wait_for_bmi_running,
    wait_for_external_ip_allocated,
    wait_for_external_ip_cr,
    wait_for_external_ip_deletion,
    wait_for_security_group_cr,
    wait_for_security_group_deletion,
    wait_for_security_group_ready,
    wait_for_subnet_cr,
    wait_for_subnet_deletion,
    wait_for_subnet_ready,
    wait_for_virtual_network_cr,
    wait_for_virtual_network_deletion,
    wait_for_virtual_network_ready,
)
from tests.core.k8s_client import K8sClient
from tests.core.osac_cli import OsacCLI
from tests.core.runner import poll_until


def _require(state: dict[str, Any], *keys: str) -> None:
    missing = [k for k in keys if k not in state]
    if missing:
        pytest.skip(f"Prerequisite state missing: {', '.join(missing)}")


class TestBmaasAutoExternalIp:
    state: ClassVar[dict[str, Any]] = {}

    # ── Setup ───────────────────────────────────────────────────────────

    def test_01_setup_networking(
        self,
        grpc: GRPCClient,
        k8s_hub_client: K8sClient,
        network_class: str,
        external_ip_pool_name: str,
        net_test_run_id: str,
    ) -> None:
        vnet_name = f"auto-eip-{net_test_run_id}"
        vnet_id = grpc.create_virtual_network(name=vnet_name, network_class=network_class, ipv4_cidr="10.101.0.0/16")
        vnet_cr = wait_for_virtual_network_cr(k8s=k8s_hub_client, uuid=vnet_id)
        wait_for_virtual_network_ready(k8s=k8s_hub_client, name=vnet_cr)

        subnet_name = f"auto-eip-sub-{net_test_run_id}"
        subnet_id = grpc.create_subnet(name=subnet_name, virtual_network=vnet_id, ipv4_cidr="10.101.1.0/24")
        subnet_cr = wait_for_subnet_cr(k8s=k8s_hub_client, uuid=subnet_id)
        wait_for_subnet_ready(k8s=k8s_hub_client, name=subnet_cr)

        sg_name = f"auto-eip-sg-{net_test_run_id}"
        sg_id = grpc.create_security_group_with_rules(
            name=sg_name,
            virtual_network=vnet_id,
            ingress=[
                {"protocol": "PROTOCOL_TCP", "port_from": 22, "port_to": 22, "ipv4_cidr": "0.0.0.0/0"},
                {"protocol": "PROTOCOL_ICMP", "ipv4_cidr": "0.0.0.0/0"},
            ],
            egress=[{"protocol": "PROTOCOL_ALL", "ipv4_cidr": "0.0.0.0/0"}],
        )
        sg_cr = wait_for_security_group_cr(k8s=k8s_hub_client, uuid=sg_id)
        wait_for_security_group_ready(k8s=k8s_hub_client, name=sg_cr)

        nat_eip_name = f"auto-eip-nat-eip-{net_test_run_id}"
        nat_eip_id = grpc.create_external_ip(name=nat_eip_name, pool=external_ip_pool_name)
        nat_eip_cr = wait_for_external_ip_cr(k8s=k8s_hub_client, uuid=nat_eip_id)
        wait_for_external_ip_allocated(k8s=k8s_hub_client, name=nat_eip_cr)

        nat_name = f"auto-eip-nat-{net_test_run_id}"
        nat_id = grpc.create_nat_gateway(name=nat_name, virtual_network_name=vnet_name, external_ip_name=nat_eip_name)
        poll_until(
            fn=lambda: (
                grpc.call(service="osac.public.v1.NATGateways/Get", data={"id": nat_id})
                .get("object", {})
                .get("status", {})
                .get("state", "")
            ),
            until=lambda s: s in ("NAT_GATEWAY_STATE_READY", "Ready"),
            retries=30,
            delay=5,
            description=f"NATGateway {nat_name} to become Ready",
        )

        self.__class__.state.update(
            vnet_id=vnet_id,
            vnet_cr=vnet_cr,
            vnet_name=vnet_name,
            subnet_id=subnet_id,
            subnet_cr=subnet_cr,
            sg_id=sg_id,
            sg_cr=sg_cr,
            nat_eip_id=nat_eip_id,
            nat_eip_cr=nat_eip_cr,
            nat_eip_name=nat_eip_name,
            nat_id=nat_id,
            nat_name=nat_name,
        )

    def test_02_create_catalog_item_with_auto_eip(
        self, private_grpc: GRPCClient, bmi_template: str, net_test_run_id: str
    ) -> None:
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
        self.__class__.state.update(auto_eip_catalog_id=item_id, auto_eip_catalog_name=name)

    # ── Provision + Verify ──────────────────────────────────────────────

    def test_03_create_bmi_with_auto_eip(
        self, cli: OsacCLI, grpc: GRPCClient, k8s_hub_client: K8sClient, net_ssh_public_key: str, net_test_run_id: str
    ) -> None:
        _require(self.state, "subnet_id", "sg_id", "auto_eip_catalog_name")

        bmi_name = f"auto-eip-bmi-{net_test_run_id}"
        bmi_id = cli.create_baremetal_instance(
            name=bmi_name,
            catalog_item=self.state["auto_eip_catalog_name"],
            ssh_key=net_ssh_public_key,
            network_attachments=[
                f"subnet={self.state['subnet_id']},interface=eth9,primary,security-groups={self.state['sg_id']}"
            ],
        )
        bmi_cr = wait_for_bmi_cr(k8s=k8s_hub_client, uuid=bmi_id)
        wait_for_bmi_running(grpc=grpc, bmi_id=bmi_id)

        bmi_ip = k8s_hub_client.get_baremetal_instance_tenant_ip(name=bmi_cr)
        assert bmi_ip, f"BMI {bmi_name} has no tenant IP"

        ext_host = k8s_hub_client.get_baremetal_instance_external_host_id(name=bmi_cr)
        bmh_name = ext_host.split("/", 1)[1]

        self.__class__.state.update(
            auto_bmi_id=bmi_id, auto_bmi_cr=bmi_cr, auto_bmi_name=bmi_name, auto_bmi_ip=bmi_ip, auto_bmi_bmh=bmh_name
        )

    def test_04_verify_auto_eip_created(self, grpc: GRPCClient, k8s_hub_client: K8sClient) -> None:
        _require(self.state, "auto_bmi_id")

        def find_auto_attachment() -> dict[str, Any] | None:
            attachments = grpc.call(service="osac.public.v1.ExternalIPAttachments/List")
            for item in attachments.get("items", []):
                bmi_ref = item.get("spec", {}).get("bare_metal_instance", {}).get("id", "")
                if bmi_ref == self.state["auto_bmi_id"]:
                    return item
            return None

        attachment = poll_until(
            fn=find_auto_attachment,
            until=lambda a: a is not None,
            retries=60,
            delay=5,
            description="auto-created ExternalIPAttachment for BMI",
        )

        auto_attach_id = attachment["id"]
        auto_eip_ref = attachment.get("spec", {}).get("external_ip", {}).get("id", "")
        assert auto_eip_ref, "Auto-created attachment has no ExternalIP reference"

        eip_data = grpc.get_external_ip(external_ip_id=auto_eip_ref)
        auto_ext_addr = eip_data.get("object", {}).get("status", {}).get("address", "")
        assert auto_ext_addr, "Auto-created ExternalIP has no allocated address"

        self.__class__.state.update(
            auto_attach_id=auto_attach_id, auto_eip_id=auto_eip_ref, auto_ext_addr=auto_ext_addr
        )
        print(f"Auto EIP: {auto_ext_addr}, attachment: {auto_attach_id}")

    # ── Teardown + Verify Cascade ───────────────────────────────────────

    def test_05_delete_bmi(self, cli: OsacCLI, grpc: GRPCClient, k8s_hub_client: K8sClient, bmh_namespace: str) -> None:
        _require(self.state, "auto_bmi_id")

        cli.delete_baremetal_instance(uuid=self.state["auto_bmi_id"])
        wait_for_bmi_deletion(k8s=k8s_hub_client, name=self.state["auto_bmi_cr"])
        wait_for_bmi_grpc_removal(grpc=grpc, uuid=self.state["auto_bmi_id"])
        wait_for_bmh_available(k8s=k8s_hub_client, name=self.state["auto_bmi_bmh"], bmh_namespace=bmh_namespace)

    def test_06_verify_auto_eip_garbage_collected(self, grpc: GRPCClient) -> None:
        _require(self.state, "auto_attach_id", "auto_eip_id")

        poll_until(
            fn=lambda: self.state["auto_attach_id"] not in grpc.list_external_ip_attachment_ids(),
            until=lambda gone: gone is True,
            retries=30,
            delay=5,
            description="auto-created ExternalIPAttachment garbage collection",
        )

        poll_until(
            fn=lambda: self.state["auto_eip_id"] not in grpc.list_external_ip_ids(),
            until=lambda gone: gone is True,
            retries=30,
            delay=5,
            description="auto-created ExternalIP garbage collection",
        )

    def test_07_delete_catalog_item(self, private_grpc: GRPCClient) -> None:
        if "auto_eip_catalog_id" not in self.state:
            pytest.skip("No catalog item to delete")
        private_grpc.delete_baremetal_instance_catalog_item(item_id=self.state["auto_eip_catalog_id"])

    def test_08_teardown_networking(self, grpc: GRPCClient, k8s_hub_client: K8sClient) -> None:
        if "nat_id" in self.state:
            grpc.delete_nat_gateway(nat_gateway_id=self.state["nat_id"])
            poll_until(
                fn=lambda: (
                    self.state["nat_id"]
                    not in [
                        item["id"] for item in grpc.call(service="osac.public.v1.NATGateways/List").get("items", [])
                    ]
                ),
                until=lambda gone: gone is True,
                retries=60,
                delay=5,
                description=f"NATGateway {self.state['nat_name']} deletion",
            )

        if "nat_eip_id" in self.state:
            grpc.delete_external_ip(external_ip_id=self.state["nat_eip_id"])
            wait_for_external_ip_deletion(k8s=k8s_hub_client, name=self.state["nat_eip_cr"])

        if "sg_id" in self.state:
            grpc.delete_security_group(sg_id=self.state["sg_id"])
            wait_for_security_group_deletion(k8s=k8s_hub_client, name=self.state["sg_cr"])

        if "subnet_id" in self.state:
            grpc.delete_subnet(subnet_id=self.state["subnet_id"])
            wait_for_subnet_deletion(k8s=k8s_hub_client, name=self.state["subnet_cr"])

        if "vnet_id" in self.state:
            grpc.delete_virtual_network(vn_id=self.state["vnet_id"])
            wait_for_virtual_network_deletion(k8s=k8s_hub_client, name=self.state["vnet_cr"])
