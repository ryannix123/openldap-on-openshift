# lldap-on-openshift

<p align="center">
  <img src="https://raw.githubusercontent.com/lldap/lldap/main/art/logo.png" alt="lldap" width="200">
</p>

<p align="center">
  <a href="https://github.com/ryannix123/lldap-on-openshift/actions/workflows/build.yaml">
    <img src="https://img.shields.io/github/actions/workflow/status/ryannix123/lldap-on-openshift/build.yaml?branch=main&label=build&logo=github" alt="Build">
  </a>
  <a href="https://quay.io/repository/ryan_nix/lldap-openshift">
    <img src="https://img.shields.io/badge/quay.io-ryan__nix%2Flldap--openshift-1f6feb?logo=redhat" alt="Quay.io">
  </a>
  <img src="https://img.shields.io/badge/base-lldap%3Astable-4b8bbe" alt="lldap stable">
  <img src="https://img.shields.io/badge/arch-amd64%20%7C%20arm64-6e7681" alt="Multi-arch">
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="License">
  </a>
</p>

> **Lightweight LDAP authentication that never leaves the cluster.**

[lldap](https://github.com/lldap/lldap) is a Rust-based lightweight LDAP server optimised for authentication use cases. It runs with ~20MB RAM, stores users in a single SQLite file, and includes a built-in web UI for user and group management — no `ldapadd` commands required.

## Architecture

```
Namespace
├── Deployment/lldap
│     ├── LDAP  :3890  (ClusterIP — in-cluster auth)
│     ├── LDAPS :6360  (ClusterIP — TLS via OpenShift service cert)
│     └── Web   :17170 (Route — admin UI)
├── Service/lldap         (ClusterIP)
├── Route/lldap-web       (HTTPS edge termination)
├── Secret/lldap-secret   (jwt-secret + admin-password)
├── Secret/lldap-tls      (auto-injected by OpenShift cert controller)
├── ConfigMap/lldap-ca-bundle (cluster CA for client apps)
└── PVC/lldap-data        (SQLite database — 256Mi)
```

## Directory layout

| DN | Purpose |
|---|---|
| `uid=admin,ou=people,<base>` | Admin account — web UI and LDAP bind |
| `ou=people,<base>` | User accounts |
| `ou=groups,<base>` | Groups |

## Deployment

### Prerequisites

```bash
pip install kubernetes
ansible-galaxy collection install kubernetes.core
oc login --token=<token> --server=<api-url>
```

### Run the playbook

```bash
ansible-playbook -i localhost, deploy.yml
```

```
LDAP base DN [dc=example,dc=com]:
JWT secret (long random string):
lldap admin password:
```

The playbook creates the secret, applies the Service first (for TLS cert injection), waits for the cert controller, then deploys everything else and prints the web UI URL.

### Manual deployment

```bash
oc create secret generic lldap-secret \
  --from-literal=jwt-secret='<long-random-string>' \
  --from-literal=admin-password='<strong-password>'

oc apply -f manifests/service.yaml
oc apply -k manifests/
```

## Connecting applications

| Setting | Value |
|---|---|
| LDAP URL | `ldap://lldap:3890` |
| LDAPS URL | `ldaps://lldap:6360` |
| Bind DN | `uid=admin,ou=people,dc=example,dc=com` |
| Users base DN | `ou=people,dc=example,dc=com` |
| Groups base DN | `ou=groups,dc=example,dc=com` |
| User filter | `(&(objectClass=person)(uid={login}))` |
| CA cert (from ConfigMap) | `/etc/ldap/ca/service-ca.crt` |

Mount the `lldap-ca-bundle` ConfigMap into application pods for LDAPS verification:

```yaml
volumeMounts:
  - name: ldap-ca
    mountPath: /etc/ldap/ca
    readOnly: true
volumes:
  - name: ldap-ca
    configMap:
      name: lldap-ca-bundle
```

## Image

`quay.io/ryan_nix/lldap-openshift:latest`

Built weekly from `lldap:stable`. Multi-arch: `linux/amd64` and `linux/arm64`.

## License

Apache-2.0 — Ryan Nix <ryan.nix@gmail.com>
