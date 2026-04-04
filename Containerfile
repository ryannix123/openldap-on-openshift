FROM quay.io/centos/centos:stream10

LABEL org.opencontainers.image.title="OpenLDAP on OpenShift" \
      org.opencontainers.image.description="Self-contained LDAPS authentication service for OpenShift namespaces" \
      org.opencontainers.image.source="https://github.com/ryannix123/openldap-on-openshift" \
      org.opencontainers.image.licenses="Apache-2.0" \
      maintainer="Ryan Nix <ryan.nix@gmail.com>"

RUN dnf install -y openldap-servers openldap-clients && \
    dnf clean all && \
    rm -rf /var/cache/dnf

# Remove any package post-install defaults so the entrypoint bootstraps cleanly
RUN rm -rf /etc/openldap/slapd.d/* /var/lib/ldap/*

# OpenShift assigns an arbitrary UID at runtime; all writable dirs must be
# group-owned by GID 0 (root) with group-write so any UID:0 combo works.
RUN mkdir -p /var/lib/ldap /etc/openldap/slapd.d /etc/openldap/certs /run/openldap && \
    chown -R 1001:0 /var/lib/ldap /etc/openldap/slapd.d /run/openldap /etc/openldap && \
    chmod -R g=u   /var/lib/ldap /etc/openldap/slapd.d /run/openldap /etc/openldap && \
    # certs dir is read-only (mounted Secret) — no group-write needed
    chown 1001:0 /etc/openldap/certs && \
    chmod 750    /etc/openldap/certs

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Non-privileged ports — OpenShift restricted SCC won't allow <1024
# The Service maps 389→1389 and 636→1636
EXPOSE 1389 1636

USER 1001

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
