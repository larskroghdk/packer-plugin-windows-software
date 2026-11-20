// Command packer-plugin-windows-software installs validated Windows software over WinRM.
package main

import (
	"fmt"
	"github.com/hashicorp/packer-plugin-sdk/plugin"
	sdkversion "github.com/hashicorp/packer-plugin-sdk/version"
	"github.com/larskroghdk/packer-plugin-windows-software/provisioner"
	"os"
)

var version = "0.1.0"
var versionPrerelease = "dev"

func main() {
	v := sdkversion.NewPluginVersion(version, versionPrerelease, "")
	set := plugin.NewSet()
	set.RegisterProvisioner(plugin.DEFAULT_NAME, provisioner.New(v.FormattedVersion()))
	set.SetVersion(v)
	if err := set.Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
