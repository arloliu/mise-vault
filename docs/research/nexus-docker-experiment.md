# Sonatype Nexus Repository 3 Docker Experiment Research

Research for running Sonatype Nexus Repository 3 in Docker as a local experiment target for mise-vault.
Mise-vault is a private mise backend plugin that downloads tool artifacts from a Nexus raw repository.

**Date**: August 2026

**Primary Sources**:
- help.sonatype.com
- hub.docker.com/r/sonatype/nexus3
- github.com/sonatype/docker-nexus3
- Nexus REST API docs

---

## 1. Container Basics: Docker Setup & Startup

### Image Name & Tags
- **Docker Hub**: `sonatype/nexus3` ([https://hub.docker.com/r/sonatype/nexus3/](https://hub.docker.com/r/sonatype/nexus3/))
- **GitHub Repo**: [https://github.com/sonatype/docker-nexus3](https://github.com/sonatype/docker-nexus3)
- **Latest image**: Alpine-based with Java 21 as of version 3.91.0
- **Available tags**: 
  - `sonatype/nexus3:latest` (Alpine, Java 21)
  - `sonatype/nexus3:3.XX.y` (specific version, Alpine)
  - `sonatype/nexus3:3.XX.y-ubi` (UBI variant with Java 21)

**Source**: [Docker Hub page](https://hub.docker.com/r/sonatype/nexus3/), [Sonatype install docs](https://help.sonatype.com/en/install-nexus-repository.html)

### Basic Docker Run Command
```bash
docker run -d -p 8081:8081 --name nexus sonatype/nexus3
```

**Source**: [Docker Hub page](https://hub.docker.com/r/sonatype/nexus3/), [GitHub README](https://github.com/sonatype/docker-nexus3/blob/main/README.md)

### Port
- **HTTP**: 8081 (default, exposed in container)
- Access Nexus UI at: `http://localhost:8081/`

**Source**: [Docker Hub page](https://hub.docker.com/r/sonatype/nexus3/)

### Volumes & Persistence
- **Container path**: `/nexus-data` (required for state persistence, runs as UID 200)
- **Docker volume approach** (recommended):
  ```bash
  docker volume create --name nexus-data
  docker run -d -p 8081:8081 --name nexus -v nexus-data:/nexus-data sonatype/nexus3
  ```
- **Host directory approach**:
  ```bash
  mkdir -p /some/dir/nexus-data && chown -R 200 /some/dir/nexus-data
  docker run -d -p 8081:8081 --name nexus -v /some/dir/nexus-data:/nexus-data sonatype/nexus3
  ```

**Critical**: For Kubernetes/persistent deployments, use a Persistent Volume (PVC), NOT ephemeral storage (emptyDir).
License data is lost if `/nexus-data` is not persisted.

**Source**: [Cloud Deployments docs](https://help.sonatype.com/en/cloud-deployments.html)

### Memory Requirements & JVM Tuning
- **Minimum RAM for smallest profile (Small)**: 8GB
  - 2 CPUs, 8GB RAM, 20GB local blob storage for ~200,000 requests/day
  - Allocate up to 2/3 of available RAM to Nexus, reserve 1/3 for OS/buffers
- **JVM heap defaults**: Configure via `INSTALL4J_ADD_VM_PARAMS` environment variable
  - Example: `-Xms2703m -Xmx2703m -XX:MaxDirectMemorySize=2703m`
  - Syntax: `docker run -e INSTALL4J_ADD_VM_PARAMS="-Xms4g -Xmx4g" ...`
  - For systems with >8GB RAM, enable G1GC garbage collection

**Source**: [System Requirements docs](https://help.sonatype.com/en/sonatype-nexus-repository-system-requirements.html), [Memory Overview docs](https://help.sonatype.com/en/nexus-repository-memory-overview.html)

### Initial Admin Password
- **Location**: `/nexus-data/admin.password` (inside the container's mounted volume)
- **Startup sequence**:
  1. On first run, Nexus generates a unique random password
  2. File is created at `/nexus-data/admin.password`
  3. Access via: `docker exec nexus cat /nexus-data/admin.password`
  4. Or from host (if using host mount): `cat /your/host/path/nexus-data/admin.password`
- **UI access**: Default username is `admin`

**Source**: [Docker Hub page](https://hub.docker.com/r/sonatype/nexus3/)

### Startup Time Expectations
- **Initial startup**: 2-3 minutes for the Nexus service to fully initialize
- **Monitor readiness**: Tail logs with `docker logs -f nexus` and wait for "Nexus Repository Manager started"
- **Ready indicator**: Web UI becomes accessible at `http://localhost:8081/` when startup is complete

**Source**: [Docker Hub page](https://hub.docker.com/r/sonatype/nexus3/)

---

## 2. Licensing: Community Edition Status & Usage Limits

### Free Edition Status
- **Name**: Sonatype Nexus Repository Community Edition (formerly OSS)
- **Status as of 2024-2026**: **Still free and open**
- **Transition**: As of version 3.77.0, the free edition was renamed from "Nexus Repository OSS" to "Community Edition"
- **Availability**: Can be downloaded and deployed as self-hosted at no cost

**Source**: [Sonatype blog: Introducing Free Nexus Repository Community Edition](https://www.sonatype.com/blog/sonatype-nexus-repository-community-edition), [CE Onboarding docs](https://help.sonatype.com/en/ce-onboarding.html)

### Community Edition Usage Limits
The Community Edition has **hard limits** that block new uploads when exceeded:
- **Maximum components**: 40,000 total components across all repositories
- **Maximum requests**: 100,000 requests per day
- **Behavior when limits exceeded**: New components cannot be added until usage drops below **both** limits
- **Usage monitoring**: Metrics available in Usage Center (takes up to 1 hour to update after changes)

**Note**: Limits apply per deployment instance.
If you exceed these, you must either:
1. Delete components to drop below both thresholds
2. Upgrade to Nexus Repository Pro license

**Source**: [Usage-Based Consumption Guide](https://help.sonatype.com/en/usage-based-consumption-guide-for-self-hosted.html), [CE Onboarding docs](https://help.sonatype.com/en/ce-onboarding.html)

### Feature Differences: Community vs. Pro
**Community Edition includes**:
- All core repository formats (Maven, npm, Docker, PyPI, Raw, etc.)
- Component search and browsing
- REST API access
- LDAP and local authentication
- Basic access controls

**Pro-only features** (relevant to this experiment):
- **User tokens**: Pro-exclusive.
  Community Edition does NOT support user tokens; basic username/password auth only.
- Azure Blob Store / Google Cloud blob stores
- Component tagging and content replication
- SAML authentication and Atlassian Crowd
- High availability (HA) deployment
- Staging and build promotion

**Source**: [Nexus Repository Feature Matrix](https://help.sonatype.com/en/nexus-repository-feature-matrix.html)

### Verdict for mise-vault
Community Edition is suitable for local/small-team experiments with <40,000 components and <100,000 requests/day.
For mise-vault's use case (downloading tool artifacts), this is more than adequate.

---

## 3. Scripted Provisioning: REST API for Repository & Auth Setup

### Creating a Raw Hosted Repository via REST API

**Endpoint**: `POST /service/rest/v1/repositories/raw/hosted`

**Base URL**: `http://localhost:8081/service/rest/v1/repositories/raw/hosted`

**Authentication**: HTTP Basic Auth (admin:generated-password)

**Request Body** (JSON):
```json
{
  "name": "devtools",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": false,
    "writePolicy": "allow_once"
  },
  "cleanup": {
    "policyNames": []
  }
}
```

**Fields**:
- `name`: Repository name (used in URLs: `/repository/devtools/...`)
- `online`: Set to `true` to enable the repository
- `blobStoreName`: Use "default" for standard blob store
- `strictContentTypeValidation`: Set to `false` for raw files (no MIME type checking)
- `writePolicy`: "allow_once" (write once, read many) is standard for hosted repos

**Response**: HTTP 201 Created if successful

**Source**: [Repositories API docs](https://help.sonatype.com/en/repositories-api.html), [Raw Repositories docs](https://help.sonatype.com/en/raw-repositories.html)

### Enabling Anonymous Read Access

**Method**: Global anonymous access must be enabled (no per-repository toggle in CE)

**UI Path**: Settings → Security → Anonymous Access

**API Status**: REST API for enabling anonymous access is **NOT documented** in official Sonatype docs.
Must use UI.

**Steps**:
1. Log in as admin
2. Navigate to Settings → Security → Anonymous Access
3. Check "Allow anonymous users to access the server"
4. Optionally set username/realm (defaults to "anonymous")
5. Save

**Effect**: The `nx-anonymous` role gains:
- Read permissions for all repository formats
- Browse permissions
- Search and health check access

**Source**: [Anonymous Access docs](https://help.sonatype.com/en/anonymous-access.html)

### Changing Admin Password

**Problem**: No documented REST API endpoint for password change exists.

**Available methods**:
1. **UI method** (simplest): Settings → Security → Users → select `admin` → click "Change password" button
2. **Direct database edit** (more complex): Update the `security_user` table with hashed password (requires database access)
3. **H2 console**: Enable HTTP H2 console in config, execute SQL directly

**For scripting**: If you need to automate password changes, the **only reliable method** is the database approach.
Alternatively, accept the auto-generated password from `/nexus-data/admin.password`.

**Workaround for automation**: 
- Initialize Nexus with the auto-generated password
- Read it from `/nexus-data/admin.password`
- Use that password for subsequent API calls
- Manually change the password via UI or database after setup, if needed

**Source**: [Reset Admin Password docs](https://help.sonatype.com/en/reset-the-admin-password.html)

### Idempotent Bootstrap Script Constraints
Given the lack of REST API for anonymous access and password changes, a **complete idempotent script** is limited.
Recommended approach:

1. **Container startup**: Use docker-compose with volume persistence
2. **Wait for Nexus**: Poll `http://localhost:8081/service/rest/v1/status` until it returns HTTP 200
3. **Read initial password**: `cat /nexus-data/admin.password`
4. **Create repository**: POST to `/service/rest/v1/repositories/raw/hosted` with Basic Auth
5. **Anonymous access**: Skip scripting, configure manually via UI (one-time setup).
Alternatively, use Groovy scripting console (advanced).
6. **Upload test artifacts**: Use PUT with Basic Auth (admin:password from step 3)

---

## 4. Uploading & Downloading Artifacts in Raw Repositories

### Upload: PUT Request to Raw Repository

**Method**: HTTP PUT with Basic Auth

**URL format**:
```
http://[server]:[port]/repository/[repository-name]/[file-path]
```

**Example**:
```bash
curl -v --user 'admin:password' \
  --upload-file ./go1.26.0.linux-amd64.tar.gz \
  http://localhost:8081/repository/devtools/go/1.26.0/go1.26.0.linux-amd64.tar.gz
```

**URL breakdown**:
- `/repository/` — Fixed prefix for artifact access
- `devtools` — Repository name
- `go/1.26.0/go1.26.0.linux-amd64.tar.gz` — Arbitrary file path (nested directories supported)

**Response**: HTTP 201 Created on success

**Source**: [Raw Repositories docs](https://help.sonatype.com/en/raw-repositories.html), [Uploading Components docs](https://help.sonatype.com/en/uploading-components.html)

### Download: GET Request from Raw Repository

**Method**: HTTP GET (optional Basic Auth if anonymous access disabled)

**URL format** (same as upload):
```
http://[server]:[port]/repository/[repository-name]/[file-path]
```

**Example - with authentication**:
```bash
curl --user 'admin:password' \
  http://localhost:8081/repository/devtools/go/1.26.0/go1.26.0.linux-amd64.tar.gz \
  -o go1.26.0.linux-amd64.tar.gz
```

**Example - anonymous (if enabled)**:
```bash
curl http://localhost:8081/repository/devtools/go/1.26.0/go1.26.0.linux-amd64.tar.gz \
  -o go1.26.0.linux-amd64.tar.gz
```

**Browser access**: Files are also downloadable directly via web browser at the same URL

**Source**: [Raw Repositories docs](https://help.sonatype.com/en/raw-repositories.html), [Download Artifacts via URI docs](https://help.sonatype.com/en/download-artifacts-using-uri.html)

### Nested Path Support
Raw repositories **fully support nested paths** with arbitrary directory structures:
- ✅ `devtools/go/1.26.0/go1.26.0.linux-amd64.tar.gz`
- ✅ `devtools/golangci-lint/1.54.0/golangci-lint-1.54.0-linux-amd64.tar.gz`
- ✅ `devtools/glab/v1.0.0/glab-1.0.0-linux-amd64.tar.gz`

Directory creation is automatic; just PUT to the full path.

---

## 5. Authentication Options for Downloads

### Option 1: HTTP Basic Auth (Username + Password)
- **Supported**: ✅ Yes, in Community Edition
- **Method**: Include `--user 'username:password'` in curl, or set Authorization header
- **Credentials**: Use admin account (or create custom user via UI)
- **Persistence**: Works across all Nexus versions

**Example with curl**:
```bash
curl --user 'admin:generated-password' \
  http://localhost:8081/repository/devtools/go/1.26.0/go1.26.0.linux-amd64.tar.gz
```

**Source**: [Uploading Components docs](https://help.sonatype.com/en/uploading-components.html)

### Option 2: User Tokens
- **Supported in CE**: ❌ No, Pro-only feature
- **Status**: User tokens are available **only in Nexus Repository Professional** license
- **Fallback**: Use basic auth with username/password instead

**Source**: [Nexus Repository Feature Matrix](https://help.sonatype.com/en/nexus-repository-feature-matrix.html)

### Option 3: Anonymous Read Access
- **Supported**: ✅ Yes, in Community Edition
- **Requirement**: Must enable globally (Settings → Security → Anonymous Access)
- **Scope**: All authenticated requests are read-only for anonymous role
- **URL**: Same `/repository/...` path, no authentication required

**Example**:
```bash
curl http://localhost:8081/repository/devtools/go/1.26.0/go1.26.0.linux-amd64.tar.gz
```

**Source**: [Anonymous Access docs](https://help.sonatype.com/en/anonymous-access.html)

### .netrc / curl Authentication
Standard curl `.netrc` file support works with Nexus:

**~/.netrc** (Unix/Linux/macOS):
```
machine localhost
login admin
password generated-password
```

Make file readable only by owner:
```bash
chmod 600 ~/.netrc
```

Then curl will auto-use credentials:
```bash
curl http://localhost:8081/repository/devtools/go/1.26.0/go1.26.0.linux-amd64.tar.gz
```

---

## 6. Lightweight Alternatives: nginx & Caddy as Nexus Replacements

### nginx Static File Server with Basic Auth

**Feasibility for mise-vault**: ⚠️ **Partial match** — good for read-only use case, limited for provisioning

**Strengths**:
- Extremely lightweight (~10MB image)
- Native HTTP Basic Auth via `ngx_http_auth_basic_module`
- `.htpasswd` file for credentials
- Fast static file serving
- Easy docker-compose setup

**Weaknesses**:
- No REST API for repository creation/management
- No user/permission management UI
- No blob store or component metadata
- All provisioning must be done manually (mkdir, copy files)
- No repository grouping, no proxy repos

**Example nginx config with basic auth**:
```nginx
server {
    listen 8081;
    location /repository/ {
        auth_basic "Private Repository";
        auth_basic_user_file /etc/nginx/.htpasswd;
        alias /data/repositories/;
        autoindex on;
    }
}
```

Create `.htpasswd`:
```bash
htpasswd -c .htpasswd admin
```

**Docker image examples**:
- `tonglil/nginx-basic-auth`
- `hans00/nginx-file-server` (includes WebDAV)
- `smokimk/nginx-static-basic-auth`

**Use case**: Good if mise-vault only needs **read access** and you pre-upload all artifacts manually or via CI/CD.
Not suitable if you need Nexus' REST API provisioning.

**Source**: [NGINX basic auth module](https://nginx.org/en/docs/http/ngx_http_auth_basic_module.html), multiple Docker Hub images documented above

### Caddy Web Server with Basic Auth

**Feasibility for mise-vault**: ⚠️ **Partial match** — similar to nginx, slightly easier config

**Strengths**:
- Minimal configuration (Caddyfile format is simpler than nginx.conf)
- Automatic HTTPS if needed (uses Let's Encrypt by default, but optional)
- Basic Auth via `basic_auth` directive (bcrypt/argon2id hashed passwords)
- Lightweight (~15MB image)
- File server directive for static files
- Auto-reload on config change

**Weaknesses**:
- Same limitations as nginx (no REST API, no management UI, no repo provisioning)
- Smaller ecosystem than nginx
- Password hashing required (cannot use plaintext)

**Example Caddyfile with basic auth**:
```caddy
:8081 {
    basic_auth /repository/* {
        admin JDJhJDEwJE1lZ...  # bcrypt-hashed password
    }
    file_server /repository/* {
        root /data/repositories
    }
}
```

Create hashed password:
```bash
caddy hash-password -plaintext "your-password"
```

**When to use Caddy over nginx**:
- Simpler/cleaner syntax preferred
- HTTPS/automatic cert management needed
- Configuration hot-reload desired

**When to use Caddy over Nexus**:
- Read-only access sufficient
- No REST API provisioning needed
- Minimal operational overhead needed
- Simple nested paths for file storage

**Source**: [Caddy basic_auth directive](https://caddyserver.com/docs/caddyfile/directives/basic_auth), [Caddy file server](https://caddyserver.com/docs/caddyfile/directives/file_server)

### Comparison: When to Use Real Nexus

Real Nexus is warranted if you need:
1. **REST API provisioning**: Automated repository creation, permission management via API
2. **Repository types**: Proxy repos (mirror upstream maven/npm/etc), group repos (combine multiple)
3. **Component metadata**: Search, tagging, custom attributes (Pro-only but available)
4. **User/permission model**: Fine-grained role-based access control (RBAC)
5. **Replication/HA**: High availability, disaster recovery
6. **Integration**: Webhook support, artifact retention policies, cleanup tasks

For **mise-vault's stated use case** (downloading tool artifacts from a raw repo):
- If artifacts are **pre-uploaded** → nginx/Caddy sufficient
- If you need **API-driven provisioning** of repos and permissions → **use Nexus**
- If you want a **sandbox/experiment** that mirrors real Nexus semantics → **use Nexus Community Edition**
  (it's free for experiments)

---

## 7. Sample docker-compose & Provisioning Script

### docker-compose.yml

```yaml
version: '3.8'

services:
  nexus:
    image: sonatype/nexus3:latest
    container_name: mise-vault-nexus
    ports:
      - "8081:8081"
    volumes:
      - nexus-data:/nexus-data
    environment:
      # JVM memory: adjust based on host RAM
      # Example: 4GB heap for machines with 8GB+ RAM
      INSTALL4J_ADD_VM_PARAMS: "-Xms2g -Xmx2g -XX:MaxDirectMemorySize=2g"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8081/service/rest/v1/status"]
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 30s
    restart: unless-stopped

volumes:
  nexus-data:
    driver: local
```

**Usage**:
```bash
docker-compose up -d
docker-compose logs -f  # Monitor startup
```

**Access**:
- UI: `http://localhost:8081/`
- Admin user: `admin`
- Initial password: `docker exec mise-vault-nexus cat /nexus-data/admin.password`

### Provisioning Script

```bash
#!/bin/bash
set -euo pipefail

# mise-vault-nexus-bootstrap.sh
# Idempotent provisioning script for Nexus raw repository

NEXUS_BASE_URL="http://localhost:8081"
ADMIN_USER="admin"
REPO_NAME="devtools"
MAX_RETRIES=30
RETRY_DELAY=2

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Step 1: Wait for Nexus to be ready
log_info "Waiting for Nexus to be ready..."
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if curl -sf "${NEXUS_BASE_URL}/service/rest/v1/status" >/dev/null 2>&1; then
        log_info "Nexus is ready!"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    log_warn "Nexus not ready yet ($RETRY_COUNT/$MAX_RETRIES), retrying in ${RETRY_DELAY}s..."
    sleep $RETRY_DELAY
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    log_error "Nexus failed to start after ${MAX_RETRIES} retries"
    exit 1
fi

# Step 2: Retrieve initial admin password
log_info "Reading initial admin password..."
ADMIN_PASSWORD=$(docker exec mise-vault-nexus cat /nexus-data/admin.password 2>/dev/null || echo "")

if [ -z "$ADMIN_PASSWORD" ]; then
    log_error "Failed to retrieve admin password. Is the container running?"
    exit 1
fi

log_info "Admin password retrieved: ${ADMIN_PASSWORD:0:8}..."

# Step 3: Check if repository already exists
log_info "Checking if repository '$REPO_NAME' exists..."
REPO_EXISTS=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASSWORD}" \
    "${NEXUS_BASE_URL}/service/rest/v1/repositories/raw/hosted/${REPO_NAME}" \
    | grep -q "\"name\" : \"${REPO_NAME}\"" && echo "1" || echo "0")

if [ "$REPO_EXISTS" = "1" ]; then
    log_info "Repository '$REPO_NAME' already exists, skipping creation"
else
    log_info "Creating raw hosted repository '$REPO_NAME'..."
    
    REPO_PAYLOAD=$(cat <<'EOF'
{
  "name": "devtools",
  "online": true,
  "storage": {
    "blobStoreName": "default",
    "strictContentTypeValidation": false,
    "writePolicy": "allow_once"
  },
  "cleanup": {
    "policyNames": []
  }
}
EOF
)

    HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/repo_response.json \
        -X POST \
        -u "${ADMIN_USER}:${ADMIN_PASSWORD}" \
        -H "Content-Type: application/json" \
        -d "$REPO_PAYLOAD" \
        "${NEXUS_BASE_URL}/service/rest/v1/repositories/raw/hosted")
    
    if [ "$HTTP_CODE" = "201" ]; then
        log_info "Repository created successfully (HTTP $HTTP_CODE)"
    elif [ "$HTTP_CODE" = "400" ]; then
        # Check if error is "repository with name 'devtools' already exists"
        if grep -q "already exists" /tmp/repo_response.json 2>/dev/null; then
            log_info "Repository already exists (HTTP 400)"
        else
            log_error "Failed to create repository: $(cat /tmp/repo_response.json)"
            exit 1
        fi
    else
        log_error "Failed to create repository (HTTP $HTTP_CODE): $(cat /tmp/repo_response.json)"
        exit 1
    fi
fi

# Step 4: Upload test artifact
log_info "Preparing test artifact for upload..."

# Create a small test tarball
TEST_FILE="/tmp/test-artifact.tar.gz"
mkdir -p /tmp/test-dir/go/1.26.0
echo "test content" > /tmp/test-dir/go/1.26.0/README.txt
tar -czf "$TEST_FILE" -C /tmp/test-dir . 2>/dev/null || true

if [ ! -f "$TEST_FILE" ]; then
    log_warn "Failed to create test artifact, skipping upload"
else
    TEST_FILE_SIZE=$(stat -f%z "$TEST_FILE" 2>/dev/null || stat -c%s "$TEST_FILE" 2>/dev/null)
    log_info "Uploading test artifact (${TEST_FILE_SIZE} bytes) to /$REPO_NAME/go/1.26.0/test-artifact.tar.gz"
    
    HTTP_CODE=$(curl -s -w "%{http_code}" -o /tmp/upload_response.txt \
        -X PUT \
        -u "${ADMIN_USER}:${ADMIN_PASSWORD}" \
        --data-binary @"$TEST_FILE" \
        "${NEXUS_BASE_URL}/repository/${REPO_NAME}/go/1.26.0/test-artifact.tar.gz")
    
    if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "204" ]; then
        log_info "Test artifact uploaded successfully (HTTP $HTTP_CODE)"
    else
        log_error "Failed to upload test artifact (HTTP $HTTP_CODE)"
    fi
fi

# Step 5: Verify download
log_info "Verifying artifact download..."
curl -sf -u "${ADMIN_USER}:${ADMIN_PASSWORD}" \
    "${NEXUS_BASE_URL}/repository/${REPO_NAME}/go/1.26.0/test-artifact.tar.gz" \
    -o /tmp/downloaded-artifact.tar.gz >/dev/null 2>&1

if [ -f /tmp/downloaded-artifact.tar.gz ]; then
    DOWNLOADED_SIZE=$(stat -f%z /tmp/downloaded-artifact.tar.gz 2>/dev/null || stat -c%s /tmp/downloaded-artifact.tar.gz 2>/dev/null)
    log_info "Artifact downloaded successfully (${DOWNLOADED_SIZE} bytes)"
    
    # Verify SHA256
    if command -v sha256sum >/dev/null; then
        ORIGINAL_HASH=$(sha256sum "$TEST_FILE" | awk '{print $1}')
        DOWNLOADED_HASH=$(sha256sum /tmp/downloaded-artifact.tar.gz | awk '{print $1}')
    else
        ORIGINAL_HASH=$(shasum -a 256 "$TEST_FILE" | awk '{print $1}')
        DOWNLOADED_HASH=$(shasum -a 256 /tmp/downloaded-artifact.tar.gz | awk '{print $1}')
    fi
    
    if [ "$ORIGINAL_HASH" = "$DOWNLOADED_HASH" ]; then
        log_info "SHA256 verification passed!"
    else
        log_warn "SHA256 mismatch: expected $ORIGINAL_HASH, got $DOWNLOADED_HASH"
    fi
else
    log_error "Failed to download artifact"
    exit 1
fi

# Step 6: Print next steps
log_info "Provisioning complete!"
echo ""
echo "=== NEXUS SETUP COMPLETE ==="
echo "Web UI:        http://localhost:8081/"
echo "Admin user:    $ADMIN_USER"
echo "Admin password: $ADMIN_PASSWORD"
echo ""
echo "=== NEXT STEPS ==="
echo "1. Log in to http://localhost:8081/ with admin / $ADMIN_PASSWORD"
echo "2. Change admin password: Settings → Security → Users → admin → Change password"
echo "3. Enable anonymous read access: Settings → Security → Anonymous Access"
echo "   → Check 'Allow anonymous users to access the server'"
echo ""
echo "=== REPOSITORY INFO ==="
echo "Repository name: $REPO_NAME"
echo "Upload URL:      ${NEXUS_BASE_URL}/repository/${REPO_NAME}/[path]"
echo "Download URL:    ${NEXUS_BASE_URL}/repository/${REPO_NAME}/[path]"
echo ""
echo "=== EXAMPLE COMMANDS ==="
echo "# Upload artifact with auth"
echo "curl -u admin:PASSWORD --upload-file artifact.tar.gz \\"
echo "  ${NEXUS_BASE_URL}/repository/${REPO_NAME}/go/1.26.0/artifact.tar.gz"
echo ""
echo "# Download artifact (after enabling anonymous access)"
echo "curl ${NEXUS_BASE_URL}/repository/${REPO_NAME}/go/1.26.0/artifact.tar.gz -o artifact.tar.gz"
echo ""
```

**Usage**:
```bash
chmod +x mise-vault-nexus-bootstrap.sh
docker-compose up -d
./mise-vault-nexus-bootstrap.sh
```

**Script features**:
- ✅ Waits for Nexus to be ready (polls `/service/rest/v1/status`)
- ✅ Retrieves auto-generated admin password from container
- ✅ Checks if repository already exists (idempotent)
- ✅ Creates raw hosted repository via REST API
- ✅ Uploads test artifact with nested path
- ✅ Verifies download and SHA256 checksum
- ✅ Colored output for clarity
- ✅ Error handling and retry logic

**Post-provisioning manual steps**:
1. Change admin password via UI (no REST API available)
2. Enable anonymous read access via Settings → Security → Anonymous Access
3. (Optional) Create additional users or set custom permissions

---

## Key Risks & Unknowns

### 1. **Password Management Gap**
- **Risk**: No REST API for changing admin password or enabling anonymous access via script
- **Mitigation**: 
  - Accept the auto-generated password for initial setup
  - Use database-level password update if full automation is required
  - Manual UI steps acceptable for one-time setup
  - Consider Groovy scripting console for advanced automation (not documented in primary sources)

### 2. **Usage Limits in Community Edition**
- **Risk**: 40,000 components / 100,000 requests-per-day hard limits
- **Impact for mise-vault**: 
  - Each unique Go version (1.25.0, 1.26.0, etc.) = 1 component
  - Each tool variant (linux-amd64, darwin-arm64, etc.) = additional components
  - If downloading golangci-lint, glab, etc., components add up quickly
  - 100K requests/day is typically not a bottleneck unless heavy CI/CD usage
- **Mitigation**: Delete old/unused artifacts to drop below limits, or upgrade to Pro

### 3. **No User Tokens in Community Edition**
- **Risk**: Only basic username/password auth available
- **Impact**: Cannot issue disposable tokens; must share admin password or create custom users
- **Mitigation**: Create dedicated user accounts (non-admin) for specific tasks; manage via UI or database

### 4. **Startup Determinism**
- **Risk**: Initial Nexus startup takes 2-3 minutes; timing can vary by system
- **Mitigation**: Bootstrap script includes retry loop (30 retries × 2s = 60s max wait)

### 5. **Container Persistence Requirements**
- **Risk**: If `/nexus-data` is not persisted (emptyDir, ephemeral), all data is lost on restart
- **Mitigation**: Always use named volumes or host mounts; never use ephemeral storage
- **For Kubernetes**: Must use PVC (PersistentVolumeClaim), not emptyDir

### 6. **Alpine Image Base (as of v3.91.0)**
- **Change**: Default image switched from Debian-based to Alpine Linux
- **Impact**: Smaller image, fewer pre-installed tools, different base utilities
- **Mitigation**: Use explicit tag (e.g., `sonatype/nexus3:3.90.x`) if Debian-based is required

### 7. **REST API Stability**
- **Risk**: Sonatype may change or deprecate REST API endpoints in future versions
- **Mitigation**: Stay on stable version (3.70+); test upgrades in non-prod first

### 8. **Raw Repository Limitations**
- **Unknown**: Whether raw repositories support HTTP range requests for partial downloads
- **Impact**: Large artifact downloads might not support resume-on-error
- **Mitigation**: Test with large files; consider uploading checksums (.sha256 files) alongside artifacts

---

## Recommended Experiment Setup

**For mise-vault's use case** (local artifact mirror for tool downloads):

1. **Start with Community Edition** (free, sufficient for experiments)
2. **Use docker-compose** for repeatable setup
3. **Accept manual UI steps** for password change and anonymous access (worth the simplicity)
4. **Plan for <40K components** or delete old versions regularly
5. **If you need REST API automation**: Use a script that handles database updates for passwords (advanced).
   Alternatively, stick with UI + curl for provisioning.
6. **Lightweight alternative**: Consider nginx/Caddy if:
   - Artifacts are pre-uploaded (CI/CD pipeline handles it)
   - No Nexus REST API features needed
   - Minimal operational complexity is priority

**Licensing verdict**: Community Edition is **100% free and suitable** for local experiments through 2026 and beyond.
As of the 2024 announcement, there are no hidden fees or time limits.

---

## References

Primary sources consulted:

- [Sonatype Nexus Repository Installation Guide](https://help.sonatype.com/en/install-nexus-repository.html)
- [Sonatype Docker Hub: sonatype/nexus3](https://hub.docker.com/r/sonatype/nexus3/)
- [GitHub: sonatype/docker-nexus3](https://github.com/sonatype/docker-nexus3)
- [Nexus System Requirements](https://help.sonatype.com/en/sonatype-nexus-repository-system-requirements.html)
- [Nexus Repository Memory Overview](https://help.sonatype.com/en/nexus-repository-memory-overview.html)
- [Nexus Repositories API](https://help.sonatype.com/en/repositories-api.html)
- [Nexus Raw Repositories](https://help.sonatype.com/en/raw-repositories.html)
- [Nexus Feature Matrix (Community vs Pro)](https://help.sonatype.com/en/nexus-repository-feature-matrix.html)
- [Nexus Community Edition Onboarding](https://help.sonatype.com/en/ce-onboarding.html)
- [Nexus Usage-Based Consumption Guide](https://help.sonatype.com/en/usage-based-consumption-guide-for-self-hosted.html)
- [Nexus Anonymous Access](https://help.sonatype.com/en/anonymous-access.html)
- [Nexus Reset Admin Password](https://help.sonatype.com/en/reset-the-admin-password.html)
- [Nexus Uploading Components](https://help.sonatype.com/en/uploading-components.html)
- [Nexus Download Artifacts via URI](https://help.sonatype.com/en/download-artifacts-using-uri.html)
- [Sonatype Blog: Introducing Free Community Edition](https://www.sonatype.com/blog/sonatype-nexus-repository-community-edition)
- [Caddy Basic Auth Documentation](https://caddyserver.com/docs/caddyfile/directives/basic_auth)
- [NGINX HTTP Basic Authentication Module](https://nginx.org/en/docs/http/ngx_http_auth_basic_module.html)

---

## ADDENDUM — Empirical corrections (2026-08-18, verified against sonatype/nexus3:latest running in Docker)

The live experiment in `experiment/` contradicts several claims above. **Where this addendum conflicts with the body, the addendum wins** (it is based on actual API calls against a running instance):

1. **Admin password change HAS a REST API** (§3 claims otherwise).
   `PUT /service/rest/v1/security/users/admin/change-password` with `Content-Type: text/plain` and the new password as the body — verified working with the initial generated password as basic auth. No database edit or UI needed.
2. **Anonymous access HAS a REST API** (§3 claims otherwise).
   `PUT /service/rest/v1/security/anonymous` with JSON body `{"enabled": false, "userId": "anonymous", "realmName": "NexusAuthorizingRealm"}` — verified working.
3. **Community Edition requires EULA acceptance before any write** (missed entirely above).
   Uploads return HTTP 403 ("You must accept the End User License Agreement") until:
   `GET /service/rest/v1/system/eula` → flip `"accepted": false` to `true` → `POST` the same JSON back. Verified working; now part of `experiment/scripts/provision-nexus.sh`.
4. **Roles and users are fully scriptable via REST** (§3's "limited idempotent script" conclusion is too pessimistic).
   `POST /service/rest/v1/security/roles` (with `nx-repository-view-raw-<repo>-read/browse` privileges) and `POST /service/rest/v1/security/users` both verified working. A fully idempotent zero-UI bootstrap exists: see `experiment/scripts/provision-nexus.sh`.
5. **curl does NOT read `~/.netrc` automatically** (§5's netrc example is wrong).
   `curl` requires `-n`/`--netrc`. Verified empirically (and consistent with curl's own man page).
6. **8GB RAM is production sizing, not an experiment requirement.**
   The experiment instance runs fine with `-Xms1g -Xmx1g -XX:MaxDirectMemorySize=2g`; startup to healthy took well under a minute on this machine.
7. **`writePolicy` value casing**: `"ALLOW_ONCE"` (uppercase) was accepted by the v1 API. The lowercase `"allow_once"` shown in §3 was not tested.
