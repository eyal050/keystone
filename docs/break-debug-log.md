# Break/Debug Log

Per [CLAUDE.md §8](../CLAUDE.md), each Keystone session ends with either:

1. A new entry below describing a failure that was injected, diagnosed, and fixed, **or**
2. A note that no break/debug was practiced this session, and why.

## Catalog of seeded scenarios

Starting material from CLAUDE.md §8 — usable once the platform has enough
surface to break:

- Policy denies a deployment that should succeed.
- `DeployIfNotExists` policy is missing its managed identity role assignment → silent non-compliance.
- Private DNS zone linked to wrong VNet → private endpoint resolves to a public IP from the spoke.
- Spoke peered to hub but UDR missing → traffic skips the firewall, NSG blocks it, looks like a firewall problem.
- Custom RBAC role missing one `Microsoft.X/Y/read` permission → cryptic 403.
- APIM private endpoint approved on storage, but DNS record still points to the public FQDN.

## Entry template

> **Date**:
> **Scenario**:
> **Symptom (what Eyal saw first)**:
> **Hypothesis path**:
> **Root cause**:
> **Fix**:
> **Signal Eyal should have looked at first**:

## Entries

### Session 0 — repo bootstrap, no infrastructure

No break/debug practiced — there is nothing deployed to break. The
catalog above is seeded; the first real entry will land once at least
`platform/00-bootstrap` and the Management subscription are up.
