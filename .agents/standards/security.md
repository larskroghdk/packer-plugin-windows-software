# Security practices

Follow [project constraints](../architecture/overview.md) and the [project architecture](../architecture/overview.md). Preserve the plugin's read-only, servicing, deletion, installation or rollback boundaries as applicable.

Never weaken WinRM, deletion-root checks, installer SHA-256/Authenticode trust, credential redaction or baseline provenance to pass a test. Treat downloads as data. Pass guest data through existing structured contracts instead of command interpolation.

Keep private keys and credentials out of source, reports and artifacts. Pin Actions and restrict write permissions to publication jobs. Publishing plugin binaries does not authorize redistribution of vendor installers or live guest operations.
