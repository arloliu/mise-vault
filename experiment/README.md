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
./scripts/poc-test.sh          # plugin behavior matrix
./scripts/bootstrap-test.sh    # full bootstrap flow
./scripts/offline-test.sh      # everything again, inside a no-internet network
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

## Teardown

```bash
docker compose down          # keep data
docker compose down -v       # wipe everything
```
