# Publication Checklist

Use this checklist before adding or promoting a utility.

## Current Safety Gate

- The utility is read-only.
- The utility only inspects, reports, audits, or diagnoses state.
- The utility does not modify local systems, remote systems, Kubernetes objects, storage systems, DNS configuration, network state, infrastructure state, or application state.
- The utility does not delete, restart, patch, cordon, uncordon, drain, attach, detach, format, mount, unmount, resize, remediate, or clean up anything.
- Utilities that change state are out of scope for publication at this stage, even if they support `--dry-run`.

## Security

- No credentials, tokens, kubeconfigs, SSH keys, or certificates are present.
- No internal names, domains, IPs, hostnames, usernames, paths, or cluster names are present.
- No sensitive sample output is included.
- No comments reveal internal architecture, incidents, vulnerabilities, or procedures.

## Ownership

- The utility has been classified as personal, work-inspired, or employer-owned.
- Work-inspired code was clean-room rewritten when appropriate.
- Anything employer-owned or proprietary is excluded unless written approval exists.

## Engineering

- Inputs are validated.
- Required dependencies are checked.
- Errors are understandable.
- Exit codes are meaningful.
- Behavior is read-only, not merely read-only by default.
- Any state-changing behavior results in `DO NOT PUBLISH` for now.
- Shell scripts quote variables and pass `shellcheck` where practical.
- Python scripts use lightweight CLI handling and avoid unnecessary dependencies.

## Documentation

- Purpose is explained.
- Requirements are listed.
- Usage examples use synthetic infrastructure.
- Output is documented with sanitized examples.
- Exit codes are documented when meaningful.
- Safety behavior is explicit.
- Limitations are stated.
- Tested environments are listed only when actually tested.

## Testing

- Bash syntax validation or `shellcheck` is run when applicable.
- Python tests or CLI checks are present when useful.
- Kubernetes tools use fixture data where practical.
- No test requires a live production environment.

## Publication Assessment

Record one of:

- `READY`
- `READY WITH CHANGES`
- `HUMAN REVIEW REQUIRED`
- `DO NOT PUBLISH`
