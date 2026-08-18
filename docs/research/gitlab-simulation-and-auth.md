# GitLab Simulation & Git/HTTP Auth for mise-vault PoC

Research to determine how to simulate a private, auth-required GitLab locally (via Docker) to test:

(a) `mise plugin install vault https://gitlab.company.example/devtools/mise-vault.git` (b) authenticated raw-file fetch (`install.sh`) via a user token or `~/.netrc`, never embedded credentials

**Date**: 2026-08-18

**Primary sources used**: docs.gitlab.com, git-scm.com, github.com/git/git (source), github.com/jdx/mise (source + docs.mise.jdx.dev), github.com/version-fox/vfox (source, via pkg.go.dev), docs.gitea.com, curl.se, hub.docker.com, github.com/GitoxideLabs/gitoxide (issue tracker, for a documented gix limitation).

---

## Question 1 — How mise fetches plugins

mise shells out to neither "always the git CLI" nor "always libgit2".
It has two code paths, and the default one is neither of those things.
The clone/fetch logic lives in `src/git.rs` (source: `https://github.com/jdx/mise/blob/main/src/git.rs`).

```rust
if Settings::get().libgit2 || Settings::get().gix {
    // clone with gix (gitoxide) — a pure-Rust git reimplementation
    let mut prepare_clone = gix::prepare_clone(url, &self.dir)?;
    ...
}
// else: shell out to the real `git` binary
let mut cmd = sanitize_git_cmd_runner(
    CmdLineRunner::new("git").arg("clone").arg("-q") ...
);
cmd.execute()?;
```
(source: `src/git.rs`, `Git::clone`)

Two settings gate this, both **default to `true`**.
The branch is an `OR`, so by default the `gix` path is always taken:

```toml
[gix]
default = true
description = "Use gix for git operations, set to false to shell out to git."
env = "MISE_GIX"

[libgit2]
default = true
description = "Use libgit2 for git operations, set to false to shell out to git."
env = "MISE_LIBGIT2"
```
(source: `https://raw.githubusercontent.com/jdx/mise/main/settings.toml`, `[gix]` / `[libgit2]` blocks)

Despite the setting being named `libgit2`, the code does **not** use the `git2` crate (libgit2 bindings) at all.
Both `gix` and `libgit2=true` route to the same `gix::prepare_clone` call.
"libgit2" appears to be a legacy name kept for backward-compatible env-var/CLI-flag naming after mise migrated from git2 to gix.
Functionally today there are only two paths: **gix** (default) and **real git CLI** (only when *both* settings are set `false`).

(empirical, verified locally on 2026-08-18): `mise --version` → `2026.8.8`; `mise settings get gix` → `true`; `mise settings get libgit2` → `true`.
So on a stock install, `mise plugin install <name> <git-url>` clones via gix, not via the `git` binary.

This matters enormously for auth, because mise's `gix` build does not use libcurl.
`Cargo.toml` enables gix's HTTP transport via the `reqwest` backend, not the `curl` backend:

```toml
gix = { version = "<1", features = ["worktree-mutation"] }
...
"gix/blocking-http-transport-reqwest-native-tls",
"reqwest/native-tls",
...
"gix/blocking-http-transport-reqwest-rust-tls",
"reqwest/rustls",
```
(source: `https://raw.githubusercontent.com/jdx/mise/main/Cargo.toml`)

`reqwest` has no built-in `.netrc` support and is not the same authentication pipeline as the real `git` CLI (which links against libcurl and gets netrc "for free", see Question 6). gix does ship a separate `gix-credentials` crate that can invoke external git credential helpers (i.e. it can run `git credential fill`), but this is a distinct, narrower code path than libcurl's own auth handling, and it has had real behavioral divergence from git: gitoxide issue `https://github.com/GitoxideLabs/gitoxide/issues/1284` ("Gix doesn't call the credentials helper properly", filed against gitoxide v0.33.0, closed) documents gix invoking a configured `credential.helper` twice instead of once, and not surfacing the remote's auth-failure message the way git does.
A search of the current `gix-credentials` source turned up no netrc handling at all — consistent with the reqwest-based, non-libcurl transport.

**Practical implication**: to get "standard git auth just works" behavior (credential helpers, `~/.netrc` via libcurl, HTTPS token URLs) for `mise plugin install`, you must force the real git CLI path:

```
MISE_GIX=false MISE_LIBGIT2=false mise plugin install vault https://gitlab.company.example/devtools/mise-vault.git
```

or set `gix = false` / `libgit2 = false` in `~/.config/mise/config.toml` under `[settings]`.
Left at defaults, the PoC is testing gix+reqwest auth behavior, which is a materially different (and less proven) code path than plain git.

### Separate auth layer for the `gitlab:` backend (not relevant to `mise plugin install`)

mise also ships a dedicated token-resolution system for its `gitlab:<owner>/<repo>` tool-backend shorthand (used to fetch releases via the GitLab API), configured via `gitlab.credential_command`, `gitlab.glab_cli_tokens`, and `gitlab.use_git_credentials` (source: `settings.toml`, `[gitlab.*]` blocks).
This is **not** the code path used by `mise plugin install <name> <git-url>` — that command takes a literal git URL and goes straight into `Git::clone`.
Don't confuse the two when reading mise's docs/source: `gitlab:` backend auth and plugin-install git auth are unrelated subsystems.

