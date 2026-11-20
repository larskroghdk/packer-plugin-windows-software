// Package guest embeds the reviewed PowerShell installation engine.
package guest

import _ "embed"

// Script runs under Windows PowerShell 5.1.
//
//go:embed Install.ps1
var Script []byte
