#!/bin/bash
# entrypoint.sh — idempotent bootstrap for OpenLDAP on OpenShift
# Runs slapd directly from slapd.conf — no OLC/slaptest conversion needed.
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths (Ubuntu 24.04 standard OpenLDAP layout)
# ---------------------------------------------------------------------------
SLAPD="/usr/sbin/slapd"
SLAPADD="/usr/sbin/slapadd"
SLAPPASSWD="/usr/sbin/slappasswd"
SLAPTEST="/usr/sbin/slaptest"

LDAP_DATA_DIR="/var/lib/ldap"
LDAP_RUN_DIR="/run/slapd"
LDAP_SCHEMA_DIR="/etc/ldap/schema"
LDAP_CERTS_DIR="/etc/ldap/certs"
SLAPD_CONF="${LDAP_RUN_DIR}/slapd.conf"

# ---------------------------------------------------------------------------
# Configuration — all overridable via environment variables in the Deployment
# ---------------------------------------------------------------------------
LDAP_BASE_DN="${LDAP_BASE_DN:-dc=example,dc=com}"
LDAP_ORG="${LDAP_ORG:-Example Organization}"
LDAP_ADMIN_PASSWORD="${LDAP_ADMIN_PASSWORD:-changeme}"
LDAP_READONLY_PASSWORD="${LDAP_READONLY_PASSWORD:-readonly}"
LDAP_LOG_LEVEL="${LDAP_LOG_LEVEL:-256}"

INITIALIZED_FLAG="${LDAP_DATA_DIR}/.initialized"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[entrypoint] $*"; }

dc_value() {
  echo "$LDAP_BASE_DN" | grep -o 'dc=[^,]*' | head -1 | cut -d= -f2
}

# ---------------------------------------------------------------------------
# Runtime directory setup
# ---------------------------------------------------------------------------
mkdir -p "$LDAP_RUN_DIR" "$LDAP_DATA_DIR"

