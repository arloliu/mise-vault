# mise-vault experiment environment

Local Docker stack simulating the private infrastructure that mise-vault targets:

| Service | Container | URL | Purpose |
|---|---|---|---|
| Nexus 3 | `mv-nexus` | http://localhost:8081 | private artifact store (raw hosted repo `devtools`, immutable ALLOW_ONCE) |
| GitLab CE | `mv-gitlab` | http://localhost:8929 | private git hosting (`devtools/mise-vault`, token / netrc auth) |

## Usage

```bash
docker compose up -d
./scripts/provision-nexus.sh          # idempotent
./scripts/provision-gitlab.sh         # idempotent; first GitLab boot takes 3-6 min
./scripts/provision-runner.sh         # CI runner + project variables
./scripts/seed-artifacts.sh           # linux-amd64 artifacts (public internet, once)
./scripts/seed-extra-platforms.sh     # linux-arm64 + darwin-arm64 artifacts

docker build -t mise-vault-test test-image/   # workstation-like image for offline/CI tests
```

Test suites:

```bash
./scripts/poc-test          # plugin behavior matrix
./scripts/bootstrap-test    # full bootstrap flow
./scripts/offline-test      # everything again, inside a no-internet network
```

## Credentials (experiment-only, obviously not secrets)

| What | Value |
|---|---|
| Nexus admin | `admin` / `admin-mise-vault` |
| Nexus read-only | `developer` / `dev-mise-vault` |
| GitLab root | `root` / `Vq7#tKm2xRz9!pWd4s` |
| GitLab root PAT | `glpat-mise-vault-root-00001` (api) |
| GitLab developer | `developer` / `dev-mise-vault-pw1!` |
| GitLab developer PAT | `glpat-mise-vault-dev-000001` (read_api, read_repository) |

## Simulating workstation auth (~/.netrc)

```netrc
machine localhost
  login developer
  password glpat-mise-vault-dev-000001
```

Note: netrc has no port field — `localhost` matches both :8081 and :8929, which
conflates Nexus and GitLab credentials. For clean separation use distinct
hostnames (e.g. add `nexus.local` / `gitlab.local` to /etc/hosts).

## Artifact layout

```
http://localhost:8081/repository/devtools/<tool>/<version>/<artifact>
```

## Private mirror / proxy overrides

Every external fetch point is overridable — nothing requires Docker Hub or
public package indexes once mirrors exist:

| What | Override | Where |
|---|---|---|
| compose images (nexus, gitlab, runner) | `REGISTRY_PREFIX=harbor.../dockerhub-proxy/` | environment or `.env` (see `.env.example`) |
| test image base | `--build-arg BASE_IMAGE=...` | `docker build test-image/` |
| test image apt packages | `--build-arg APT_MIRROR=http://mirror.../ubuntu` | `docker build test-image/` |
| mise binary in test image | `--build-arg MISE_BINARY_URL=...` (hosted binary) or `MISE_INSTALL_URL=...` (mirrored install script) | `docker build test-image/` |
| CI job images | `PYTHON_IMAGE`, `PYTHON_SLIM_IMAGE`, `DEVTOOLS_CI_IMAGE` | GitLab CI variables |
| Go toolchain for checksum CI | ship go inside `PYTHON_IMAGE` (the job's apt fallback is skipped when the image already has `go`) | GitLab CI variable |
| CI pip packages | `PIP_INDEX_URL` | GitLab CI variable (pip reads it natively) |
| runner default job image | `DEFAULT_JOB_IMAGE=...` | env for `provision-runner.sh` |
| seed scripts (public intake simulation) | standard `http_proxy`/`https_proxy`/`no_proxy` | environment (curl and python urllib honor them) |

## Teardown

```bash
docker compose down          # keep data
docker compose down -v       # wipe everything
```
