# Safe-Guard Claude Plugin Marketplace

Internal marketplace for Safe-Guard Claude plugins. Teammates add it once, then install
plugins in one click.

## For teammates — add the marketplace, then install Emory

In Claude Code:

```
/plugin marketplace add sgicloud/sg-marketplace
/plugin install emory@safe-guard
```

(Replace `sgicloud/sg-marketplace` with the repo path this ends up at.)

Then just say **"run Emory"** — or open an API-support SR and say **"run Emory on this."**

## Plugins

| Plugin | What it does |
|---|---|
| **emory** | API-support triage agent — routes EAS vs Legacy, runs five read-only config checks, returns a verdict + prefilled SR summary. See `emory-plugin/README.md` and `emory-plugin/CONNECTORS.md`. |

## Maintainers — publish / update

This repo is the marketplace. `.claude-plugin/marketplace.json` lists the plugins; each
plugin lives in its own folder (`emory-plugin/`).

To update Emory: refresh `emory-plugin/skills/emory/SKILL.md`, bump the version in
`emory-plugin/.claude-plugin/plugin.json`, commit, and push. Installed users pick up the
new version on `/plugin update`.
