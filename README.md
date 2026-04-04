# openldap-on-openshift

> **Authentication that never leaves the cluster.**

Most applications that need LDAP authentication are configured to reach an external directory service — Active Directory, FreeIPA, or a corporate LDAP server sitting somewhere on the network. Every authentication request crosses a namespace boundary, a network boundary, or both. That means latency, firewall rules, VPN dependencies, and a hard external coupling that breaks the moment that service is unreachable.

This project gives you a fully self-contained LDAPS service that lives **inside** your OpenShift namespace. Applications bind to `ldaps://openldap:636` — a ClusterIP Service that is unreachable from outside the cluster by design. Authentication traffic stays on the pod network, encrypted end-to-end using a certificate issued by OpenShift's own internal CA.

---

## Why in-cluster LDAP?

| Concern | External LDAP | openldap-on-openshift |
|---|---|---|
| Auth traffic crosses network boundary | ✅ Yes | ❌ Never |
| Reachable from outside the cluster | ✅ Yes | ❌ ClusterIP only |
| Requires firewall rules / VPN | ✅ Often | ❌ No |
| Fails if external service is down | ✅ Yes | ❌ No — self-contained |
| TLS certificate management | Manual / cert-manager | Automatic (OpenShift service CA) |
| Works in air-gapped environments | ❌ Depends | ✅ Yes |
| Per-namespace isolation | ❌ Shared service | ✅ One instance per namespace |

This pattern is especially useful for:

- **Self-hosted applications** (Gitea, Nextcloud, Rocket.Chat, OpenProject, OpenEMR) that require LDAP/LDAPS for user authentication but don't need to share a directory with the rest of the organization
- **Development and staging namespaces** that need a real LDAP service without connecting to production AD
- **Air-gapped or disconnected OpenShift clusters** where reaching an external directory isn't possible
- **Demos and lab environments** where standing up a full FreeIPA or AD instance is overkill

---

## How it works

```
┌─────────────────────────────────────────────────────────────┐
│  OpenShift Namespace                                        │
│                                                             │
│   ┌──────────────┐    ldaps://openldap:636    ┌──────────┐  │
│   │  Your App    │ ─────────────────────────► │  slapd   │  │
│   │  (any pod)   │   ClusterIP — no egress    │  (pod)   │  │
│   └──────────────┘                            └──────────┘  │
│                                                    │         │
│   ┌─────────────────────────────┐            ┌────┴─────┐   │
│   │  openldap-ca-bundle         │            │   PVC    │   │
│   │  ConfigMap (mount in app)   │            │ data +   │   │
│   │  → service-ca.crt           │            │ config   │   │
│   └─────────────────────────────┘            └──────────┘   │
│                                                             │
│   ── No traffic crosses this boundary ──────────────────── │
└─────────────────────────────────────────────────────────────┘
```

OpenShift's [service serving certificate](https://docs.openshift.com/container-platform/latest/security/certificates/service-serving-certificate.html) controller automatically issues a TLS certificate for the `openldap` Service, signed by the cluster's internal CA. Every pod in the cluster already trusts that CA — no cert-manager, no self-signed certificates, no manual PKI work required.

---

## Image

```
quay.io/ryan_nix/openldap-openshift:latest
```

- Built on **CentOS Stream 10**
- Rebuilt weekly to pick up updated `openldap-servers` packages
- Multi-arch: `linux/amd64` and `linux/arm64`
- Runs as a non-root arbitrary UID (OpenShift restricted SCC compatible)

---

## Directory layout

The following objects are created in your namespace on first deploy:

| DN | Role |
|---|---|
| `cn=admin,<base>` | Full admin — use for provisioning only, not app auth |
| `cn=readonly,<base>` | Read-only bind account — use this in your application config |
| `ou=users,<base>` | People accounts |
| `ou=groups,<base>` | Group memberships |

---

## Deployment

### 1. Set credentials

Never commit real passwords. Use `oc create secret` before applying manifests:

```bash
oc create secret generic openldap-admin \
  --from-literal=admin-password='<strong-password>' \
  --from-literal=readonly-password='<strong-password>'
```

### 2. Apply manifests

The Service must exist before the Deployment so OpenShift's cert controller
can generate the TLS Secret before slapd starts:

```bash
oc apply -f manifests/service.yaml
oc apply -k manifests/
```

### 3. Verify LDAPS connectivity

From any pod in the same namespace (or exec into the slapd pod itself):

```bash
# Confirm the pod is healthy
oc rollout status deployment/openldap

# Test LDAPS using the cluster CA bundle (mounted via the ConfigMap)
ldapsearch -x \
  -H ldaps://openldap:636 \
  -D "cn=readonly,dc=example,dc=com" \
  -w '<readonly-password>' \
  -b "ou=users,dc=example,dc=com" \
  -o TLS_CACERT=/etc/ldap/ca/service-ca.crt
```

---

## Configuring your application

### Mount the CA bundle

Every application that connects over LDAPS needs to verify the server certificate.
Mount the `openldap-ca-bundle` ConfigMap — OpenShift keeps it populated with the
cluster's service CA automatically.

