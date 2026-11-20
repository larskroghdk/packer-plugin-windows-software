package provisioner

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"

	"github.com/hashicorp/packer-plugin-sdk/packer"

	"github.com/larskroghdk/packer-plugin-windows-software/guest"
)

// remote runs guest engine actions in a per-run directory through the builder's communicator.
type remote struct {
	comm     packer.Communicator
	ui       packer.Ui
	dir      string
	sequence int
	created  bool
}

func (r *remote) path(name string) string { return r.dir + `\` + name }

func (r *remote) exec(ctx context.Context, args string) error {
	cmd := &packer.RemoteCmd{Command: `powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass ` + args}
	if err := cmd.RunWithUi(ctx, r.comm, r.ui); err != nil {
		return err
	}
	if cmd.ExitStatus() != 0 {
		return fmt.Errorf("PowerShell exited with status %d", cmd.ExitStatus())
	}
	return nil
}

// setup creates the working directory and uploads the embedded engine.
func (r *remote) setup(ctx context.Context) error {
	if err := r.exec(ctx, fmt.Sprintf(`-Command "$ErrorActionPreference='Stop'; $null=New-Item -ItemType Directory -Path '%s'"`, r.dir)); err != nil {
		return err
	}
	r.created = true
	return r.comm.Upload(r.path("Install.ps1"), bytes.NewReader(guest.Script), nil)
}

// cleanup removes the working directory's files and then the directory. It
// refuses a reparse-point root or subdirectories rather than recursing.
func (r *remote) cleanup(ctx context.Context) error {
	if !r.created {
		return nil
	}
	// dir is constructed exclusively from a fixed root and an SDK-generated UUID.
	return r.exec(ctx, fmt.Sprintf(`-Command "$ErrorActionPreference='Stop'; $p=Get-Item -LiteralPath '%s'; if ($p.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point at working directory' }; Get-ChildItem -LiteralPath $p.FullName -Force | ForEach-Object { if ($_.Attributes -band [IO.FileAttributes]::Directory) { throw 'Unexpected directory in working directory' }; Remove-Item -LiteralPath $_.FullName -Force }; Remove-Item -LiteralPath $p.FullName -Force"`, r.dir))
}

// action uploads the optional JSON input, runs one engine action and decodes its result into out.
func (r *remote) action(ctx context.Context, name string, input, out any) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	r.sequence++
	prefix := fmt.Sprintf("%03d", r.sequence)
	args := fmt.Sprintf(`-File "%s" -Action %s -OutputPath "%s"`, r.path("Install.ps1"), name, r.path(prefix+"-out.json"))
	if input != nil {
		data, err := json.Marshal(input)
		if err != nil {
			return err
		}
		path := r.path(prefix + "-in.json")
		if err = r.comm.Upload(path, bytes.NewReader(data), nil); err != nil {
			return err
		}
		args += fmt.Sprintf(` -InputPath "%s"`, path)
	}
	if err := r.exec(ctx, args); err != nil {
		return err
	}
	var b bytes.Buffer
	if err := r.comm.Download(r.path(prefix+"-out.json"), &b); err != nil {
		return err
	}
	// Windows PowerShell 5.1 writes UTF-8 with a byte order mark.
	if err := json.Unmarshal(bytes.TrimPrefix(b.Bytes(), []byte("\xef\xbb\xbf")), out); err != nil {
		return fmt.Errorf("decode guest %s result: %w", name, err)
	}
	return ctx.Err()
}
