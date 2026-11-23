# Go standards

Use the toolchain declared in [go.mod](../../go.mod), [project constraints](../architecture/overview.md), and the owning module's AGENTS.md when present. Keep Packer lifecycle and communicator ownership in the provisioner and preserve existing package boundaries.

Propagate context and errors, bound retries, and own files, timers and goroutines explicitly. Preserve unknown guest observations and versioned JSON/HCL contracts. Follow this project's source documentation conventions rather than introducing generic comment policies.

Use [go-development](../skills/go-development/SKILL.md) and the [testing requirements](testing.md).