```yaml
# Add to your application Deployment
volumeMounts:
  - name: ldap-ca
    mountPath: /etc/ldap/ca
    readOnly: true
volumes:
  - name: ldap-ca
    configMap:
      name: openldap-ca-bundle
```

### Application LDAP settings

Use these values across your applications. Traffic to `openldap:636` is
ClusterIP-only and never leaves the namespace.

| Setting | Value |
|---|---|
| **LDAP URL** | `ldaps://openldap:636` |
| **Bind DN** | `cn=readonly,dc=example,dc=com` |
| **Base DN** | `dc=example,dc=com` |
| **Users OU** | `ou=users,dc=example,dc=com` |
| **Groups OU** | `ou=groups,dc=example,dc=com` |
| **CA certificate** | `/etc/ldap/ca/service-ca.crt` (from mounted ConfigMap) |
| **TLS** | Required — `LDAPS` only, not STARTTLS |

### Common application wiring

**Gitea**
```ini
[security]
; In app.ini
[service]
DISABLE_REGISTRATION = true   ; rely on LDAP for all auth

[ldap]
; Configure via Admin → Authentication Sources → Add LDAP (simple auth)
; Host: openldap  Port: 636  Security: LDAPS
; User Filter: (&(objectClass=inetOrgPerson)(uid=%s))
; CA cert: /etc/ldap/ca/service-ca.crt (mount the ConfigMap into the Gitea pod)
```

**Nextcloud** (LDAP integration app)
```
Server: ldaps://openldap
Port: 636
Bind DN: cn=readonly,dc=example,dc=com
Base DN: dc=example,dc=com
CA: upload service-ca.crt via LDAP app TLS settings
```

**Rocket.Chat**
```
Server URL: ldaps://openldap:636
Bind DN: cn=readonly,dc=example,dc=com
Base DN: dc=example,dc=com
Reject Unauthorized: true (provide CA via NODE_EXTRA_CA_CERTS or mount)
```

**OpenProject**
```ruby
# In configuration.yml or environment
ldap_auth_source:
  host: openldap
  port: 636
  tls: true
  ca_file: /etc/ldap/ca/service-ca.crt
  bind_dn: cn=readonly,dc=example,dc=com
```

---

## Customizing the base DN per project

The default base DN is `dc=example,dc=com`. Override it before the **first**
deploy (the value is baked into the database on initialization):

```yaml
# In manifests/deployment.yaml env block
- name: LDAP_BASE_DN
  value: "dc=myapp,dc=internal"
- name: LDAP_ORG
  value: "My Application"
```

For multi-project use, maintain a Kustomize overlay per namespace:

```
overlays/
├── gitea/
│   └── kustomization.yaml   # patches LDAP_BASE_DN: dc=gitea,dc=internal
├── nextcloud/
│   └── kustomization.yaml   # patches LDAP_BASE_DN: dc=nextcloud,dc=internal
└── openemr/
    └── kustomization.yaml   # patches LDAP_BASE_DN: dc=openemr,dc=internal
```

---

## Adding users

```bash
ADMIN_PW=$(oc get secret openldap-admin -o jsonpath='{.data.admin-password}' | base64 -d)

oc exec deployment/openldap -- ldapadd \
  -x -H ldap://localhost:1389 \
  -D "cn=admin,dc=example,dc=com" \
  -w "$ADMIN_PW" <<EOF
dn: uid=jdoe,ou=users,dc=example,dc=com
objectClass: top
objectClass: inetOrgPerson
objectClass: posixAccount
cn: Jane Doe
sn: Doe
uid: jdoe
mail: jdoe@example.com
uidNumber: 10001
gidNumber: 10001
homeDirectory: /home/jdoe
userPassword: $(oc exec deployment/openldap -- slappasswd -s 'initial-password')
EOF
```

---

## Environment variable reference

| Variable | Default | Description |
|---|---|---|
| `LDAP_BASE_DN` | `dc=example,dc=com` | Root suffix — set before first deploy |
| `LDAP_ORG` | `Example Organization` | Organization name on the root entry |
| `LDAP_ADMIN_PASSWORD` | *(from Secret)* | Admin bind DN password |
| `LDAP_READONLY_PASSWORD` | *(from Secret)* | Read-only bind DN password |
| `LDAP_LOG_LEVEL` | `256` | slapd verbosity (0 = silent, 256 = stats, -1 = all) |

---

## Security notes

- The `openldap` Service is `ClusterIP` — there is no `Route`, no `NodePort`, and no `LoadBalancer`. Authentication traffic physically cannot leave the cluster.
- The readonly bind DN (`cn=readonly`) has read access to all attributes except `userPassword`. Applications should always bind as `readonly`, never as `admin`.
- The admin bind DN should only be used from within `oc exec` or a provisioning Job — never hard-coded into application configuration.
- Passwords are stored using SSHA (salted SHA-1) as generated by `slappasswd`. For stronger hashing, pass `-h {ARGON2}` to `slappasswd` if your OpenLDAP build supports it.

---

## License

Apache-2.0 — Ryan Nix &lt;ryan.nix@gmail.com&gt;