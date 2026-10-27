# Security

Please report security vulnerabilities privately through [GitHub's vulnerability reporting form](https://github.com/lucasaarch/Spark/security/advisories/new). Do not post credentials, exploit details, or private terminal output in a public issue.

Include the affected version or commit, reproduction steps, impact, and a minimal example with synthetic data. Fixes target the latest development branch and subsequent releases.

Spark runs local shell processes with your user account's permissions. Terminal output, links, and agent status reports are untrusted input. Agent status and usage are display hints, not authenticated process identities or authorization to execute commands.
