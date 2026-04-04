#!/bin/bash
# entrypoint.sh — idempotent bootstrap for OpenLDAP on OpenShift
# Uses slapd.conf + slaptest for OLC generation — avoids Ubuntu slapadd
# attribute-type-undefined issues with backend-specific OLC attributes.
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths (Ubuntu 24.04 standard OpenLDAP layout)
# ---------------------------------------------------------------------------
SLAPD="/usr/sbin/slapd"
SLAPADD="/usr/sbin/slapadd"
SLAPPASSWD="/usr/sbin/slappasswd"
SLAPTEST="/usr/sbin/slaptest"

SLAPD_CONFIG_DIR="/etc/ldap/slapd.d"
LDAP_DATA_DIR="/var/lib/ldap"
LDAP_RUN_DIR="/run/slapd"
LDAP_SCHEMA_DIR="/etc/ldap/schema"
LDAP_CERTS_DIR="/etc/ldap/certs"

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
# Runtime directory setup (needed after PVC mount)
# ---------------------------------------------------------------------------
mkdir -p "$LDAP_RUN_DIR"

# ---------------------------------------------------------------------------
# Bootstrap — runs only once per PVC lifetime
# ---------------------------------------------------------------------------
if [ ! -f "$INITIALIZED_FLAG" ]; then
  log "First run — bootstrapping OpenLDAP (base DN: ${LDAP_BASE_DN})"

  ADMIN_PW_HASH=$("$SLAPPASSWD" -s "$LDAP_ADMIN_PASSWORD")
  READONLY_PW_HASH=$("$SLAPPASSWD" -s "$LDAP_READONLY_PASSWORD")
  DC_VALUE=$(dc_value)

  rm -rf "${SLAPD_CONFIG_DIR:?}"/*

  # -------------------------------------------------------------------------
  # Phase 1 — generate OLC config via slapd.conf + slaptest
  #
  # Using slapd.conf here (not OLC LDIF) because slaptest loads the full
  # slapd binary including backend modules before converting, making all
  # attribute types available. Direct slapadd -n 0 with OLC LDIF fails on
  # Ubuntu when backend-specific attributes (olcDbIndex, olcDbMaxSize, etc.)
  # are encountered before the mdb schema is registered.
  # -------------------------------------------------------------------------
  SLAPD_CONF=$(mktemp /tmp/slapd.XXXXXX.conf)
  trap 'rm -f "$SLAPD_CONF"' EXIT

  # Locate the mdb backend module — path varies by arch on Ubuntu
  MODULE_PATH=$(find /usr/lib -name "back_mdb.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
  if [ -z "$MODULE_PATH" ]; then
    log "ERROR: Could not locate back_mdb.so — is slapd installed correctly?"
    exit 1
  fi
  log "Found mdb module at: ${MODULE_PATH}"

  cat > "$SLAPD_CONF" <<CONF
modulepath      ${MODULE_PATH}
moduleload      back_mdb

include         ${LDAP_SCHEMA_DIR}/core.schema
include         ${LDAP_SCHEMA_DIR}/cosine.schema
include         ${LDAP_SCHEMA_DIR}/inetorgperson.schema
include         ${LDAP_SCHEMA_DIR}/nis.schema

pidfile         ${LDAP_RUN_DIR}/slapd.pid
argsfile        ${LDAP_RUN_DIR}/slapd.args
loglevel        ${LDAP_LOG_LEVEL}

TLSCertificateFile      ${LDAP_CERTS_DIR}/tls.crt
TLSCertificateKeyFile   ${LDAP_CERTS_DIR}/tls.key

database        mdb
suffix          "${LDAP_BASE_DN}"
rootdn          "cn=admin,${LDAP_BASE_DN}"
rootpw          ${ADMIN_PW_HASH}
directory       ${LDAP_DATA_DIR}

index   objectClass     eq,pres
index   ou,cn,mail,surname,givenname eq,pres,sub
index   uid             eq,pres,sub

access to attrs=userPassword
    by self write
    by anonymous auth
    by dn.exact="cn=admin,${LDAP_BASE_DN}" write
    by * none
access to attrs=shadowLastChange
    by self write
    by * read
access to *
    by dn.exact="cn=admin,${LDAP_BASE_DN}" write
    by dn.exact="cn=readonly,${LDAP_BASE_DN}" read
    by self read
    by * none
CONF

  log "Converting slapd.conf to OLC format..."
  "$SLAPTEST" -f "$SLAPD_CONF" -F "$SLAPD_CONFIG_DIR"
  rm -f "$SLAPD_CONF"
  trap - EXIT

  # -------------------------------------------------------------------------
  # Phase 2 — bootstrap directory data
  # -------------------------------------------------------------------------
  log "Loading base directory data..."
  "$SLAPADD" -n 1 -F "$SLAPD_CONFIG_DIR" <<DATA
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
# TLS detection
# ---------------------------------------------------------------------------
LDAP_URIS="ldap://:1389/"

if [ -f "${LDAP_CERTS_DIR}/tls.crt" ] && [ -f "${LDAP_CERTS_DIR}/tls.key" ]; then
  log "TLS certificates found — enabling LDAPS on :1636"
  LDAP_URIS="ldap://:1389/ ldaps://:1636/"
else
  log "WARNING: TLS cert/key not found at ${LDAP_CERTS_DIR} — LDAPS disabled."
  log "  Ensure the Service annotation 'service.beta.openshift.io/serving-cert-secret-name'"
  log "  is set and the generated Secret is mounted at ${LDAP_CERTS_DIR}."
fi

# ---------------------------------------------------------------------------
# Start slapd in the foreground (PID 1)
# ---------------------------------------------------------------------------
log "Starting slapd — URIs: ${LDAP_URIS}"
exec "$SLAPD" -d "${LDAP_LOG_LEVEL}" -F "$SLAPD_CONFIG_DIR" -h "${LDAP_URIS}"