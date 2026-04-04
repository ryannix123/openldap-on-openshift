# openldap-on-openshift

<p align="center">
  <img src="https://upload.wikimedia.org/wikipedia/en/c/c7/OpenLDAP-logo.png" alt="OpenLDAP" width="220">
</p>

<p align="center">
  <a href="https://github.com/ryannix123/openldap-on-openshift/actions/workflows/build.yaml">
    <img src="https://img.shields.io/github/actions/workflow/status/ryannix123/openldap-on-openshift/build.yaml?branch=main&label=build&logo=github" alt="Build">
  </a>
  <a href="https://quay.io/repository/ryan_nix/openldap-openshift">
    <img src="https://img.shields.io/badge/quay.io-ryan__nix%2Fopenldap--openshift-1f6feb?logo=redhat" alt="Quay.io">
  </a>
  <img src="https://img.shields.io/badge/OpenLDAP-2.6-4b8bbe" alt="OpenLDAP 2.6">
  <img src="https://img.shields.io/badge/base-Ubuntu%2024.04%20LTS-E95420?logo=ubuntu&logoColor=white" alt="Ubuntu 24.04 LTS">
  <img src="https://img.shields.io/badge/arch-amd64%20%7C%20arm64-6e7681" alt="Multi-arch">
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="License">
  </a>
</p>


A self-contained LDAPS authentication service for OpenShift namespaces, built on Ubuntu 24.04 LTS. Deploy one instance per namespace so applications never authenticate to a service running outside the cluster.

## Architecture

```
Namespace
├── Deployment/openldap (slapd on ports 1389/1636)
├── Service/openldap    (ClusterIP: 389/636 → 1389/1636)
│     └── annotation: service.beta.openshift.io/serving-cert-secret-name: openldap-tls
├── Secret/openldap-tls          (auto-injected by OpenShift cert controller)
├── Secret/openldap-admin        (admin + readonly passwords)
├── PVC/openldap-storage         (mdb data + OLC config via subPaths)
└── ConfigMap/openldap-ca-bundle (service CA injected for client use)
```

TLS is handled entirely by the OpenShift [service serving certificate](https://docs.openshift.com/container-platform/latest/security/certificates/service-serving-certificate.html) mechanism. No cert-manager, no self-signed certs, no manual PKI. The cluster CA is already trusted by all pods in the cluster.

## Directory structure

| DN | Purpose |
|---|---|
| `cn=admin,<base>` | Full admin bind — use for provisioning only |
| `cn=readonly,<base>` | Read-only service account — use for app authentication |
| `ou=users,<base>` | Person accounts |
| `ou=groups,<base>` | Group memberships |

## Quick start

### 1. Set passwords (never commit real values)

```bash
oc create secret generic openldap-admin \
  --from-literal=admin-password='<strong-password>' \
  --from-literal=readonly-password='<strong-password>'
```

### 2. Deploy

```bash
# Apply the Service first — the cert controller needs it to generate the TLS secret
oc apply -f manifests/service.yaml
# Wait a moment, then apply everything else
oc apply -k manifests/
```

### 3. Verify

```bash
# Wait for the pod to be Ready
oc rollout status deployment/openldap

# Test plain LDAP from inside the cluster (exec into any pod)
ldapsearch -x -H ldap://openldap:389 \
  -D "cn=readonly,dc=example,dc=com" \
  -w '<readonly-password>' \
  -b "ou=users,dc=example,dc=com"

# Test LDAPS using the injected CA bundle
ldapsearch -x -H ldaps://openldap:636 \
  -D "cn=readonly,dc=example,dc=com" \
  -w '<readonly-password>' \
  -b "ou=users,dc=example,dc=com" \
  -o TLS_CACERT=/etc/ldap/ca/service-ca.crt
```

## Customizing the base DN per project

Override `LDAP_BASE_DN` and `LDAP_ORG` in the Deployment env block before the first deploy (changes only take effect on a fresh PVC):

```yaml
env:
  - name: LDAP_BASE_DN
    value: "dc=myapp,dc=internal"
  - name: LDAP_ORG
    value: "My Application"
```

Using Kustomize overlays per project:

```yaml
# overlays/myapp/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
bases:
  - ../../manifests
patches:
  - patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/env/0/value
        value: "dc=myapp,dc=internal"
    target:
      kind: Deployment
      name: openldap
```

## Configuring client applications to use LDAPS

Mount the `openldap-ca-bundle` ConfigMap into your application pod:

```yaml
# In your application Deployment
volumeMounts:
  - name: ldap-ca
    mountPath: /etc/ldap/ca
    readOnly: true
volumes:
  - name: ldap-ca
    configMap:
      name: openldap-ca-bundle
```

Then set the CA cert path in your application's LDAP configuration:

| Framework / App | Setting |
|---|---|
| Generic ldapsearch | `LDAPTLS_CACERT=/etc/ldap/ca/service-ca.crt` |
| Python `ldap3` | `Tls(ca_certs_file='/etc/ldap/ca/service-ca.crt')` |
| Java / JNDI | `javax.net.ssl.trustStore` pointing to a JKS with the CA |
| Keycloak | `Connection URL: ldaps://openldap:636`, upload CA under LDAP provider |
| Gitea | `LDAP_TLS_VERIFY=true`, point CA to the mounted file |

Connection URL pattern (same namespace): `ldaps://openldap:636`
Connection URL pattern (cross-namespace): `ldaps://openldap.<namespace>.svc.cluster.local:636`

## Adding users

```bash
# Exec into the pod and use ldapadd
oc exec deployment/openldap -- ldapadd \
  -x -H ldap://localhost:1389 \
  -D "cn=admin,dc=example,dc=com" \
  -w "$ADMIN_PASSWORD" <<EOF
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