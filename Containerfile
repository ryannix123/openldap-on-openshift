FROM ubuntu:24.04

LABEL org.opencontainers.image.title="OpenLDAP on OpenShift" \
      org.opencontainers.image.description="Self-contained LDAPS authentication service for OpenShift namespaces" \
      org.opencontainers.image.source="https://github.com/ryannix123/openldap-on-openshift" \
      org.opencontainers.image.licenses="Apache-2.0" \
      maintainer="Ryan Nix <ryan.nix@gmail.com>"

# slapd is available in Ubuntu 24.04 LTS standard repos — no third-party repo needed.
# DEBIAN_FRONTEND=noninteractive suppresses the debconf dialog that apt triggers
# when installing slapd interactively. The entrypoint handles all configuration.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      slapd \
      ldap-utils && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Remove package post-install defaults so the entrypoint bootstraps cleanly
RUN rm -rf /var/lib/ldap/*

# OpenShift assigns an arbitrary UID at runtime; all writable dirs must be
# group-owned by GID 0 (root) with group-write so any UID:0 combo works.
RUN mkdir -p /var/lib/ldap \
             /etc/ldap/certs \
             /run/slapd && \
    chown -R 1001:0 /var/lib/ldap /run/slapd && \
    chmod -R g=u    /var/lib/ldap /run/slapd && \
    # certs dir is read-only (mounted Secret) — no group-write needed
    chown 1001:0 /etc/ldap/certs && \
    chmod 750    /etc/ldap/certs

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Non-privileged ports — OpenShift restricted SCC won't allow <1024
# The Service maps 389→1389 and 636→1636
EXPOSE 1389 1636

USER 1001

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]