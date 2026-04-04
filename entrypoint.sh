#!/bin/bash
# entrypoint.sh — idempotent bootstrap for OpenLDAP on OpenShift
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — all overridable via environment variables in the Deployment
# ---------------------------------------------------------------------------
LDAP_BASE_DN="${LDAP_BASE_DN:-dc=example,dc=com}"
LDAP_ORG="${LDAP_ORG:-Example Organization}"
LDAP_ADMIN_PASSWORD="${LDAP_ADMIN_PASSWORD:-changeme}"
LDAP_READONLY_PASSWORD="${LDAP_READONLY_PASSWORD:-readonly}"
LDAP_LOG_LEVEL="${LDAP_LOG_LEVEL:-256}"          # 256 = stats; 0 = silent

SLAPD_CONFIG_DIR="/etc/openldap/slapd.d"
LDAP_DATA_DIR="/var/lib/ldap"
LDAP_RUN_DIR="/run/openldap"
LDAP_CERTS_DIR="/etc/openldap/certs"
INITIALIZED_FLAG="${LDAP_DATA_DIR}/.initialized"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[entrypoint] $*"; }

# Extract the first dc= value from the base DN (e.g. dc=example,dc=com → example)
dc_value() {
  echo "$LDAP_BASE_DN" | grep -o 'dc=[^,]*' | head -1 | cut -d= -f2
}

# ---------------------------------------------------------------------------
# Runtime directory setup (needed after PVC mount, which may be empty)
# ---------------------------------------------------------------------------
mkdir -p "$LDAP_RUN_DIR"

# ---------------------------------------------------------------------------
# Bootstrap — runs only once per PVC lifetime
# ---------------------------------------------------------------------------
if [ ! -f "$INITIALIZED_FLAG" ]; then
  log "First run — bootstrapping OpenLDAP (base DN: ${LDAP_BASE_DN})"

  # Hash passwords via slappasswd
  ADMIN_PW_HASH=$(slappasswd -s "$LDAP_ADMIN_PASSWORD")
  READONLY_PW_HASH=$(slappasswd -s "$LDAP_READONLY_PASSWORD")
  DC_VALUE=$(dc_value)

  # Clear any stale config from a previous incomplete init
  rm -rf "${SLAPD_CONFIG_DIR:?}"/*

  # -------------------------------------------------------------------------
  # Phase 1 — OLC (cn=config) bootstrap
  # Write to a temp file so slapadd can follow schema include: paths
  # -------------------------------------------------------------------------
  CONFIG_LDIF=$(mktemp /tmp/slapd-config.XXXXXX.ldif)
  trap 'rm -f "$CONFIG_LDIF"' EXIT

  cat > "$CONFIG_LDIF" <<CONFIG
dn: cn=config
objectClass: olcGlobal
cn: config
olcArgsFile: /run/openldap/slapd.args
olcPidFile: /run/openldap/slapd.pid
olcTLSCertificateFile: /etc/openldap/certs/tls.crt
olcTLSCertificateKeyFile: /etc/openldap/certs/tls.key
olcLogLevel: ${LDAP_LOG_LEVEL}

dn: cn=schema,cn=config
objectClass: olcSchemaConfig
cn: schema

include: file:///etc/openldap/schema/core.ldif
include: file:///etc/openldap/schema/cosine.ldif
include: file:///etc/openldap/schema/inetorgperson.ldif
include: file:///etc/openldap/schema/nis.ldif

dn: olcDatabase={-1}frontend,cn=config
objectClass: olcDatabaseConfig
objectClass: olcFrontendConfig
olcDatabase: {-1}frontend
olcAccess: {0}to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * break
olcAccess: {1}to dn.exact="" by * read
olcAccess: {2}to dn.base="cn=Subschema" by * read

dn: olcDatabase={0}config,cn=config
objectClass: olcDatabaseConfig
olcDatabase: {0}config
olcAccess: {0}to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * break

dn: olcDatabase={1}mdb,cn=config
objectClass: olcDatabaseConfig
objectClass: olcMdbConfig
olcDatabase: {1}mdb
olcDbDirectory: /var/lib/ldap
olcSuffix: ${LDAP_BASE_DN}
olcRootDN: cn=admin,${LDAP_BASE_DN}
olcRootPW: ${ADMIN_PW_HASH}
olcDbMaxSize: 1073741824
olcDbIndex: objectClass eq,pres
olcDbIndex: ou,cn,mail,surname,givenname eq,pres,sub
olcDbIndex: uid eq,pres,sub
olcDbIndex: memberOf eq
olcAccess: {0}to attrs=userPassword by self write by anonymous auth by dn.exact="cn=admin,${LDAP_BASE_DN}" write by * none
olcAccess: {1}to attrs=shadowLastChange by self write by * read
olcAccess: {2}to * by dn.exact="cn=admin,${LDAP_BASE_DN}" write by dn.exact="cn=readonly,${LDAP_BASE_DN}" read by self read by * none

CONFIG

  log "Loading OLC configuration..."
  slapadd -n 0 -F "$SLAPD_CONFIG_DIR" -l "$CONFIG_LDIF"
  rm -f "$CONFIG_LDIF"
  trap - EXIT

  # -------------------------------------------------------------------------
  # Phase 2 — Directory data bootstrap (database 1 = mdb)
  # -------------------------------------------------------------------------
  log "Loading base directory data..."
  slapadd -n 1 -F "$SLAPD_CONFIG_DIR" <<DATA
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
description: Group membership

DATA

  touch "$INITIALIZED_FLAG"
  log "Bootstrap complete."

else
  log "Database already initialized — skipping bootstrap."
fi

# ---------------------------------------------------------------------------
# TLS detection — if the cert Secret isn't mounted yet (e.g. before the
# OpenShift service cert controller has run), degrade gracefully to plain LDAP
# so the pod stays Running and readiness probes pass.
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
exec slapd -d "${LDAP_LOG_LEVEL}" -F "$SLAPD_CONFIG_DIR" -h "${LDAP_URIS}"
