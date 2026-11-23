package provisioner

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestPrivateDirectoryScript runs the working directory script under Windows
// PowerShell and checks that the directory admits only SYSTEM and
// Administrators and that an existing directory is refused. PSModulePath is
// cleared so that a PowerShell 7 parent shell cannot load its modules into
// Windows PowerShell.
func TestPrivateDirectoryScript(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("requires Windows PowerShell")
	}
	powershell, err := exec.LookPath("powershell.exe")
	if err != nil {
		t.Skip("powershell.exe is not available")
	}
	run := func(script string) (string, error) {
		cmd := exec.Command(powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script)
		for _, kv := range os.Environ() {
			if !strings.HasPrefix(strings.ToUpper(kv), "PSMODULEPATH=") {
				cmd.Env = append(cmd.Env, kv)
			}
		}
		out, err := cmd.CombinedOutput()
		return strings.TrimSpace(string(out)), err
	}
	dir := filepath.Join(t.TempDir(), "work dir's")
	quoted := "'" + strings.ReplaceAll(dir, "'", "''") + "'"
	if out, err := run(privateDirectoryScript(dir)); err != nil {
		t.Fatalf("create: %v: %s", err, out)
	}
	t.Cleanup(func() {
		if out, err := run(`$a = Get-Acl -LiteralPath ` + quoted + `; $a.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule([System.Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))); (New-Object System.IO.DirectoryInfo(` + quoted + `)).SetAccessControl($a)`); err != nil {
			t.Errorf("restore access for cleanup: %v: %s", err, out)
		}
	})
	acl, err := run(`$a = Get-Acl -LiteralPath ` + quoted + `; [string]$a.AreAccessRulesProtected + ' ' + ((@($a.Access | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value + '=' + $_.FileSystemRights }) | Sort-Object) -join ',')`)
	if err != nil {
		t.Fatalf("read ACL: %v: %s", err, acl)
	}
	if want := "True S-1-5-18=FullControl,S-1-5-32-544=FullControl"; acl != want {
		t.Fatalf("ACL = %q, want %q", acl, want)
	}
	if out, err := run(privateDirectoryScript(dir)); err == nil || !strings.Contains(out, "already exists") {
		t.Fatalf("second run = %v: %s, want a refusal", err, out)
	}
}
