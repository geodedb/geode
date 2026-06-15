# docs/internal/ — CONFIDENTIAL, NOT FOR OPEN-SOURCE RELEASE

> ⚠️ **Everything in this directory is internal CodePros operational
> documentation.** It references private infrastructure (the `arda` cluster, the
> corporate Vault `pki.devnw.com`, `*.geodedb.com`, ArgoCD app names, Vault
> roles/paths) and the hard-won operational learnings from running geode in our
> environment.
>
> **This directory MUST be excluded from any public / open-source fork or
> release of geode.** When publishing geode (crates.io / npm / PyPI / public
> mirror), strip `docs/internal/` first (add it to the open-source sanitizer's
> exclude list, or `git rm -r docs/internal` on the public branch).
>
> The rest of the geode project is Apache-2.0. These files are not.

## Contents

- [`K8S_RAFT_CLUSTER_DEPLOYMENT.md`](K8S_RAFT_CLUSTER_DEPLOYMENT.md) — runbook for
  deploying and operating the 3-node Raft cluster on Kubernetes (arda), with the
  full catalogue of deployment gotchas learned bringing the cluster to
  production-eligible state in `v0.7.0`.
