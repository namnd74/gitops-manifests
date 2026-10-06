# Portable local GitOps implementation plan

**Goal:** Run backend, k3d, Sealed Secrets and Argo CD locally from main without personal account paths, remote credentials or environment branches.

**Architecture:** A configurable local launcher creates a separate k3d cluster, builds/imports a native image, seals cluster-specific secrets into ignored runtime manifests, commits them to an ignored local main repository and serves it read-only inside Kubernetes. Three Argo Applications track main with separate overlays. Optional hosted CI remains explicit and parameterized.

**Constraints:** Work directly on main as requested. Do not delete or modify existing remote environment branches or the running demo cluster. No private keys/passwords/token values in committed files or logs. Initial container/controller downloads need internet. Bash/Python entry points support macOS, Linux and Windows through WSL2; verify this host without claiming untested platforms.

1. Add failing behavior tests for portable configuration, generated Argo branch/overlay routing, local image identity and a real local Git snapshot excluding plaintext.
2. Implement local configuration/launcher, cluster setup, read-only Git server, generated sealed manifests, image import and acceptance checks.
3. Remove personal runtime/default identity and machine-specific documentation, parameterize hosted source/config repositories, make publication optional and main the default config branch.
4. Run script/Go/workflow checks; build and exercise the complete local lab plus a second backend update through local main.
5. Review the changes, commit on main, publish only the tested main changes and save a generic step-by-step guide.

## Verification status

Implemented local launcher, generic templates, optional hosted CI and local instructions on main. Static review completed. Filesystem/Git/Kustomize workflow tests and Go quality checks pass. Live Docker/k3d acceptance passed on macOS with Docker linux/arm64: fresh deployment, source update across all environments, restore, and repeat up with unchanged image/revision/ciphertext. Original demo cluster remains Synced/Healthy. Main publication follows these verified changes.