### Ref pinning

`mise plugins install <name> <git-url>#<ref>` — the URL and ref are split on `#`:

```rust
pub fn split_url_and_ref(url: &str) -> (String, Option<String>) {
    match url.split_once('#') {
        Some((url, _ref)) => (url.to_string(), Some(_ref.to_string())),
        None => (url.to_string(), None),
    }
}
```
(source: `src/git.rs`, `Git::split_url_and_ref`)

The documented example is `mise plugins install poetry https://github.com/mise-plugins/mise-poetry.git#11d0c1e` (source: `src/cli/plugins/install.rs`, `AFTER_LONG_HELP`).
Internally, `CloneOptions` carries either a `branch` (tag/branch name, passed to `git clone -b <branch> --single-branch` or gix's `with_ref_name`) or a `revision` (an arbitrary commit-ish, including abbreviated SHAs).
A SHA can't be passed to `git clone -b` or to gix's ref-name-only API, so mise instead does a full clone and then an explicit `git checkout --force <sha>` (source: `src/git.rs`, `CloneOptions`, `Git::clone`, `Git::checkout`).
`update_ref` (used for subsequent `mise plugins update`) does an explicit `git fetch --prune --update-head-ok origin <refspec>` followed by `checkout --force`.

---

## Question 2 — Git-over-HTTPS auth options with GitLab

All forms below are drawn from GitLab's own docs at `https://docs.gitlab.com/user/profile/personal_access_tokens/`, `https://docs.gitlab.com/user/project/deploy_tokens/`, `https://docs.gitlab.com/ci/jobs/ci_job_token/`, and `https://docs.gitlab.com/topics/git/clone/`.

**(a) Personal access token, `oauth2` convention:**
```
git clone https://oauth2:<your_access_token>@gitlab.example.com/gitlab-org/gitlab.git
```
GitLab's PAT docs give this exact example.
Note: **"the username can be any non-empty string value; GitLab does not validate it"** — `oauth2` is convention (traditionally meaning "this credential is a token, not a real GitLab username"), not a hard requirement for a plain PAT.
GitLab's docs also show the equivalent `https://<username>:<personal_token>@gitlab.com/...` form.
Required scope: `read_repository` (or `write_repository` for push) — GitLab's clone docs (`topics/git/clone/`) list personal/deploy/project/group access tokens as the options for HTTPS clone auth, each needing a `read_repository`/`write_repository` scope.

**(b) CI job token:**
```
git clone https://gitlab-ci-token:${CI_JOB_TOKEN}@gitlab.example.com/<namespace>/<project>
```
(source: `https://docs.gitlab.com/ci/jobs/ci_job_token/`).
Only valid inside a running CI/CD job — `CI_JOB_TOKEN` is minted per-job and revoked when the job ends, and it inherits the triggering user's access but scoped down.
Not usable for a one-time developer/machine bootstrap.

**(c) Deploy tokens:**
```
git clone https://<deploy-user>:<deploy-token>@gitlab.example.com/tanuki/awesome_project.git
```
(source: `https://docs.gitlab.com/user/project/deploy_tokens/`).
Default username is `gitlab+deploy-token-{n}` unless a custom username is set at creation time.
Scopes include `read_repository` ("Read-only access to the repository using `git clone`"), plus registry scopes.
Requires Maintainer/Owner (project) or Owner (group) to create.
Explicitly documented: **"Deploy tokens do not support SSH authentication"** — HTTP(S) only, which fits this PoC.
Deploy tokens are the right tool when you want a credential scoped to *one repo*, decoupled from any human account, and revocable independently — a good fit for a CI/bootstrap identity, less so for an interactive developer's personal machine.

**(d) `~/.netrc`:**
```
machine gitlab.company.example
login <user-or-any-string>
password <PAT-or-deploy-token>
```
This is not documented by GitLab itself (their docs don't mention netrc), but it works because git's HTTPS transport is built on libcurl, and libcurl (when driven by the real `git` CLI, not mise's default gix path — see Question 1) is configured by git to try `~/.netrc` automatically.
See Question 6 for the exact source citation.

**(e) Credential helpers:**
```
git config --global credential.helper store
```
Then the first authenticated operation prompts once and git persists username + password/token to `~/.git-credentials` (or `$XDG_CONFIG_HOME/git/credentials`) in **cleartext** — git's own docs warn: *"Using this helper will store your passwords unencrypted on disk, protected only by filesystem permissions"* (source: `https://github.com/git/git/blob/master/Documentation/git-credential-store.adoc`).
OS-keychain-backed helpers (`git-credential-manager`, macOS Keychain, etc.) avoid the cleartext-on-disk problem but add a dependency outside what a minimal Docker-based PoC needs.

**(f) `insteadOf` URL rewriting:**
```
git config --global url."https://oauth2:TOKEN@gitlab.company.example/".insteadOf "https://gitlab.company.example/"
```
Git's own docs: *"Any URL that starts with this value will be rewritten to start, instead, with `<base>`...
When more than one insteadOf strings match a given URL, the longest match is used"* (source: `https://github.com/git/git/blob/main/Documentation/config/url.adoc`).
This centralizes the token in one place (`~/.gitconfig`) rather than duplicating it into every clone URL, and it's transparent to callers who invoke plain `https://gitlab.company.example/...` URLs — including `mise plugin install`, since mise passes the URL through unmodified to whichever git backend it uses.

**Caveat for this PoC**: `insteadOf` rewriting is a `gix-config`-level feature, and gitoxide's own issue tracker shows it was tracked as an outstanding TODO in gix's config/URL-rewrite handling (`https://github.com/GitoxideLabs/gitoxide/issues/450`, "don't forget about url.base.insteadOf and pushInsteadOf").
Whether the version of gix vendored in mise's current release honors `insteadOf` was **not verified against current gix behavior** — treat this as unverified for mise's default (gix) code path and confirm empirically before relying on it; it's known-solid only via the real `git` CLI.

### Which is most appropriate for "bootstrap once per machine"?

**`~/.netrc`** for the raw-HTTP part (curl/install.sh, since it maps 1:1 onto the PoC's stated requirement of "token or `~/.netrc`, never embedded credentials"), plus either **`~/.netrc`** or **`credential.helper store`** for the `git clone` part, *provided mise is forced onto the real git CLI path* (`MISE_GIX=false MISE_LIBGIT2=false`, see Question 1).
Reasoning:

- Neither netrc nor a credential helper writes a token into any repo's `.git/config` or into the remote URL shown by `git remote -v` — satisfying "never embedded credentials."
- netrc requires zero git configuration and is a single flat file, which is easy to template/generate for CI or onboarding scripts.
- `insteadOf` is attractive (one config line covers every repo on the host) but still embeds the token in plaintext, just in `~/.gitconfig` instead of `.git/config` — same security tradeoff, one level up — and it's the option with an open question mark against mise's default gix transport.
- Deploy tokens or `oauth2:<PAT>@` embedded directly in the remote URL (option a/c used as a literal clone argument, not via netrc/insteadOf) get persisted in plaintext inside `.git/config` the moment `git clone` runs — this is explicitly what the PoC wants to avoid.

**Security tradeoff common to (a)/(c)/(f)/(e-store)**: all of them ultimately store the credential in cleartext somewhere on disk (`.git/config`, `~/.gitconfig`, `~/.git-credentials`, or `~/.netrc`), protected only by filesystem permissions.
None of GitLab's or git's HTTPS auth options avoid this without adding an OS keychain-backed helper.
`~/.netrc` at least keeps the blast radius to one well-known, `chmod 600`-able file that's easy to audit and rotate.

---

## Question 3 — Raw file fetch auth

Working forms for `curl https://gitlab.company.example/<namespace>/<project>/-/raw/v1.0.0/install.sh`:

- **`PRIVATE-TOKEN` header** (GitLab's recommended method):
  ```
  curl --header "PRIVATE-TOKEN: <your_access_token>" \
    --url "https://gitlab.example.com/api/v4/projects/13083/repository/files/app%2Fmodels%2Fkey%2Erb/raw?ref=main"
  ```
  (source: `https://docs.gitlab.com/api/repository_files/`).
  GitLab's REST-auth docs state: *"Pass the token using the `PRIVATE-TOKEN` header (recommended) or other methods"* (source: `https://docs.gitlab.com/api/rest/authentication/`).

- **Query parameter** (`?private_token=<PAT>` or `?access_token=<OAuth-token>`): supported per the same authentication doc, but query-string tokens land in server access logs, browser history, and shell history — avoid for anything beyond throwaway local testing.

- **`curl -n` / `--netrc`**: works against the plain `-/raw/<ref>/<path>` web endpoint (which is a normal HTTP Basic-auth-capable path when the project is private and GitLab prompts for credentials) the same way any HTTP Basic-auth endpoint honors netrc — curl reads matching `machine`/`login`/`password` and supplies them as Basic auth on 401.
  This is **not GitLab-specific** behavior; it's generic curl netrc handling (see Question 6) and it requires the explicit `-n`/`--netrc` flag — curl does not read `~/.netrc` by default (verified against curl's own docs, see Question 6).

- **CI job token**: `--header "JOB-TOKEN: $CI_JOB_TOKEN"` works for "specific API endpoints" per GitLab's job-token docs — scoped to CI runs, not for the machine-bootstrap scenario.

### Repository Files API — the more robust option for `install.sh`

```
GET /api/v4/projects/:id/repository/files/:file_path/raw?ref=<tag-or-branch-or-sha>
```
Parameters: `id` (numeric project ID or URL-encoded `namespace%2Fproject` path), `file_path` (URL-encoded, e.g.
`install%2Esh`), `ref` (defaults to the project's default branch if omitted), `lfs` (optional, fetch LFS pointer target instead of pointer file).
Auth: `PRIVATE-TOKEN` header (any PAT/project/group access token with at least `read_repository`), `Authorization: Bearer <oauth-token>`, or `JOB-TOKEN` for CI.
This is preferable to the `-/raw/` web URL for a bootstrap script because it's a stable, versioned, documented API surface rather than the web UI's raw-file route, and it composes cleanly with GitLab's standard `PRIVATE-TOKEN` header pattern — the same header/token you'd already be using for git auth via `oauth2:<PAT>@`.

---

## Question 4 — GitLab CE in Docker

**Resource requirements** (source: `https://docs.gitlab.com/install/requirements/`): baseline single-node installation is **8 vCPU / 16 GB RAM**.
GitLab also documents a reduced-footprint mode: *"For single-node installations in memory-constrained environments, GitLab can run with at least 8 GB of memory."* A separate, more aggressive page, `https://docs.gitlab.com/omnibus/settings/memory_constrained_envs/`, gives an official floor: *"Minimum 2 GB of RAM + 1 GB of SWAP, optimally 2.5 GB of RAM + 1 GB of swap"*, achieved by disabling Puma clustering (`puma['worker_processes'] = 0`), reducing Sidekiq concurrency, disabling Prometheus monitoring, and tuning `gitaly['configuration']` concurrency limits:

```ruby
puma['worker_processes'] = 0
sidekiq['concurrency'] = 10
prometheus_monitoring['enable'] = false
gitlab_rails['env'] = { 'MALLOC_CONF' => 'dirty_decay_ms:1000,muzzy_decay_ms:1000' }
gitaly['configuration'] = {
  concurrency: [
    { 'rpc' => "/gitaly.SmartHTTPService/PostReceivePack", 'max_per_repo' => 3 },
    { 'rpc' => "/gitaly.SSHService/SSHUploadPack", 'max_per_repo' => 3 },
  ],
}
gitaly['env'] = {
  'MALLOC_CONF' => 'dirty_decay_ms:1000,muzzy_decay_ms:1000',
  'GITALY_COMMAND_SPAWN_MAX_PARALLEL' => '2'
}
```
GitLab's own caveat: *"you may experience unexpected degradation of both product functionality and performance"* at this floor.
A safer laptop-practical target is ~4 GB RAM / 2-4 vCPU with the above tuning — still below the 16 GB baseline but above GitLab's documented absolute floor.

**Startup time**: no official number found in docs.gitlab.com, but GitLab's own issue tracker documents that health-check endpoints report OK *before* the internal `gitlab-ctl reconfigure` (Chef-based) run has actually finished (`https://gitlab.com/gitlab-org/gitlab/-/issues/207599`, "Health check endpoints report OK status before gitlab is reconfigured on startup") — meaning a container-orchestration healthcheck alone is not a reliable "ready" signal; plan for polling `docker logs` for `gitlab Reconfigured!` and then an additional grace period, not just a TCP/HTTP probe.

**docker-compose** (source: `https://docs.gitlab.com/install/docker/installation/`), non-standard-port variant (443 kept for TLS/registry use but HTTP moved to 8929):
```yaml
services:
  gitlab:
    image: gitlab/gitlab-ce:<version>-ce.0
    container_name: gitlab
    restart: always
    hostname: 'gitlab.example.com'
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'http://gitlab.example.com:8929'
        gitlab_rails['gitlab_shell_ssh_port'] = 2424
    ports:
      - '8929:8929'
      - '443:443'
      - '2424:22'
    volumes:
      - '$GITLAB_HOME/config:/etc/gitlab'
      - '$GITLAB_HOME/logs:/var/log/gitlab'
      - '$GITLAB_HOME/data:/var/opt/gitlab'
    shm_size: '256m'
```
(Docker Hub page `https://hub.docker.com/r/gitlab/gitlab-ce` defers to this same docs.gitlab.com page for the authoritative compose example.)

**Initial root password**: GitLab writes a randomly generated root password to `/etc/gitlab/initial_root_password` inside the container, valid for **24 hours** before the file is auto-removed.
To pin it instead, pass `GITLAB_ROOT_PASSWORD=<password>` (and optionally `GITLAB_ROOT_EMAIL=...`) as environment variables at first boot (documented in GitLab's Linux-package install docs, e.g.
`https://docs.gitlab.com/install/package/ubuntu/`); setting `gitlab_rails['initial_root_password']` directly in `gitlab.rb` is explicitly called out as not recommended, since it leaves the password in cleartext config.

**Non-interactive project + token creation**: the cleanest bootstrap is `gitlab-rails runner`, run once via `docker exec`, since it doesn't require an existing token (breaking the chicken-and-egg problem of the PAT API):
```
docker exec -it gitlab gitlab-rails runner "
  token = User.find_by_username('root').personal_access_tokens.create(
    scopes: [:api, :read_repository, :write_repository],
    name: 'mise-vault-poc'
  )
  token.set_token('glpat-poc-token-0000000000')
  token.save!
"
```
(pattern confirmed via GitLab's own forum thread on Rails-runner token creation and the Personal Access Tokens API docs; token value must be 20+ chars and scopes must be valid).
Once you have *one* token this way, subsequent tokens/projects can be created through the ordinary REST API:
```
curl --request POST --header "PRIVATE-TOKEN: <token>" \
  --data '{"name":"mise-vault","visibility":"private"}' \
  --url "https://gitlab.example.com/api/v4/projects"
```
(source: `https://docs.gitlab.com/api/projects/`, adapted from the documented request shape — GitLab's `PRIVATE-TOKEN`/JSON POST convention is consistent across their API docs, though the exact `POST /projects` curl block was not directly visible in the fetched page excerpt; treat the JSON body as representative, verify field names against the live docs page before scripting).
`gitlab-rails runner` can equally script project + membership creation (`Project.create!`, etc.) if you want to avoid the token bootstrap step entirely.

**Practicality assessment for a laptop PoC**: workable but heavy.
Even at the memory-constrained floor (2-4 GB), GitLab CE brings Puma, Sidekiq, PostgreSQL, Redis, Gitaly, and (unless disabled) Prometheus as one monolithic container, with multi-minute reconfigure on first boot and a non-trivial image pull.
It is the right target for a **final validation pass** against the real product, but too slow/heavy for iterate-fix-iterate development of the plugin's auth code.

---

## Question 5 — Lighter stand-ins

### (a) Gitea

Gitea's own docs describe it as designed to be lightweight: *"One of Gitea's design goals is to be lightweight and fast in response"*, *"A Raspberry Pi 3 is powerful enough to run Gitea for small workloads"*, *"2 CPU cores and 1GB RAM is typically sufficient for small teams/projects"* (source: `https://docs.gitea.com/`).

Docker Compose (source: `https://docs.gitea.com/installation/install-with-docker`):
```yaml
services:
  server:
    image: docker.gitea.com/gitea:1.27.2
    container_name: gitea
    environment:
      - USER_UID=1000
      - USER_GID=1000
    restart: always
    volumes:
      - ./gitea:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "3000:3000"
      - "222:22"
```

**Clone auth semantics**: HTTPS clone with a token works as `https://<token>:x-oauth-basic@gitea.domain.example/owner/repo.git` (documented community pattern for Gitea's OAuth2/token Basic-auth handling; there have been version-specific compatibility issues reported upstream, e.g.
`https://github.com/go-gitea/gitea/issues/10903` and `https://github.com/go-gitea/gitea/issues/2480`, so pin a recent Gitea version and verify the exact accepted username string empirically against the image you deploy).
`~/.netrc` works the same way it does for any git-over-libcurl HTTPS remote (community-documented pattern, consistent with git's generic netrc/libcurl behavior from Question 6 — Gitea doesn't need to do anything special for this since it's the *client's* transport, not the server, that consults netrc).

**Raw file URL**: `GET /:owner/:repo/raw/:branch/:path`, e.g.
`http://localhost:3000/gflorent/test-repo/raw/branch/master/as1_pe_203.stp` (pattern shown in Gitea community references derived from the API's `/repos/:owner/:repo/raw/:branch/:path` route); `?raw=1` on the normal `/src/` blob-view URL redirects to the same raw route (GitHub-compatible convenience alias).

**Scripting user/repo/token creation** (source: `https://docs.gitea.com/administration/command-line` and `https://docs.gitea.com/development/api-usage`):
```
gitea admin user create --username poc --password <pw> --email poc@example.com --admin
gitea admin user generate-access-token --username poc --token-name mise-vault-poc --scopes write:repository
```
API auth for scripting further steps (e.g. repo creation via `POST /api/v1/user/repos`): Authorization header `token <token>` ("for historical reasons", per Gitea's API-usage docs — note it's the literal word `token`, not `Bearer`) or Basic auth with the token as username/password for the token-generation endpoint itself, which "requires you to authenticate using BasicAuth and a password."

### (b) Plain git smart HTTP (`git-http-backend`)

`git-http-backend` is a CGI program (ships with git) implementing the smart HTTP protocol; deployment is "front it with a CGI-capable web server that also does auth" (source: `https://git-scm.com/docs/git-http-backend`).
Minimal Apache sketch from git's own docs, adapted with Basic auth for all access:
```apache
SetEnv GIT_PROJECT_ROOT /var/www/git
SetEnv GIT_HTTP_EXPORT_ALL
ScriptAlias /git/ /usr/libexec/git-core/git-http-backend/

<LocationMatch "^/git/">
    AuthType Basic
    AuthName "Git Access"
    AuthUserFile /etc/git-htpasswd
    Require valid-user
</LocationMatch>
```
(sketch combines git's documented `ScriptAlias`/`SetEnv` block with git's documented `AuthType Basic` `LocationMatch` pattern for gating access — git's docs show the auth block for gating *push* specifically via a `RewriteCond` on `service=git-receive-pack`; gating all access, as above, is the simpler config for a read-mostly PoC target).
`git-http-backend` itself has effectively zero footprint beyond the git installation already on the box — this is the cheapest possible stand-in, at the cost of having no web UI, no user/token model (you manage `htpasswd` entries by hand or script), and no raw-file API — it only serves the smart-HTTP git protocol, not a `/raw/` file endpoint, so it does **not** cover Question 3/7 (raw file / Lua http fetch) on its own; pair it with a plain static-file location block (nginx `location /raw/ { auth_basic ...; alias /var/www/repo-files/; }`) if you need a raw-file target too.

### (c) GitLab's own guidance on minimal footprint

Already covered under Question 4: GitLab documents an official memory-constrained configuration (`docs.gitlab.com/omnibus/settings/memory_constrained_envs/`) with an explicit 2 GB RAM + 1 GB swap floor, but GitLab does **not** publish a "tiny test instance" Docker Compose variant distinct from the standard Omnibus image — the memory-constrained settings are `gitlab.rb`/`GITLAB_OMNIBUS_CONFIG` tuning on top of the same monolithic image, not a lighter alternative image.

### Recommendation

- **Fast-iteration phase** (writing/debugging the plugin's git-clone and raw-file-fetch auth code): **Gitea in Docker**.
  Starts in seconds, ~1 GB RAM, supports token-based HTTPS clone and a raw-file HTTP route, scriptable end-to-end via `gitea admin user create` / `generate-access-token` and the REST API — closest fidelity-per-cost match to what the PoC actually exercises.
- **Cheapest possible / protocol-only sanity checks**: `git-http-backend` behind nginx/Apache with `htpasswd` Basic auth, when you only need to validate git-over-HTTPS-with-credentials mechanics (e.g. does mise's gix-vs-git-CLI path actually send the Basic auth header) without needing a real GitLab-like project model.
- **Final validation pass**: real `gitlab/gitlab-ce` in Docker, once, before shipping — to catch GitLab-specific behavior Gitea/git-http-backend can't reproduce (GitLab's specific PAT/deploy-token scope model, `PRIVATE-TOKEN` header semantics, the Repository Files API, CI job tokens, 2FA interactions).

---

## Question 6 — netrc specifics

**File format** (per curl's own docs, `https://raw.githubusercontent.com/curl/curl/master/docs/libcurl/opts/CURLOPT_NETRC.md`, and general netrc convention):
```
machine <hostname>
login <username>
password <password-or-token>
```
No port field exists in the format — see below.
Curl's doc explicitly says: *"Only machine name, username and password are taken into account (init macros and similar things are not supported)"* and *"The netrc file provides credentials for a hostname independent of which [protocol and port]..."* — confirming netrc is **host-only**, not host+port.

**Permissions**: `~/.netrc` should be `chmod 600` — this is the long-standing convention (many `ftp`/`curl` implementations refuse to use a netrc file that's group/world-readable); enforce it explicitly when generating one for the PoC rather than relying on default umask.

**Does curl read it automatically?** **No.** Curl's own man page is explicit: `-n, --netrc`: *"Try to read the .netrc file in the user's home directory and use login name and password from there for authentication."* Without `-n`/`--netrc` (or `--netrc-optional`), curl ignores `~/.netrc` entirely (source: curl man page, `https://curl.se/docs/manpage.html`, `--netrc`/`--netrc-optional`/`--netrc-file` entries).
So any `curl` invocation used for the raw-file fetch (Question 3) must explicitly pass `-n` (or `--netrc-optional` if you want it to silently fall back to anonymous access when no matching entry exists).

**Does git read it automatically for HTTPS?** **Yes, unconditionally, no git config needed** — but only when git's HTTPS transport is actually libcurl (i.e. the real `git` binary, not mise's default gix/reqwest path — see Question 1).
Confirmed directly in git's C source:
```c
curl_easy_setopt(result, CURLOPT_NETRC, CURL_NETRC_OPTIONAL);
```
(source: `https://github.com/git/git/blob/master/http.c`, ~line 1144).
`CURL_NETRC_OPTIONAL` means libcurl prefers credentials embedded in the URL if present, otherwise falls back to `~/.netrc` — this is set unconditionally on every libcurl handle git creates for HTTP(S), so it's not a documented git-config knob; it's baked into git's HTTP layer.
This is why git-scm.com's own `gitcredentials` doc doesn't mention netrc at all (fetched directly: no netrc content on that page) — netrc lives one layer below git's own credential-helper machinery, inside libcurl, and git's docs largely leave curl's own behavior to curl's docs.

**Non-standard-port gotcha**: since `machine` has no port component, `machine localhost` in `~/.netrc` matches **any** port on `localhost` — curl/libcurl (and therefore git, when using the real binary) match purely on hostname.
Concretely, for a GitLab test instance on `http://localhost:8929`, the netrc entry is simply:
```
machine localhost
login root
password glpat-poc-token-0000000000
```
**not** `machine localhost:8929` (that would be parsed as a literal, non-matching hostname string, since `:8929` isn't stripped/interpreted as a port by the netrc parser).
If you run multiple different local test services on different ports of the same hostname (e.g.
Gitea on 3000 and GitLab on 8929, both on `localhost`), netrc **cannot distinguish between them** — the same `machine localhost` entry (or whichever one appears first / is parsed) is used for all of them.
Recommended mitigations for the PoC: bind each test service to a distinct hostname (e.g. via `/etc/hosts` entries `gitea.local` / `gitlab.local` both pointing at 127.0.0.1) rather than distinct ports on `localhost`, or use `--netrc-file` with a purpose-built file per test scenario rather than relying on the shared `~/.netrc`.

---

## Question 7 — mise artifact download auth for backend plugins

**Yes — the Lua `http` module documented for mise backend plugins accepts an arbitrary `headers` table, so a custom `Authorization` (or `PRIVATE-TOKEN`) header can be set explicitly.** Verified directly against mise's own docs (`https://mise.jdx.dev/plugin-lua-modules.html`):

```lua
local http = require("http")

local resp, err = http.get({
    url = "https://api.github.com/repos/owner/repo/releases",
    headers = {
        ['User-Agent'] = "mise-plugin",
        ['Accept'] = "application/json"
    }
})
```
```lua
local err = http.download_file({
    url = "https://github.com/owner/repo/archive/v1.0.0.tar.gz",
    headers = {
        ['User-Agent'] = "mise-plugin"
    }
}, "/path/to/download.tar.gz")
```
`http.get`, `http.head`, and `http.download_file` all take a table with `url` and an optional `headers` table; `try_get`/`try_head`/`try_download_file` are non-raising variants with the same signature (mise docs note plain `pcall()` cannot catch errors from these async-backed calls, hence the `try_*` family). mise's docs do not show an `Authorization`-header example specifically, but the `headers` table is a plain freeform key→string map, so nothing prevents setting `['Authorization'] = 'Bearer ' .. token` or `['PRIVATE-TOKEN'] = token`.

This is corroborated independently at the vfox layer (mise's backend-plugin runtime is vfox-Lua-API-compatible), via the actual Go source's godoc on pkg.go.dev (`https://pkg.go.dev/github.com/version-fox/vfox/internal/module/http`): `Module.Get`'s doc comment reads *"Get performs a http get request @param url string @param headers table @return resp"*, and `Module.DownloadFile`'s reads *"DownloadFile performs a http get request to write stream to a file. @param url string @param headers table"* — both added as of vfox v0.2.2/v0.4.0 respectively, confirming header support has been present in the underlying module for multiple releases, not a recent addition.

**`~/.netrc` does not help here, and this needs to be stated plainly**: this HTTP module is neither curl nor git — it's a Go HTTP client exposed into Lua (vfox `internal/module/http`), invoked directly by mise's embedded Lua interpreter with no libcurl in the loop.
Nothing in that path consults `~/.netrc`.
Question 6's "git/curl read netrc automatically" finding **does not transfer** to backend plugin artifact downloads.

**Implication for mise-vault's design**: the plugin's Lua install-hook code must read the token itself and set the header explicitly, e.g.:
```lua
local http = require("http")
local env = require("env")  -- os.getenv per mise docs
local token = os.getenv("MISE_VAULT_GITLAB_TOKEN")
local resp, err = http.get({
    url = install_sh_raw_url,
    headers = { ['PRIVATE-TOKEN'] = token }
})
```
`os.getenv` is confirmed as the documented pattern for reading env vars from backend plugin Lua code (mise docs, Environment Module section: *"To read variables in Lua, use `os.getenv("MY_VAR")`"*). mise's backend-plugin-development docs (`https://mise.jdx.dev/backend-plugin-development.html`) do **not** document any built-in auth/token convention for artifact downloads — there's no `PLUGIN:GetAuthHeader` hook or config-driven header injection documented anywhere in that page.
The plugin is entirely on its own to wire a token (from an env var, or from mise's own tool-options config passed into the plugin) into the `headers` table on every `http.get`/`http.download_file` call that needs authenticated access — this is a design decision mise-vault's own Lua code needs to make, not something mise provides for free.

---

## Key risks / unknowns

1. **mise's default git-clone path (gix + reqwest) has an unverified relationship to standard git auth mechanisms.**
   Everything in Question 2 about netrc/credential-helper/insteadOf "just working" is proven true only for the real `git` CLI path (`MISE_GIX=false MISE_LIBGIT2=false`).
   Under mise's *default* settings, `mise plugin install` uses gix's own `gix-credentials` layer (which can shell out to `git credential fill`, but with documented behavioral divergence from git — gitoxide issue #1284) and gix's `insteadOf` support is not confirmed current (gitoxide issue #450 tracked it as outstanding).
   **The PoC must explicitly test both mise settings combinations** (default gix, and forced git-CLI) against whichever auth mechanism is chosen, rather than assuming git-CLI-documented behavior applies.

2. **The `oauth2:<PAT>@gitlab.../repo.git` username convention is not enforced by GitLab** — GitLab's docs say the username is unvalidated.
   This means a typo'd or wrong username silently still works as long as the password field carries a valid token, which is convenient for the PoC but also means a broken `oauth2:` prefix wouldn't surface as an obvious auth error during testing — double-check token validity independently (e.g. via a `curl --header "PRIVATE-TOKEN: ..."` API call) rather than trusting "clone succeeded" alone during debugging.

3. **`GITLAB_ROOT_PASSWORD`/`initial_root_password` bootstrap and `gitlab-rails runner` PAT creation were not empirically executed against a running container in this research** — commands are assembled from GitLab's documented patterns (forum thread + API docs) but not run end-to-end.
   Verify the exact `gitlab-rails runner` invocation (user lookup, token scope names, minimum token length) against the actual GitLab CE version pinned for the PoC before scripting it into CI, since GitLab has changed PAT internals across versions (`set_token`/scope-enum names are the parts most likely to drift).

4. **Gitea's `token:x-oauth-basic@` clone-auth string was reconstructed from community reports and GitHub issues, not a docs.gitea.com page** — several linked upstream issues report version-specific breakage of this exact pattern.
   Pin a specific, recent Gitea image tag and empirically verify the accepted username/password combination for HTTPS clone before building the PoC around it.

5. **The `git-http-backend` Apache auth sketch in Question 5(b) is a composite** of two separate blocks shown in git's own docs (the plain `ScriptAlias` setup, and a push-gating `RewriteCond`/`LocationMatch` example) — it was not tested as a single working config.
   Validate it against a real Apache (or translate to nginx `fastcgi_pass` + `auth_basic`) before treating it as load-bearing.

6. **GitLab's `POST /api/v4/projects` example body in Question 4 is inferred**, not directly quoted from a successfully fetched docs.gitlab.com code block — the page fetch returned only the GET/list documentation.
   Re-verify field names (`name`, `visibility`, etc.) against `https://docs.gitlab.com/api/projects/` directly before scripting.

7. **No empirical local test of curl/git netrc behavior was completed** — an attempt to spin up a local Python HTTP test server in this sandbox to observe `Authorization` headers with/without `-n` was killed by the sandbox's background-process controls before it could produce output.
   The netrc findings here rest entirely on curl's own docs/man page and git's `http.c` source (`CURLOPT_NETRC`), which are strong primary sources, but the "recommended experiment topology" below should include this exact test as an early, cheap validation step once real Docker containers are available.

---

## Recommended experiment topology

**Phase 1 — fast iteration (Gitea)**

```yaml
# docker-compose.yml
services:
  gitea:
    image: docker.gitea.com/gitea:1.27.2
    container_name: gitea-poc
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - GITEA__server__DOMAIN=gitea.local
      - GITEA__server__HTTP_PORT=3000
      - GITEA__server__ROOT_URL=http://gitea.local:3000/
    ports:
      - "3000:3000"
      - "2222:22"
    volumes:
      - ./gitea-data:/data
```
Add to `/etc/hosts`: `127.0.0.1 gitea.local` (avoids the plain-`localhost` netrc-port-collision problem from Question 6, and gives you a distinct `machine` name if you later add a second service).

Bootstrap (after container is up):
```
docker exec -it gitea-poc gitea admin user create \
  --username poc --password 'poc-pass-000' --email poc@example.com --admin
docker exec -it gitea-poc gitea admin user generate-access-token \
  --username poc --token-name mise-vault-poc --scopes write:repository --raw
# → capture the printed token as $GITEA_TOKEN
```
Create the `mise-vault` repo (via API, using the token above):
```
curl -X POST http://gitea.local:3000/api/v1/user/repos \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"mise-vault","private":true,"auto_init":true}'
```
Push the plugin repo content, then commit `install.sh` and tag `v1.0.0`.

`~/.netrc`:
```
machine gitea.local
login poc
password <GITEA_TOKEN>
```
`chmod 600 ~/.netrc`.

Test matrix to run in Phase 1:
- `MISE_GIX=false MISE_LIBGIT2=false mise plugin install vault http://gitea.local:3000/poc/mise-vault.git` (forced real git CLI — should pick up `~/.netrc` with zero extra config)
- same command *without* the `MISE_GIX`/`MISE_LIBGIT2` overrides (mise defaults).
  Expected to need `MISE_GITLAB_*`-unrelated, gix-specific auth; likely to **fail** with netrc alone, confirming risk #1 above.
- `curl -n http://gitea.local:3000/poc/mise-vault/raw/branch/main/install.sh` (raw-file fetch honoring the same `~/.netrc`)
- a Lua `http.get`/`http.download_file` call from the plugin's own hook code, with the token read via `os.getenv("MISE_VAULT_GITEA_TOKEN")` and set as an explicit header (confirming Question 7 — `~/.netrc` alone must **not** work here)

**Phase 2 — protocol-only sanity check (optional, `git-http-backend`)**

Use only if Phase 1's Gitea-specific behavior needs to be isolated from "is this generic git-over-HTTPS-with-Basic-auth" — nginx + `fcgiwrap` + `git-http-backend` + `htpasswd`, on a third hostname (`git-raw.local`) to keep netrc entries distinct.

**Phase 3 — final validation (real GitLab CE, once)**

```yaml
services:
  gitlab:
    image: gitlab/gitlab-ce:latest
    container_name: gitlab-poc
    hostname: gitlab.local
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'http://gitlab.local:8929'
        gitlab_rails['gitlab_shell_ssh_port'] = 2224
        puma['worker_processes'] = 0
        sidekiq['concurrency'] = 10
        prometheus_monitoring['enable'] = false
    ports:
      - '8929:8929'
      - '2224:22'
    volumes:
      - './gitlab-config:/etc/gitlab'
      - './gitlab-logs:/var/log/gitlab'
      - './gitlab-data:/var/opt/gitlab'
    shm_size: '256m'
```
Add `127.0.0.1 gitlab.local` to `/etc/hosts`.

Bootstrap PAT non-interactively:
```
docker exec -it gitlab-poc gitlab-rails runner "
  token = User.find_by_username('root').personal_access_tokens.create(
    scopes: [:api, :read_repository],
    name: 'mise-vault-poc'
  )
  token.set_token('glpat-poc0000000000000')
  token.save!
"
```
Create project + push `mise-vault` repo + tag `v1.0.0` via `curl --header "PRIVATE-TOKEN: glpat-poc0000000000000" ... /api/v4/projects`, then push over `https://oauth2:glpat-poc0000000000000@gitlab.local:8929/root/mise-vault.git` once (to seed content), after which switch to netrc for the actual test:

`~/.netrc`:
```
machine gitlab.local
login root
password glpat-poc0000000000000
```

Re-run the exact same test matrix from Phase 1 (both `MISE_GIX`/`MISE_LIBGIT2` combinations, raw-file fetch via `curl -n` and via the Repository Files API with `PRIVATE-TOKEN`, and the Lua `http.get` header-injection path) against `gitlab.local:8929` to confirm nothing GitLab-specific (CI job tokens aside) diverges from the Gitea/git-http-backend results.
