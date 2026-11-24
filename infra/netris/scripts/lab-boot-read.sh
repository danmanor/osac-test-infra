#!/usr/bin/env bash
# lab-boot-read.sh - read-only dump of how the lab VMs' first boot went.
#
#   lab-boot-read.sh
#
# For the mgmt-server (192.168.122.10) and each running ns-softgate-<n> libvirt domain
# (10.3.3.<n+1>), prints a "=== <name> (<ip>)" header followed by the hostname,
# `cloud-init status --long`, the download result lines (ovpn-download, netris-download,
# curl and apt errors), the apt sources and how many apt downloads went to each host
# (which shows whether the VM used the configured mirror), the tail of
# /var/log/cloud-init-output.log, the OpenVPN
# server state and the installed openvpn and netris packages. Their first boot
# downloads packages, OpenVPN certificates and the Netris agent from the internet,
# and a failed download shows up much later as a service that never started; this
# names the download. Values after --auth and after auth/token/password/secret/key
# keys are masked. Hosts are read in parallel over SSH as root with the lab host's
# key, as setup does, each within 60s. An unreachable or stuck host is reported in
# its section and does not fail the script. gather-infra runs it at the end of the job.
set -uo pipefail

work="$(mktemp -d)" || exit 1
trap 'rm -rf -- "${work}"' EXIT

# Expanded on the guest, not here.
remote="hostname
echo '== cloud-init status'; cloud-init status --long 2>&1 | head -40
echo '== download results'; grep -h -E 'ovpn-download|netris-download|netris-install|curl: \\(|Could not resolve|Failed to fetch|Temporary failure|E: ' /var/log/cloud-init-output.log 2>/dev/null | tail -60
echo '== apt sources'; grep -h -E '^(URIs:|deb )' /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list /etc/apt/sources.list 2>/dev/null | sort | uniq -c
echo '== apt downloads per host'; grep -h -o -E '^(Get|Hit|Ign|Err):[0-9]+ https?://[^ /]+' /var/log/cloud-init-output.log 2>/dev/null | sed -E 's/:[0-9]+ / /' | sort | uniq -c
echo '== cloud-init output (tail)'; tail -n 120 /var/log/cloud-init-output.log 2>/dev/null
echo '== openvpn server'; systemctl is-active openvpn@server 2>&1; ls -l /etc/openvpn 2>&1 | head -20
echo '== packages'; dpkg-query -W -f='\${Package} \${Version} \${db:Status-Abbrev}\n' 'openvpn' 'netris*' 2>&1 | head -20"

# URL credentials (user:password@, as in an apt mirror URL) are masked. A quoted
# value is masked whole, escaped quotes included; a quote that is not closed masks
# the rest of the line.
key='(([Aa][Uu][Tt][Hh]|[Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Kk][Ee][Yy])[A-Za-z_]*["\x27]?[ ]*[:=][ ]*)'
mask() {
    sed -E \
        -e 's#(://)[^/@ ]+@#\1<masked>@#g' \
        -e 's/(--auth[= ]+)("([^"\\]|\\.)*"|\x27([^\x27\\]|\\.)*\x27)/\1<masked>/g' \
        -e 's/(--auth[= ]+)["\x27].*$/\1<masked>/' \
        -e 's/(--auth[= ]+)[^ ]+/\1<masked>/g' \
        -e "s/${key}(\"([^\"\\\\]|\\\\.)*\"|\\x27([^\\x27\\\\]|\\\\.)*\\x27)/\\1<masked>/g" \
        -e "s/${key}[\"\\x27].*\$/\\1<masked>/" \
        -e "s/${key}[^ \"\\x27]+/\\1<masked>/g"
}

# Each read gets its own deadline, well inside gather-infra's 120s for the whole
# script: ConnectTimeout bounds only the connection, and one stuck session must
# not hold back the sections of the hosts that answered.
read_deadline="${LAB_BOOT_READ_DEADLINE:-60}"

read_host() {
    local name="$1" ip="$2" rc=0
    {
        echo "=== ${name} (${ip})"
        timeout "${read_deadline}" ssh -n -o BatchMode=yes -o ConnectTimeout=3 -o ServerAliveInterval=10 \
            -o ServerAliveCountMax=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR "root@${ip}" "${remote}" 2>&1 || rc=$?
        if [ "${rc}" -eq 124 ]; then
            echo "lab-boot-read: ${name} (${ip}) read timed out after ${read_deadline}s"
        elif [ "${rc}" -ne 0 ]; then
            echo "lab-boot-read: ${name} (${ip}) read failed (exit ${rc})"
        fi
    } | mask > "${work}/${name}"
}

read_host mgmt-server 192.168.122.10 &
# The loop reads from a process substitution, not a pipe, so the reads it starts are
# children of this shell and the wait below waits for them.
while read -r name n; do
    read_host "${name}" "10.3.3.$((n + 1))" &
done < <(virsh list --name 2>/dev/null | sed -n 's/^\(ns-softgate-\([0-9]\+\)\)$/\1 \2/p')
wait
cat "${work}"/* 2>/dev/null
exit 0
