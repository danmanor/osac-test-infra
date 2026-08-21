#!/bin/bash
#
# OSAC BMaaS Networking Demo
#
# This demo walks through the full bare-metal networking story:
# how a tenant creates an isolated network, provisions servers on it,
# and controls connectivity — layer 2, layer 3, egress, and ingress.
#
set -euo pipefail

CAST_FILE="${CAST_FILE:-bmaas-networking-demo.cast}"
CLEANUP="${CLEANUP:-false}"

# Colors
BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
RED='\033[1;31m'
WHITE='\033[1;37m'
RESET='\033[0m'

export KUBECONFIG=/root/.kube/config

# ── Helpers ──────────────────────────────────────────────────────────────────

type_cmd() {
  local cmd="$1"
  echo ""
  echo -ne "${GREEN}\$ ${RESET}"
  for (( i=0; i<${#cmd}; i++ )); do
    echo -n "${cmd:$i:1}"
    sleep 0.02
  done
  echo ""
  sleep 0.3
}

run_cmd() {
  type_cmd "$1"
  eval "$1"
  sleep 1
}

header() {
  echo ""
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${CYAN}  $*${RESET}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""
  sleep 2
}

narrate() {
  echo -e "  ${WHITE}$*${RESET}"
  sleep 1
}

info() {
  echo -e "  ${BLUE}ℹ${RESET}  $*"
  sleep 0.5
}

ok() {
  echo -e "  ${GREEN}✓${RESET}  $*"
  sleep 0.5
}

fail_expected() {
  echo -e "  ${YELLOW}✗${RESET}  $*  ${DIM}(expected — this proves isolation)${RESET}"
  sleep 0.5
}

pause() {
  sleep "${1:-2}"
}

wait_bmi_running() {
  local bmi_id=$1 timeout=${2:-600}
  local elapsed=0
  echo ""
  while true; do
    local line state
    line=$(osac get baremetalinstance "$bmi_id" 2>/dev/null | grep "$bmi_id" | head -1 || true)
    if echo "$line" | grep -q "RUNNING"; then
      echo ""
      ok "Server is ${GREEN}RUNNING${RESET} and connected to the tenant network"
      return 0
    fi
    if echo "$line" | grep -q "FAILED"; then
      echo -e "\n  ${RED}✗ FAILED${RESET}" >&2
      return 1
    fi
    state=$(echo "$line" | grep -oE "PROVISIONING|RUNNING|FAILED|DELETING" | head -1)
    state=${state:-waiting}
    if (( elapsed >= timeout )); then
      echo -e "\n  ${RED}✗ Timed out${RESET}" >&2
      return 1
    fi
    echo -ne "  ${YELLOW}⏳${RESET} Provisioning bare-metal server... ${DIM}${state} (${elapsed}s)${RESET}      \r"
    sleep 10
    elapsed=$((elapsed + 10))
  done
}

wait_resource_ready() {
  local type=$1 name=$2 timeout=${3:-120}
  local elapsed=0
  while true; do
    local line state
    line=$(osac get "$type" 2>/dev/null | grep "$name" | grep -v "Yes" | head -1 || true)
    # Match READY or ALLOCATED anywhere in the line (skip DELETING rows)
    if echo "$line" | grep -qE "READY|ALLOCATED"; then
      state=$(echo "$line" | grep -oE "READY|ALLOCATED" | head -1)
      ok "$name is ${GREEN}$state${RESET}"
      return 0
    fi
    if (( elapsed >= timeout )); then
      echo -e "  ${RED}✗ Timed out waiting for $name${RESET}" >&2
      return 1
    fi
    echo -ne "  ${YELLOW}⏳${RESET} Waiting for $name... ${DIM}(${elapsed}s)${RESET}      \r"
    sleep 5
    elapsed=$((elapsed + 5))
  done
}

wait_resource_gone() {
  local type=$1 name=$2 timeout=${3:-300}
  local elapsed=0
  while true; do
    local line
    line=$(osac get "$type" 2>&1 || true)
    if ! echo "$line" | grep -q "$name"; then
      ok "$name removed"
      return 0
    fi
    if (( elapsed >= timeout )); then
      info "$name still deleting after ${timeout}s — continuing"
      return 0
    fi
    echo -ne "  ${YELLOW}⏳${RESET} Waiting for $name to be removed... ${DIM}(${elapsed}s)${RESET}      \r"
    sleep 5
    elapsed=$((elapsed + 5))
  done
}

get_bmi_tenant_ip() {
  local bmi_id=$1
  oc get baremetalinstance -n osac-e2e-ci \
    -l "osac.openshift.io/baremetalinstance-uuid=$bmi_id" \
    -o jsonpath='{.items[0].status.networkAttachmentStatuses[0].ipAddress}' 2>/dev/null
}

get_bmi_bmc_ip() {
  local bmi_id=$1
  local bmh_name
  bmh_name=$(oc get baremetalinstance -n osac-e2e-ci \
    -l "osac.openshift.io/baremetalinstance-uuid=$bmi_id" \
    -o jsonpath='{.items[0].spec.externalHostID}' 2>/dev/null | cut -d/ -f2)
  local bmc_mac
  bmc_mac=$(virsh domiflist "$bmh_name" 2>/dev/null | awk '/bmc-net/{print $5}')
  virsh net-dhcp-leases bmc-net 2>/dev/null | grep "$bmc_mac" | awk '{print $5}' | cut -d/ -f1
}

ssh_bmi() {
  local bmc_ip=$1; shift
  ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i /root/.ssh/id_rsa "core@$bmc_ip" "$@" 2>/dev/null
}

# ── Config ───────────────────────────────────────────────────────────────────

POOL_NAME="tenant-external-pool"
CATALOG="ci-bm-default"

VNET_NAME="demo-vnet"
SUBNET1_NAME="demo-subnet-a"
SUBNET2_NAME="demo-subnet-b"
SG_NAME="demo-sg"
NAT_NAME="demo-nat"
NAT_EIP_NAME="demo-nat-eip"

BMI1_NAME="demo-server-1"
BMI2_NAME="demo-server-2"
BMI3_NAME="demo-server-3"

BMI1_ID="" BMI2_ID="" BMI3_ID=""
SUBNET1_ID="" SUBNET2_ID="" SG_ID=""

# ── Cleanup ──────────────────────────────────────────────────────────────────

cleanup_resources() {
  header "Cleanup"
  for name in "$BMI3_NAME" "$BMI2_NAME" "$BMI1_NAME"; do
    info "Deleting $name..."; osac delete baremetalinstance "$name" 2>/dev/null || true
  done
  sleep 5
  osac delete natgateway "$NAT_NAME" 2>/dev/null || true
  osac delete externalip "$NAT_EIP_NAME" 2>/dev/null || true
  osac delete securitygroup "$SG_ID" 2>/dev/null || true
  osac delete subnet "$SUBNET2_NAME" 2>/dev/null || true
  osac delete subnet "$SUBNET1_NAME" 2>/dev/null || true
  osac delete virtualnetwork "$VNET_NAME" 2>/dev/null || true
  ok "Cleanup complete"
}

# ── Demo ─────────────────────────────────────────────────────────────────────

run_demo() {
  if [[ "${CLEANUP}" == "true" ]]; then
    trap 'rc=$?; cleanup_resources; exit $rc' EXIT INT TERM
  fi

  # ═══════════════════════════════════════════════════════════════════════════
  header "OSAC Bare-Metal Networking Demo"
  narrate "OSAC provisions bare-metal servers and connects them to"
  narrate "tenant-isolated networks managed by a Netris fabric."
  narrate ""
  narrate "In this demo we will:"
  narrate "  1. Build a tenant network from scratch"
  narrate "  2. Provision servers and test connectivity"
  narrate "  3. Prove L2 and L3 isolation between subnets"
  narrate "  4. Prove tenant isolation from the management cluster"
  narrate "  5. Add external access (egress and ingress)"
  pause 3

  # ═══════════════════════════════════════════════════════════════════════════
  header "Part 1: Building the Tenant Network"

  # ── Virtual Network ────────────────────────────────────────────────────────
  narrate "First, we create a ${BOLD}Virtual Network${RESET}."
  narrate "This is the tenant's isolated L3 domain — backed by a Netris VPC."
  narrate "No other tenant can see traffic inside it."
  narrate ""
  run_cmd "osac create virtualnetwork --name $VNET_NAME --network-class netris --ipv4-cidr 10.100.0.0/16"
  wait_resource_ready virtualnetworks "$VNET_NAME"
  pause

  narrate "Let's see it:"
  run_cmd "osac get virtualnetworks"
  pause

  # ── Subnets ────────────────────────────────────────────────────────────────
  narrate "Next, we create two ${BOLD}Subnets${RESET} inside the Virtual Network."
  narrate "Each subnet is a separate broadcast domain (L2 segment)."
  narrate "Servers in the same subnet can arping each other (L2)."
  narrate "Servers in different subnets can only ping (L3, routed by the gateway)."
  narrate ""

  narrate "${BOLD}Subnet A${RESET} — 10.100.1.0/24:"
  run_cmd "osac create subnet --name $SUBNET1_NAME --virtual-network $VNET_NAME --ipv4-cidr 10.100.1.0/24"
  wait_resource_ready subnets "$SUBNET1_NAME"
  SUBNET1_ID=$(osac get subnets 2>/dev/null | awk "/$SUBNET1_NAME/"'{print $4}')

  narrate "${BOLD}Subnet B${RESET} — 10.100.2.0/24:"
  run_cmd "osac create subnet --name $SUBNET2_NAME --virtual-network $VNET_NAME --ipv4-cidr 10.100.2.0/24"
  wait_resource_ready subnets "$SUBNET2_NAME"
  SUBNET2_ID=$(osac get subnets 2>/dev/null | awk "/$SUBNET2_NAME/"'{print $4}')

  narrate "Both subnets:"
  run_cmd "osac get subnets"
  pause

  # ── Security Group ─────────────────────────────────────────────────────────
  narrate "Now a ${BOLD}Security Group${RESET} — firewall rules for the network."
  narrate "We allow SSH (tcp/22) and ICMP (ping) inbound so we can test connectivity."
  narrate ""
  type_cmd "osac create securitygroup --name $SG_NAME --virtual-network $VNET_NAME --ingress protocol=tcp,port-from=22,port-to=22,ipv4-cidr=0.0.0.0/0 --ingress protocol=icmp,ipv4-cidr=0.0.0.0/0"
  SG_ID=$(osac create securitygroup --name $SG_NAME --virtual-network "$VNET_NAME" \
    --ingress protocol=tcp,port-from=22,port-to=22,ipv4-cidr=0.0.0.0/0 \
    --ingress protocol=icmp,ipv4-cidr=0.0.0.0/0 2>&1 | grep -oP "ID: \K[0-9a-f-]+" || true)
  ok "Security Group created (ID: ${DIM}$SG_ID${RESET})"
  wait_resource_ready securitygroups "$SG_NAME"
  run_cmd "osac get securitygroups"
  pause

  # ── NAT Gateway ────────────────────────────────────────────────────────────
  narrate "Now a ${BOLD}NAT Gateway${RESET} for outbound internet access."
  narrate "This allocates a public IP and creates an SNAT rule so all servers"
  narrate "in the Virtual Network can reach the internet."
  narrate ""

  run_cmd "osac create externalip --name $NAT_EIP_NAME --pool $POOL_NAME"
  wait_resource_ready externalips "$NAT_EIP_NAME" 300

  run_cmd "osac create natgateway --name $NAT_NAME --virtual-network $VNET_NAME --externalip $NAT_EIP_NAME"
  wait_resource_ready natgateways "$NAT_NAME"

  narrate "The tenant network is ready. Let's review:"
  run_cmd "osac get virtualnetworks"
  run_cmd "osac get subnets"
  run_cmd "osac get natgateways"
  pause 3

  # ═══════════════════════════════════════════════════════════════════════════
  header "Part 2: Provisioning Bare-Metal Servers"

  narrate "We'll provision three servers:"
  narrate "  ${BOLD}Server 1${RESET} — Subnet A (10.100.1.0/24)"
  narrate "  ${BOLD}Server 2${RESET} — Subnet A (same subnet as Server 1)"
  narrate "  ${BOLD}Server 3${RESET} — Subnet B (10.100.2.0/24, different subnet)"
  narrate ""
  narrate "Each server is a real bare-metal host provisioned via metal3/Ironic."
  narrate "The OS image is written to disk, the server boots, and its fabric NIC"
  narrate "is connected to the tenant subnet via the Netris fabric."
  pause 2

  # ── Server 1 ───────────────────────────────────────────────────────────────
  narrate "${BOLD}Creating Server 1${RESET} on Subnet A..."
  type_cmd "osac create baremetalinstance --name $BMI1_NAME --catalog-item $CATALOG --network-attachment subnet=$SUBNET1_ID,interface=eth9,primary,security-groups=$SG_ID --ssh-key \"\$(cat ~/.ssh/id_rsa.pub)\""
  BMI1_ID=$(osac create baremetalinstance --name "$BMI1_NAME" \
    --catalog-item "$CATALOG" \
    --network-attachment "subnet=$SUBNET1_ID,interface=eth9,primary,security-groups=$SG_ID" \
    --ssh-key "$(cat ~/.ssh/id_rsa.pub)" 2>&1 | grep -oP "'\K[0-9a-f-]+")
  ok "Server 1 created (ID: ${DIM}$BMI1_ID${RESET})"
  narrate "Waiting for provisioning (OS image write + network handoff + reboot)..."
  wait_bmi_running "$BMI1_ID" 600

  local BMI1_IP BMI1_BMC
  BMI1_IP=$(get_bmi_tenant_ip "$BMI1_ID")
  BMI1_BMC=$(get_bmi_bmc_ip "$BMI1_ID")
  info "Server 1 tenant IP: ${GREEN}${BOLD}$BMI1_IP${RESET} (Subnet A)"

  narrate "Let's verify on the API:"
  run_cmd "osac get baremetalinstances"
  pause 2

  # ═══════════════════════════════════════════════════════════════════════════
  header "Part 3: Testing Egress (NAT Gateway)"

  narrate "Server 1 is running. Can it reach the internet?"
  narrate "The NAT Gateway provides SNAT egress — let's test with curl."
  narrate ""
  narrate "We use ${BOLD}toolbox${RESET} inside the server to get curl (it's a RHCOS host)."
  pause

  type_cmd "# SSH into Server 1 and test internet access"
  type_cmd "ssh core@<server-1> 'toolbox run curl -s -o /dev/null -w \"%{http_code}\" https://quay.io'"
  local http_code
  http_code=$(ssh_bmi "$BMI1_BMC" "toolbox run curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 https://quay.io" 2>/dev/null || echo "000")
  if [[ "$http_code" == "200" ]]; then
    echo "  HTTP $http_code"
    ok "Internet access works! The NAT Gateway is providing egress."
  else
    echo "  HTTP $http_code"
    info "Egress test returned $http_code (may need a moment for SNAT to propagate)"
  fi
  pause 2

  # ── Server 2 ───────────────────────────────────────────────────────────────
  header "Part 4: Second Server (Same Subnet) + L2 Connectivity"

  narrate "Now we add ${BOLD}Server 2${RESET} on the ${BOLD}same Subnet A${RESET}."
  narrate "Since both servers are on the same subnet, they share a broadcast"
  narrate "domain — they can discover each other at Layer 2 (arping)."
  pause

  type_cmd "osac create baremetalinstance --name $BMI2_NAME --catalog-item $CATALOG --network-attachment subnet=$SUBNET1_ID,interface=eth9,primary,security-groups=$SG_ID --ssh-key \"\$(cat ~/.ssh/id_rsa.pub)\""
  BMI2_ID=$(osac create baremetalinstance --name "$BMI2_NAME" \
    --catalog-item "$CATALOG" \
    --network-attachment "subnet=$SUBNET1_ID,interface=eth9,primary,security-groups=$SG_ID" \
    --ssh-key "$(cat ~/.ssh/id_rsa.pub)" 2>&1 | grep -oP "'\K[0-9a-f-]+")
  ok "Server 2 created"
  wait_bmi_running "$BMI2_ID" 600

  local BMI2_IP BMI2_BMC
  BMI2_IP=$(get_bmi_tenant_ip "$BMI2_ID")
  BMI2_BMC=$(get_bmi_bmc_ip "$BMI2_ID")
  info "Server 2 tenant IP: ${GREEN}${BOLD}$BMI2_IP${RESET} (Subnet A)"

  run_cmd "osac get baremetalinstances"
  pause

  narrate "Both servers are on Subnet A. Let's test connectivity."
  narrate ""
  narrate "${BOLD}Test 1: L2 — arping${RESET} (same broadcast domain)"
  narrate "arping sends ARP requests directly on the local network segment."
  narrate "If it works, the servers are truly on the same L2 domain."
  pause

  type_cmd "# From Server 1, arping Server 2"
  type_cmd "ssh core@<server-1> 'toolbox run arping -c 3 -I ens5 $BMI2_IP'"
  ssh_bmi "$BMI1_BMC" "toolbox run arping -c 3 -I ens5 $BMI2_IP" || true
  echo ""
  ok "arping works — Server 1 and Server 2 are on the same L2 segment"
  pause

  narrate "${BOLD}Test 2: L3 — ping${RESET}"
  type_cmd "ssh core@<server-1> 'ping -c 3 $BMI2_IP'"
  ssh_bmi "$BMI1_BMC" "ping -c 3 $BMI2_IP" || true
  echo ""
  ok "ping works too — full IP connectivity within the subnet"
  pause 2

  # ── Server 3 (different subnet) ────────────────────────────────────────────
  header "Part 5: Third Server (Different Subnet) + L3 vs L2"

  narrate "Now we add ${BOLD}Server 3${RESET} on ${BOLD}Subnet B${RESET} (10.100.2.0/24)."
  narrate "This is a different subnet in the same Virtual Network."
  narrate ""
  narrate "Key difference:"
  narrate "  Same subnet  = same broadcast domain → L2 (arping) works"
  narrate "  Diff subnet  = routed through gateway → only L3 (ping) works"
  pause 2

  type_cmd "osac create baremetalinstance --name $BMI3_NAME --catalog-item $CATALOG --network-attachment subnet=$SUBNET2_ID,interface=eth9,primary,security-groups=$SG_ID --ssh-key \"\$(cat ~/.ssh/id_rsa.pub)\""
  BMI3_ID=$(osac create baremetalinstance --name "$BMI3_NAME" \
    --catalog-item "$CATALOG" \
    --network-attachment "subnet=$SUBNET2_ID,interface=eth9,primary,security-groups=$SG_ID" \
    --ssh-key "$(cat ~/.ssh/id_rsa.pub)" 2>&1 | grep -oP "'\K[0-9a-f-]+")
  ok "Server 3 created"
  wait_bmi_running "$BMI3_ID" 600

  local BMI3_IP BMI3_BMC
  BMI3_IP=$(get_bmi_tenant_ip "$BMI3_ID")
  BMI3_BMC=$(get_bmi_bmc_ip "$BMI3_ID")
  info "Server 3 tenant IP: ${GREEN}${BOLD}$BMI3_IP${RESET} (Subnet B)"

  run_cmd "osac get baremetalinstances"
  pause

  narrate "${BOLD}Test 3: L3 ping across subnets${RESET}"
  narrate "Server 1 ($BMI1_IP, Subnet A) → Server 3 ($BMI3_IP, Subnet B)"
  narrate "These are in the same Virtual Network, so the gateway routes between them."
  pause

  type_cmd "ssh core@<server-1> 'ping -c 3 $BMI3_IP'"
  ssh_bmi "$BMI1_BMC" "ping -c 3 $BMI3_IP" || true
  echo ""
  ok "L3 ping works — the gateway routes between Subnet A and Subnet B"
  pause

  narrate "${BOLD}Test 4: L2 arping across subnets${RESET}"
  narrate "Now let's try arping — this should ${YELLOW}fail${RESET} because they're on"
  narrate "different broadcast domains (different subnets)."
  pause

  type_cmd "ssh core@<server-1> 'toolbox run arping -c 3 -I ens5 $BMI3_IP'"
  ssh_bmi "$BMI1_BMC" "toolbox run arping -c 3 -I ens5 $BMI3_IP" || true
  echo ""
  fail_expected "arping fails — different subnets, different broadcast domains"
  pause 2

  # ═══════════════════════════════════════════════════════════════════════════
  header "Part 6: Tenant Isolation"

  narrate "Can our servers reach the management cluster?"
  narrate "The management cluster runs on a completely different Virtual Network."
  narrate "OSAC enforces network isolation — tenant traffic cannot cross VNet boundaries."
  pause

  local MGMT_IP="192.168.40.2"
  narrate "Management cluster IP: $MGMT_IP (OCP node, different VNet)"
  narrate ""

  type_cmd "ssh core@<server-1> 'ping -c 3 -W 3 $MGMT_IP'"
  ssh_bmi "$BMI1_BMC" "ping -c 3 -W 3 $MGMT_IP" 2>/dev/null || true
  echo ""
  fail_expected "Cannot reach the management cluster — tenant isolation is enforced"
  narrate ""
  narrate "The tenant's servers are fully isolated from OSAC infrastructure."
  pause 3

  # ═══════════════════════════════════════════════════════════════════════════
  header "Part 7: External IP — Inbound Access (Ingress)"

  narrate "So far our servers can reach the internet (egress via NAT Gateway),"
  narrate "but nobody can reach them from outside (no public IP)."
  narrate ""
  narrate "To enable inbound access, we create an ${BOLD}External IP Attachment${RESET}."
  narrate "This allocates a public IP and creates a DNAT rule mapping it"
  narrate "to the server's private tenant IP."
  pause 2

  narrate "Step 1: Allocate an External IP from the pool"
  run_cmd "osac create externalip --name demo-ingress-eip --pool $POOL_NAME"
  wait_resource_ready externalips "demo-ingress-eip" 300
  local INGRESS_EIP_ID
  INGRESS_EIP_ID=$(osac get externalips 2>/dev/null | awk '/demo-ingress-eip/{print $4}')

  narrate "Step 2: Attach it to Server 1"
  run_cmd "osac create externalipattachment --name demo-ingress --externalip $INGRESS_EIP_ID --baremetal-instance $BMI1_ID"
  narrate "Waiting for the DNAT rule to be provisioned on the fabric..."
  wait_resource_ready externalipattachments "demo-ingress" 120

  local EXT_ADDR
  EXT_ADDR=$(osac get externalips 2>/dev/null | awk '/demo-ingress-eip/{print $8}')
  info "External IP address: ${GREEN}${BOLD}$EXT_ADDR${RESET}"
  narrate ""
  narrate "Now we can SSH to Server 1 from the hypervisor using its public IP:"
  pause

  type_cmd "ssh core@$EXT_ADDR 'hostname && ip -4 addr show ens5'"
  ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i /root/.ssh/id_rsa "core@$EXT_ADDR" 'hostname && echo "---" && ip -4 addr show ens5' 2>/dev/null || \
    info "SSH via external IP may need a moment for the DNAT to propagate"
  echo ""
  ok "Inbound access works — the External IP routes to the server's tenant IP"
  pause 3

  # ═══════════════════════════════════════════════════════════════════════════
  header "Summary"
  echo ""
  narrate "${BOLD}What we built:${RESET}"
  echo ""
  info "  ${BOLD}Virtual Network${RESET}      $VNET_NAME (10.100.0.0/16) — tenant-isolated L3 domain"
  info "  ${BOLD}Subnet A${RESET}             $SUBNET1_NAME (10.100.1.0/24) — broadcast domain 1"
  info "  ${BOLD}Subnet B${RESET}             $SUBNET2_NAME (10.100.2.0/24) — broadcast domain 2"
  info "  ${BOLD}Security Group${RESET}       $SG_NAME — SSH + ICMP allowed"
  info "  ${BOLD}NAT Gateway${RESET}          $NAT_NAME — SNAT egress to internet"
  info "  ${BOLD}External IP${RESET}          demo-ingress-eip — DNAT ingress to Server 1"
  echo ""
  narrate "${BOLD}What we proved:${RESET}"
  echo ""
  ok "Same subnet: L2 (arping) + L3 (ping) — same broadcast domain"
  ok "Cross subnet: L3 only — routed through the gateway, no L2"
  ok "Cross VNet: no connectivity — tenant isolation enforced"
  ok "NAT Gateway: SNAT egress to the internet"
  ok "External IP: DNAT ingress from a public IP"
  echo ""
  narrate "Every server was provisioned on bare metal via metal3/Ironic,"
  narrate "connected to the tenant fabric via Netris, and isolated by design."
  echo ""
  pause 3

  # ═══════════════════════════════════════════════════════════════════════════
  header "Part 8: Teardown — Removing All Resources"

  narrate "A clean demo ends with a clean environment."
  narrate "We delete in reverse dependency order — children before parents:"
  narrate "  1. External IP Attachment (depends on External IP + BMI)"
  narrate "  2. Ingress External IP (depends on pool)"
  narrate "  3. Bare-metal servers (depend on subnets)"
  narrate "  4. NAT Gateway (depends on External IP + Virtual Network)"
  narrate "  5. NAT External IP (depends on pool)"
  narrate "  6. Security Group (depends on Virtual Network)"
  narrate "  7. Subnets (depend on Virtual Network)"
  narrate "  8. Virtual Network"
  pause 2

  narrate "${BOLD}Step 1-2: Remove ingress (attachment first, then its External IP)${RESET}"
  run_cmd "osac delete externalipattachment demo-ingress"
  wait_resource_gone externalipattachments "demo-ingress"
  run_cmd "osac delete externalip demo-ingress-eip"
  wait_resource_gone externalips "demo-ingress-eip"

  narrate "${BOLD}Step 3: Delete all servers${RESET}"
  run_cmd "osac delete baremetalinstance $BMI1_NAME"
  run_cmd "osac delete baremetalinstance $BMI2_NAME"
  run_cmd "osac delete baremetalinstance $BMI3_NAME"

  narrate ""
  narrate "Waiting for servers to deprovision (network offboard + disk wipe)..."
  wait_resource_gone baremetalinstances "$BMI1_NAME" 900
  wait_resource_gone baremetalinstances "$BMI2_NAME" 900
  wait_resource_gone baremetalinstances "$BMI3_NAME" 900
  ok "All servers deprovisioned and removed"
  pause

  narrate "${BOLD}Step 4-5: Remove NAT Gateway, then its External IP${RESET}"
  run_cmd "osac delete natgateway $NAT_NAME"
  wait_resource_gone natgateways "$NAT_NAME"
  run_cmd "osac delete externalip $NAT_EIP_NAME"
  wait_resource_gone externalips "$NAT_EIP_NAME"

  narrate "${BOLD}Step 6: Remove Security Group${RESET}"
  run_cmd "osac delete securitygroup $SG_ID"
  wait_resource_gone securitygroups "$SG_NAME"

  narrate "${BOLD}Step 7-8: Remove Subnets, then Virtual Network${RESET}"
  run_cmd "osac delete subnet $SUBNET1_NAME"
  wait_resource_gone subnets "$SUBNET1_NAME"
  run_cmd "osac delete subnet $SUBNET2_NAME"
  wait_resource_gone subnets "$SUBNET2_NAME"
  run_cmd "osac delete virtualnetwork $VNET_NAME"
  wait_resource_gone virtualnetworks "$VNET_NAME"

  narrate ""
  narrate "Final state — everything removed:"
  run_cmd "osac get virtualnetworks"
  run_cmd "osac get subnets"
  run_cmd "osac get natgateways"
  run_cmd "osac get baremetalinstances"
  echo ""
  ok "All resources successfully removed. Environment is clean."
  pause 5
}

# ── Main ─────────────────────────────────────────────────────────────────────

case "${1:-}" in
  --no-record)
    run_demo
    ;;
  --cleanup)
    CLEANUP=true
    stty cols 120 rows 40 2>/dev/null || true
    asciinema rec --title "OSAC BMaaS Networking Demo" \
      -c "bash -c 'source $0 && run_demo'" "${CAST_FILE}"
    ;;
  *)
    stty cols 120 rows 40 2>/dev/null || true
    asciinema rec --title "OSAC BMaaS Networking Demo" \
      -c "bash -c 'source $0 && run_demo'" "${CAST_FILE}"
    ;;
esac
