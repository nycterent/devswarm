# Self-Distributing Swarm

This repository is part of a self-distributing swarm.

## What is this?

A self-distributing swarm is a repository that:
- Automatically replicates via Git's fork mechanism
- Maintains its own health and topology
- Requires zero infrastructure (uses github's features)
- Is censorship-resistant (must delete ALL forks)

## How it works

1. **Fork = Replication**: Each fork is a complete copy
2. **CI/CD = Coordination**: Automated sync every 6 hours
3. **Git = Consensus**: Merge conflicts resolved via git
4. **API = Discovery**: Platform API discovers all forks

## Join the swarm

```bash
# Fork this repo (or click the Fork button)
# Your fork automatically becomes part of the swarm
# CI/CD runs automatically to sync with the network
```

## Swarm Health

Check `.swarm/manifest.json` for current topology:
- **Healthy**: 10+ forks
- **Stable**: 6-9 forks  
- **Vulnerable**: 3-5 forks
- **Degraded**: <3 forks

## Philosophy

Based on the [Unhosted](https://unhosted.org) philosophy:
- Users own their copies (via fork)
- No central server required
- Platform-agnostic (works on any Git forge)
- Consent-based participation (you choose to fork)

## Platform: github

This swarm is currently running on github but can migrate to any Git forge.

---

**By forking this repo, you're already participating in the swarm.** 🐝
