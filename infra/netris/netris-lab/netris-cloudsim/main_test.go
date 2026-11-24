package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/netrisai/netriswebapi/v2/types/ipam"
	"gopkg.in/yaml.v3"
)

// mgmtPackages is the mgmt-server's package list in main.go.
var mgmtPackages = []string{"apache2", "isc-dhcp-server", "iptables-persistent", "openvpn"}

func sgCloudInitArgs() map[string]interface{} {
	return map[string]interface{}{
		"hostname":          "softgate",
		"passwordHash":      "hash",
		"sshAuthKey":        []string{"key"},
		"installedPackages": []string{"lldpd"},
		"dnsServer":         "10.0.0.1",
		"ctlInfo": NetrisControllerInfo{
			Version: "4.16.0-001",
			AuthKey: "auth-key",
			AptRepo: "main",
		},
		"allVms": [][]map[string]string{{
			{
				"Type":        "softgate",
				"Name":        "ns-softgate-0",
				"MainAddress": "10.2.3.1",
				"MgmtAddress": "10.3.3.1/24",
			},
		}},
	}
}

// userData parses rendered cloud-init user data and returns its runcmd entries.
func userData(t *testing.T, cloudInit string) []interface{} {
	t.Helper()
	var doc map[string]interface{}
	if err := yaml.Unmarshal([]byte(cloudInit), &doc); err != nil {
		t.Fatalf("rendered cloud-init is not valid YAML: %v", err)
	}
	runcmd, ok := doc["runcmd"].([]interface{})
	if !ok {
		t.Fatalf("rendered cloud-init has no runcmd list")
	}
	return runcmd
}

func TestSoftgateCloudInitDownloadsInstallerBeforeRunningIt(t *testing.T) {
	cloudInit := prepareCloudInitSG(sgCloudInitArgs(), false)
	userData(t, cloudInit)

	if strings.Contains(cloudInit, "get.netris.io | sh") {
		t.Fatal("the Netris installer must not be piped into sh: a failed download then runs nothing, silently")
	}
	download := strings.Index(cloudInit, "-o /root/netris-install.sh https://get.netris.io")
	run := strings.Index(cloudInit, "sh /root/netris-install.sh --lo $MAINIP")
	if download < 0 || run < 0 || run < download {
		t.Fatal("softgate cloud-init must download the installer to a file, then run it")
	}
	if !strings.Contains(cloudInit[download-400:download], "curl -fsSL --retry 5") {
		t.Fatal("the installer download must fail on HTTP errors and retry")
	}
	if !strings.Contains(cloudInit, `echo "netris-download: FAILED https://get.netris.io" >&2`) {
		t.Fatal("a failed installer download must be logged")
	}
}

// shellify joins runcmd entries into one /bin/sh script the way cloud-init does
// (cloudinit.util.shellify): a string entry is copied as is, a list entry is
// shell-quoted and joined. An exit in any entry therefore ends all of runcmd.
func shellify(runcmd []interface{}) string {
	var b strings.Builder
	b.WriteString("#!/bin/sh\n")
	for _, entry := range runcmd {
		switch v := entry.(type) {
		case string:
			b.WriteString(v + "\n")
		case []interface{}:
			parts := make([]string, 0, len(v))
			for _, p := range v {
				parts = append(parts, "'"+strings.ReplaceAll(p.(string), "'", `'"'"'`)+"'")
			}
			b.WriteString(strings.Join(parts, " ") + "\n")
		}
	}
	return b.String()
}