# ---------------------------------------------------------------------------
# Locate mdb backend module (path varies by arch on Ubuntu)
# ---------------------------------------------------------------------------
MODULE_PATH=$(find /usr/lib -name "back_mdb.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
if [ -z "$MODULE_PATH" ]; then
  log "ERROR: Could not locate back_mdb.so — is slapd installed correctly?"
  exit 1
fi
log "Found mdb module at: ${MODULE_PATH}"

# ---------------------------------------------------------------------------
# TLS — use -r (readable) not -f (exists) to verify actual access.
# Kubernetes secret mounts exist but may not be readable if fsGroup
# does not match the container's supplemental groups.
# ---------------------------------------------------------------------------
LDAP_URIS="ldap://:1389/"
TLS_DIRECTIVES=""

if [ -r "${LDAP_CERTS_DIR}/tls.crt" ] && [ -r "${LDAP_CERTS_DIR}/tls.key" ]; then
  log "TLS certificates readable — enabling LDAPS on :1636"
  LDAP_URIS="ldap://:1389/ ldaps://:1636/"
  TLS_DIRECTIVES="TLSCertificateFile      ${LDAP_CERTS_DIR}/tls.crt
TLSCertificateKeyFile   ${LDAP_CERTS_DIR}/tls.key"
else
  log "WARNING: TLS cert/key not readable at ${LDAP_CERTS_DIR} — LDAPS disabled."
  log "  cert exists:  $([ -f "${LDAP_CERTS_DIR}/tls.crt" ] && echo yes || echo no)"
  log "  cert readable:$([ -r "${LDAP_CERTS_DIR}/tls.crt" ] && echo yes || echo no)"
  log "  key exists:   $([ -f "${LDAP_CERTS_DIR}/tls.key" ] && echo yes || echo no)"
  log "  key readable: $([ -r "${LDAP_CERTS_DIR}/tls.key" ] && echo yes || echo no)"
fi

# ---------------------------------------------------------------------------
# Generate slapd.conf from current env vars on every start
# ---------------------------------------------------------------------------
ADMIN_PW_HASH=$("$SLAPPASSWD" -s "$LDAP_ADMIN_PASSWORD")
READONLY_PW_HASH=$("$SLAPPASSWD" -s "$LDAP_READONLY_PASSWORD")

cat > "$SLAPD_CONF" <<CONF
modulepath      ${MODULE_PATH}
moduleload      back_mdb

include         ${LDAP_SCHEMA_DIR}/core.schema
include         ${LDAP_SCHEMA_DIR}/cosine.schema
include         ${LDAP_SCHEMA_DIR}/inetorgperson.schema
include         ${LDAP_SCHEMA_DIR}/nis.schema

loglevel        ${LDAP_LOG_LEVEL}

${TLS_DIRECTIVES}

database        mdb
suffix          "${LDAP_BASE_DN}"
rootdn          "cn=admin,${LDAP_BASE_DN}"
rootpw          ${ADMIN_PW_HASH}
directory       ${LDAP_DATA_DIR}

index   objectClass             eq,pres
index   ou,cn,mail,surname,givenname eq,pres,sub
index   uid                     eq,pres,sub

access to attrs=userPassword
    by self write
    by anonymous auth
    by * none
access to attrs=shadowLastChange
    by self write
    by * read
access to *
    by dn.exact="cn=readonly,${LDAP_BASE_DN}" read
    by self read
    by * none
CONF

# ---------------------------------------------------------------------------
# Bootstrap — runs only once per PVC lifetime
# ---------------------------------------------------------------------------
if [ ! -f "$INITIALIZED_FLAG" ]; then
  log "First run — bootstrapping directory (base DN: ${LDAP_BASE_DN})"

  DC_VALUE=$(dc_value)
  "$SLAPADD" -f "$SLAPD_CONF" <<DATA
dn: ${LDAP_BASE_DN}
objectClass: top
objectClass: dcObject
objectClass: organization
o: ${LDAP_ORG}
dc: ${DC_VALUE}

dn: cn=admin,${LDAP_BASE_DN}
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: admin
description: LDAP administrator
userPassword: ${ADMIN_PW_HASH}

dn: cn=readonly,${LDAP_BASE_DN}
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: readonly
description: Read-only service bind account for application authentication
userPassword: ${READONLY_PW_HASH}

dn: ou=users,${LDAP_BASE_DN}
objectClass: top
objectClass: organizationalUnit
ou: users
description: People accounts

dn: ou=groups,${LDAP_BASE_DN}
objectClass: top
objectClass: organizationalUnit
ou: groups
description: Group memberships

DATA

  touch "$INITIALIZED_FLAG"
  log "Bootstrap complete."
else
  log "Database already initialized — skipping bootstrap."
fi

# ---------------------------------------------------------------------------
# Validate config before handing off to slapd
# ---------------------------------------------------------------------------
log "Validating slapd.conf..."
if ! "$SLAPTEST" -f "$SLAPD_CONF" -u 2>&1; then
  log "ERROR: slapd.conf validation failed — see above."
  exit 1
fi
log "Config valid."

# ---------------------------------------------------------------------------
# Diagnostics — printed on every start to aid debugging
# ---------------------------------------------------------------------------
log "Running as: $(id)"
log "Data directory: ${LDAP_DATA_DIR}"
ls -lan "$LDAP_DATA_DIR" 2>&1 | while IFS= read -r line; do log "  $line"; done
log "Certs directory: ${LDAP_CERTS_DIR}"
ls -lan "$LDAP_CERTS_DIR" 2>&1 | while IFS= read -r line; do log "  $line"; done

# ---------------------------------------------------------------------------
# Start slapd — wrapped to capture exit code for debugging
# ---------------------------------------------------------------------------
rm -f "${LDAP_RUN_DIR}/slapd.pid" "${LDAP_RUN_DIR}/slapd.args"

log "slapd.conf contents:"
cat "$SLAPD_CONF" | while IFS= read -r line; do log "  ${line}"; done

log "Sleeping 60s before starting slapd — exec in now to run manually:"
log "  oc exec deployment/openldap -- /bin/bash"
log "  Then: /usr/sbin/slapd -d 1 -f ${SLAPD_CONF} -h '${LDAP_URIS}'"
sleep 60

log "Starting slapd — URIs: ${LDAP_URIS}"
exec "$SLAPD" -d "${LDAP_LOG_LEVEL}" -f "$SLAPD_CONF" -h "${LDAP_URIS}"