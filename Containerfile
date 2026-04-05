FROM docker.io/lldap/lldap:stable

LABEL org.opencontainers.image.title="lldap on OpenShift" \
      org.opencontainers.image.description="Lightweight LDAP authentication service for OpenShift namespaces" \
      org.opencontainers.image.source="https://github.com/ryannix123/lldap-on-openshift" \
      org.opencontainers.image.licenses="Apache-2.0" \
      maintainer="Ryan Nix <ryan.nix@gmail.com>"

# OpenShift assigns an arbitrary UID at runtime with GID 0.
# Pre-set group-write on all app and data directories at build time
# so no runtime chown is needed — which would fail under restricted SCC.
USER root
RUN chown -R 1000:0 /app /data 2>/dev/null || true && \
    chmod -R g=u /app /data

USER 1000

EXPOSE 3890 6360 17170