// runMgmtRuncmd runs the mgmt-server runcmd as cloud-init would, with every
// system path moved under a temp dir and every external command stubbed: the
// stubs append their argv to calls.log; curl writes its -o file, or fails for
// curlFails. dpkg-query reports every package installed except those in missing,
// until apt-get has run once; a missing entry "name=status" reports that status
// (a partial install) and a plain name reports the package as unknown. It returns the script's exit code, its output and calls.log.
func runMgmtRuncmd(t *testing.T, curlFails bool, missing ...string) (int, string, string, string) {
	t.Helper()
	if _, err := exec.LookPath("sh"); err != nil {
		t.Skip("sh not available")
	}
	args := sgCloudInitArgs()
	args["hostname"] = "mgmt-server"
	args["installedPackages"] = mgmtPackages
	subnet := ipam.IPAM{DefaultGateway: "192.168.122.10", Prefix: "192.168.122.0/24"}
	subnet.Subnet.Length = 24
	args["ips"] = []ipam.IPAM{subnet}
	script := shellify(userData(t, prepareCloudInitForMgmt(args, false)))

	root := t.TempDir()
	for _, dir := range []string{"etc/openvpn", "etc/iptables", "etc/dhcp", "root", "tmp", "var/www/html", "bin"} {
		if err := os.MkdirAll(filepath.Join(root, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	// One pass, so a path already moved under root (itself under /tmp/) is not
	// rewritten again by the /tmp/ rule.
	var pairs []string
	for _, prefix := range []string{"/etc/", "/root/", "/tmp/", "/var/"} {
		for _, before := range []string{" ", "<", ">", "\""} {
			pairs = append(pairs, before+prefix, before+root+prefix)
		}
	}
	script = strings.NewReplacer(pairs...).Replace(script)
	curl := `out=""; prev=""; for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done`
	if curlFails {
		curl += "\nexit 22"
	} else {
		curl += "\n" + `[ -n "$out" ] || exit 2; echo stub > "$out" || exit 23; echo "ovpn-download: stub http=200"`
	}
	installed := filepath.Join(root, "apt-installed")
	dpkg := `[ -f "` + installed + `" ] && { printf 'install ok installed'; exit 0; }`
	for _, p := range missing {
		if name, status, partial := strings.Cut(p, "="); partial {
			dpkg += "\n" + `[ "$3" = "` + name + `" ] && { printf '` + status + `'; exit 0; }`
		} else {
			dpkg += "\n" + `[ "$3" = "` + p + `" ] && exit 1`
		}
	}
	stubs := map[string]string{
		"curl": curl, "systemctl": "", "sysctl": "", "iptables-restore": "",
		"apt-get": `touch "` + installed + `"`, "dpkg-query": dpkg + "\nprintf 'install ok installed'", "sleep": "", "sudo": `"$@"`,
	}
	calls := filepath.Join(root, "calls.log")
	for name, body := range stubs {
		content := "#!/bin/sh\necho \"" + name + " $*\" >> " + calls + "\n" + body + "\n"
		if err := os.WriteFile(filepath.Join(root, "bin", name), []byte(content), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	scriptPath := filepath.Join(root, "runcmd")
	if err := os.WriteFile(scriptPath, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "sh", scriptPath)
	cmd.Env = append(os.Environ(), "PATH="+filepath.Join(root, "bin")+":"+os.Getenv("PATH"))
	out, err := cmd.CombinedOutput()
	code := 0
	if exitErr, ok := err.(*exec.ExitError); ok {
		code = exitErr.ExitCode()
	} else if err != nil {
		t.Fatal(err)
	}
	log, err := os.ReadFile(calls)
	if err != nil {
		t.Fatalf("reading the stub call log: %v\noutput:\n%s", err, out)
	}
	return code, string(out), string(log), root
}

func TestMgmtRuncmdStartsOpenVPNAfterFetchingItsFiles(t *testing.T) {
	code, out, calls, root := runMgmtRuncmd(t, false)
	if !strings.Contains(calls, "systemctl start openvpn@server") {
		t.Fatalf("runcmd must reach systemctl start openvpn@server (exit %d)\noutput:\n%s\ncalls:\n%s", code, out, calls)
	}
	for _, f := range []string{"ca.crt", "dh.pem", "myservername.crt", "myservername.key", "ta.key"} {
		if _, err := os.Stat(filepath.Join(root, "etc", "openvpn", f)); err != nil {
			t.Fatalf("OpenVPN file %s was not written: %v\noutput:\n%s", f, err, out)
		}
	}
	if strings.Contains(out, "ovpn-download: FAILED") {
		t.Fatalf("no download may fail on the success path, output:\n%s", out)
	}
}

func TestMgmtRuncmdStopsAndNamesTheURLWhenADownloadFails(t *testing.T) {
	code, out, calls, _ := runMgmtRuncmd(t, true)
	if code == 0 {
		t.Fatal("runcmd must fail when an OpenVPN file download fails")
	}
	if !strings.Contains(out, "ovpn-download: FAILED https://raw.githubusercontent.com/rawfilescloud/ovpn-config-examples/main/ca.crt") {
		t.Fatalf("a failed download must name its URL, output:\n%s", out)
	}
	if strings.Contains(calls, "systemctl start openvpn@server") {
		t.Fatal("runcmd must not start OpenVPN without its files")
	}
}

func TestMgmtCloudInitFetchesOpenVPNFilesWithFailOnError(t *testing.T) {
	args := sgCloudInitArgs()
	args["hostname"] = "mgmt-server"
	args["installedPackages"] = []string{"apache2", "isc-dhcp-server", "iptables-persistent", "openvpn"}
	subnet := ipam.IPAM{
		DefaultGateway: "192.168.122.10",
		IPFamily:       "ipv4",
		Purpose:        "management",
		Prefix:         "192.168.122.0/24",
		Type:           "subnet",
	}
	subnet.Subnet.Length = 24
	subnet.Subnet.Prefix = "192.168.122.0"
	args["ips"] = []ipam.IPAM{subnet}
	cloudInit := prepareCloudInitForMgmt(args, false)
	runcmd := userData(t, cloudInit)

	if strings.Contains(cloudInit, "curl -sS https://raw.githubusercontent.com") {
		t.Fatal("OpenVPN files must not be fetched without -f: an HTTP error page is saved as the certificate")
	}
	fetch, start := -1, -1
	for i, entry := range runcmd {
		text, _ := entry.(string)
		if text == "" {
			if list, ok := entry.([]interface{}); ok && len(list) == 3 {
				text, _ = list[2].(string)
			}
		}
		if strings.Contains(text, "for f in ca.crt dh.pem myservername.crt myservername.key ta.key") &&
			strings.Contains(text, "curl -fsS --retry 5") {
			fetch = i
		}
		if text == "systemctl start openvpn@server" {
			start = i
		}
	}
	if fetch < 0 || start < 0 || start < fetch {
		t.Fatalf("mgmt runcmd must fetch the OpenVPN files with -f before starting the server (fetch=%d start=%d)", fetch, start)
	}
}

func TestSortLinkMappingsByNumericLocalPort(t *testing.T) {
	links := []LinkMapping{
		{LocalPortIndex: 10, Local: "eth10"},
		{LocalPortIndex: 9, Local: "eth9"},
		{LocalPortIndex: 11, Local: "eth11"},
	}

	sortLinkMappings(links)

	got := []string{links[0].Local, links[1].Local, links[2].Local}
	want := []string{"eth9", "eth10", "eth11"}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("link order = %v, want %v", got, want)
		}
	}
}

func TestControllerInfoUsesConfiguredBackendVersion(t *testing.T) {
	info := controllerInfo(
		NetrisController{BackendVersion: "4.16.0-008"},
		"auth-key",
		"main",
	)

	if info.Version != "4.16.0-008" {
		t.Fatalf("expected configured backend version 4.16.0-008, got %q", info.Version)
	}
}

func TestPrepareCloudInitSGGuardsNetworkScriptInBootcmd(t *testing.T) {
	cloudInit := prepareCloudInitSG(map[string]interface{}{
		"hostname":          "softgate",
		"passwordHash":      "hash",
		"sshAuthKey":        []string{"key"},
		"installedPackages": []string{"lldpd"},
		"dnsServer":         "10.0.0.1",
		"ctlInfo": NetrisControllerInfo{
			Version: "4.16.0-001",
			AuthKey: "auth-key",
			AptRepo: "main",
		},
		"allVms": [][]map[string]string{{
			{
				"Type":        "softgate",
				"Name":        "ns-softgate-0",
				"MainAddress": "10.2.3.1",
				"MgmtAddress": "10.3.3.1/24",
			},
		}},
	}, false)

	bootcmdStart := strings.Index(cloudInit, "bootcmd:")
	runcmdStart := -1
	writeFilesStart := -1
	if bootcmdStart >= 0 {
		runcmdStart = strings.Index(cloudInit[bootcmdStart:], "runcmd:")
		if runcmdStart >= 0 {
			runcmdStart += bootcmdStart
		}
		writeFilesStart = strings.Index(cloudInit[bootcmdStart:], "write_files:")
		if writeFilesStart >= 0 {
			writeFilesStart += bootcmdStart
		}
	}
	if bootcmdStart < 0 || runcmdStart < 0 || writeFilesStart < 0 || runcmdStart >= writeFilesStart {
		t.Fatalf("cloud-init is missing the expected bootcmd/runcmd/write_files sections")
	}

	bootcmd := cloudInit[bootcmdStart:runcmdStart]
	if !strings.Contains(bootcmd, "if [ -x /etc/network_nics_up.sh ]; then bash /etc/network_nics_up.sh; fi") {
		t.Fatal("softgate bootcmd must run network_nics_up.sh only when the helper exists")
	}

	if count := strings.Count(cloudInit[runcmdStart:writeFilesStart], "bash /etc/network_nics_up.sh"); count != 1 {
		t.Fatalf("network_nics_up.sh invocation count = %d, want 1", count)
	}
}

const testAptMirror = "http://us-east-1.ec2.archive.ubuntu.com/ubuntu"

// ubuntuCloudInits renders every Ubuntu VM's user data with the given aptMirror
// ("" leaves it unset, as when the Pulumi config has no apt_mirror).
func ubuntuCloudInits(t *testing.T, aptMirror string) map[string]string {
	t.Helper()
	args := func() map[string]interface{} {
		a := sgCloudInitArgs()
		if aptMirror != "" {
			a["aptMirror"] = aptMirror
		}
		return a
	}
	mgmt := args()
	mgmt["installedPackages"] = mgmtPackages
	subnet := ipam.IPAM{DefaultGateway: "192.168.122.10", Prefix: "192.168.122.0/24"}
	subnet.Subnet.Length = 24
	mgmt["ips"] = []ipam.IPAM{subnet}
	return map[string]string{
		"server":       prepareCloudInit(args(), false),
		"softgate":     prepareCloudInitSG(args(), false),
		"isp":          prepareCloudInitISP(args(), false),
		"isp-internal": prepareCloudInitISPInternal(args(), false),
		"mgmt-server":  prepareCloudInitForMgmt(mgmt, false),
	}
}

func aptSection(t *testing.T, name, cloudInit string) map[string]interface{} {
	t.Helper()
	var doc map[string]interface{}
	if err := yaml.Unmarshal([]byte(cloudInit), &doc); err != nil {
		t.Fatalf("%s: rendered cloud-init is not valid YAML: %v", name, err)
	}
	apt, ok := doc["apt"].(map[string]interface{})
	if !ok {
		t.Fatalf("%s: cloud-init has no apt section", name)
	}
	return apt
}

func TestUbuntuCloudInitsMakeAptRetryAndTimeOut(t *testing.T) {
	for name, cloudInit := range ubuntuCloudInits(t, "") {
		apt := aptSection(t, name, cloudInit)
		conf, _ := apt["conf"].(string)
		for _, want := range []string{`Acquire::Retries "5";`, `Acquire::http::Timeout "30";`, `Acquire::https::Timeout "30";`} {
			if !strings.Contains(conf, want) {
				t.Errorf("%s: apt conf must contain %s, got:\n%s", name, want, conf)
			}
		}
		if _, ok := apt["primary"]; ok {
			t.Errorf("%s: without apt_mirror the image's mirrors must be kept", name)
		}
	}
}

func TestUbuntuCloudInitsUseTheConfiguredMirror(t *testing.T) {
	for name, cloudInit := range ubuntuCloudInits(t, testAptMirror) {
		apt := aptSection(t, name, cloudInit)
		for _, pocket := range []string{"primary", "security"} {
			entries, _ := apt[pocket].([]interface{})
			if len(entries) != 1 {
				t.Fatalf("%s: apt %s must have one entry, got %v", name, pocket, apt[pocket])
			}
			if uri := entries[0].(map[string]interface{})["uri"]; uri != testAptMirror {
				t.Errorf("%s: apt %s uri = %v, want %s", name, pocket, uri, testAptMirror)
			}
		}
	}
}

func TestSoftgateWaitsForTheMirrorNameBeforeTheFirstAptUpdate(t *testing.T) {
	for mirror, host := range map[string]string{
		"":                                   "archive.ubuntu.com",
		testAptMirror:                        "us-east-1.ec2.archive.ubuntu.com",
		"http://mirror.internal:8080/ubuntu": "mirror.internal",
		"http://192.168.122.20/ubuntu":       "192.168.122.20",
	} {
		args := sgCloudInitArgs()
		if mirror != "" {
			args["aptMirror"] = mirror
		}
		script := shellify(userData(t, prepareCloudInitSG(args, false)))
		wait := strings.Index(script, "apt_host="+host+"\n")
		resolve := strings.Index(script, `until getent hosts "$apt_host"`)
		update := strings.Index(script, "apt-get update")
		if wait < 0 || resolve < wait || update < resolve {
			t.Fatalf("mirror %q: softgate runcmd must wait for %s to resolve before apt-get update (wait=%d resolve=%d update=%d)", mirror, host, wait, resolve, update)
		}
		// getent, not nslookup: nslookup does a reverse (PTR) lookup for an IP
		// mirror, and the wait would never end where that record is missing.
		if !strings.Contains(script, "getent hosts "+host+" > /dev/null") || strings.Contains(script, "nslookup") {
			t.Errorf("mirror %q: the softgate connectivity wait must look up %s with getent", mirror, host)
		}
		if !strings.Contains(script, "apt-get update && apt-get install -y isc-dhcp-client && break") {
			t.Fatal("the isc-dhcp-client install must be retried")
		}
	}
}

func TestMgmtRuncmdReinstallsPackagesCloudInitFailedToInstall(t *testing.T) {
	code, out, calls, _ := runMgmtRuncmd(t, false, "openvpn")
	if !strings.Contains(out, "apt-retry: installing missing packages: openvpn (try 1)") {
		t.Fatalf("a missing package must be named and reinstalled (exit %d), output:\n%s", code, out)
	}
	if strings.Contains(out, "(try 2)") {
		t.Fatalf("the retry must stop once the packages are installed, output:\n%s", out)
	}
	install := strings.Index(calls, "apt-get install -y openvpn")
	restart := strings.Index(calls, "systemctl restart isc-dhcp-server")
	if install < 0 || restart < install {
		t.Fatalf("missing packages must be installed before the services they provide are used, calls:\n%s", calls)
	}
	if !strings.Contains(calls, "systemctl start openvpn@server") {
		t.Fatalf("runcmd must still reach systemctl start openvpn@server, calls:\n%s", calls)
	}
}

func TestMgmtRuncmdReinstallsPartlyInstalledPackages(t *testing.T) {
	_, out, calls, _ := runMgmtRuncmd(t, false, "openvpn=install ok unpacked", "isc-dhcp-server=install ok half-configured")
	if !strings.Contains(out, "apt-retry: installing missing packages: isc-dhcp-server openvpn (try 1)") {
		t.Fatalf("unpacked and half-configured packages must be reinstalled, output:\n%s\ncalls:\n%s", out, calls)
	}
}

func TestMgmtRuncmdSkipsTheRetryWhenPackagesAreInstalled(t *testing.T) {
	_, out, calls, _ := runMgmtRuncmd(t, false)
	if strings.Contains(out, "apt-retry:") || strings.Contains(calls, "apt-get install") {
		t.Fatalf("nothing may be reinstalled when every package is present, output:\n%s\ncalls:\n%s", out, calls)
	}
}

func TestServerAndSoftgateRetryMissingPackagesAfterTheMirrorWait(t *testing.T) {
	for name, cloudInit := range map[string]string{
		"server":   prepareCloudInit(sgCloudInitArgs(), false),
		"softgate": prepareCloudInitSG(sgCloudInitArgs(), false),
	} {
		script := shellify(userData(t, cloudInit))
		wait := strings.Index(script, `until getent hosts "$apt_host"`)
		retry := strings.Index(script, "apt-retry: installing missing packages:")
		if wait < 0 || retry < wait {
			t.Errorf("%s: cloud-init's packages step can run before the mirror resolves, so the missing packages must be retried after the wait (wait=%d retry=%d)", name, wait, retry)
		}
		if !strings.Contains(script, "for p in qemu-guest-agent lldpd; do") {
			t.Errorf("%s: the retry must cover qemu-guest-agent and the configured packages", name)
		}
	}
}

func TestServerWaitsForTheNetrisRepositoryAndRetriesNetrisHnp(t *testing.T) {
	script := shellify(userData(t, prepareCloudInit(sgCloudInitArgs(), false)))
	wait := strings.Index(script, "until getent hosts repo.netris.ai")
	install := strings.Index(script, "apt-get update && apt-get install -y netris-hnp && break")
	if wait < 0 || install < wait {
		t.Fatalf("the server must wait for repo.netris.ai before installing netris-hnp, and retry it (wait=%d install=%d)", wait, install)
	}
}
