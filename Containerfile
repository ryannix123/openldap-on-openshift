FROM docker.io/lldap/lldap:stable

LABEL org.opencontainers.image.title="lldap on OpenShift" \
      org.opencontainers.image.description="Lightweight LDAP authentication service for OpenShift namespaces" \
      org.opencontainers.image.source="https://github.com/ryannix123/lldap-on-openshift" \
      org.opencontainers.image.licenses="Apache-2.0" \
      maintainer="Ryan Nix <ryan.nix@gmail.com>"

# OpenShift assigns an arbitrary UID at runtime. Ensure /data is
# group-owned by GID 0 with group-write so any UID:0 combo works.
USER root
RUN mkdir -p /data && \
    chown -R 1000:0 /data && \
    chmod -R g=u /data

USER 1000

EXPOSE 3890 6360 17170
