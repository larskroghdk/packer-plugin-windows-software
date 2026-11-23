// Package packages embeds the validated installer catalog, so a released
// plugin binary works without a catalog file on the Packer host.
package packages

import _ "embed"

// Catalog is packages/catalog.json as it was when the plugin was built.
//
//go:embed catalog.json
var Catalog []byte
