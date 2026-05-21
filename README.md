# Keystone

A personal Azure lab for building hands-on fluency with Microsoft Cloud
Adoption Framework (CAF) Enterprise-Scale Landing Zones in Terraform.

**Keystone** is the platform: management group hierarchy, Azure Policy,
hub-spoke networking, centralized logging, custom RBAC, and MCA-based
subscription vending.

**ReelHouse** is a minimal video-sharing workload that runs on top of
Keystone as an Application Landing Zone tenant. ReelHouse exists to
justify Keystone — it is not the point of the project.

## Status

**In active development — pre-public.** This repo is private until the
going-public checklist in [`CLAUDE.md` §6](CLAUDE.md) is run end-to-end.

## Local setup

```bash
mkdir -p ~/.keystone && chmod 700 ~/.keystone
cp secrets.example.env ~/.keystone/secrets.env
chmod 600 ~/.keystone/secrets.env
# Fill in real values per docs/secrets-inventory.md
source ~/.keystone/secrets.env
```

## Documentation

- [`CLAUDE.md`](CLAUDE.md) — authoritative operating contract. Read first.
- [`docs/secrets-inventory.md`](docs/secrets-inventory.md) — every sensitive value the project needs and how to retrieve it.
