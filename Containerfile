FROM registry.access.redhat.com/ubi10/ubi-minimal

# Register with RHSM using activation key (secrets mounted at build time, never in image layers)
RUN --mount=type=secret,id=activation_key \
    --mount=type=secret,id=org_id \
    if [ -f /run/secrets/activation_key ] && [ -f /run/secrets/org_id ]; then \
        subscription-manager register \
            --activationkey="$(cat /run/secrets/activation_key)" \
            --org="$(cat /run/secrets/org_id)"; \
    fi

# Install EPEL repo RPM (microdnf can't install from URLs, use rpm directly)
RUN curl -sLo /tmp/epel.rpm https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm && \
    rpm -ivh /tmp/epel.rpm && rm -f /tmp/epel.rpm

# Install NRPE daemon and check plugins
RUN microdnf install -y \
    nrpe \
    nagios-plugins-load \
    nagios-plugins-disk \
    nagios-plugins-swap \
    nagios-plugins-procs \
    nagios-plugins-users \
    nagios-plugins-tcp \
    nagios-plugins-ping \
    iputils \
    procps-ng \
    iproute \
    && microdnf clean all

# Unregister from RHSM to avoid leaking entitlements
RUN subscription-manager unregister 2>/dev/null || true

# Overlay custom configs and check scripts
COPY rootfs/ /

# Plugins are tracked 100644 in git, so COPY lands them non-executable and this
# chmod is load-bearing. It used to name each file and had silently fallen five
# plugins behind — check_cloudflare_status, check_container_memory,
# check_container_running, check_factory_health and check_quay_staleness all
# shipped unrunnable. Nothing caught it because the deployed agent bind-mounts
# /srv over this directory, so only a run of the bare image would have noticed.
# Glob so a new plugin cannot be forgotten again.
RUN chmod +x /usr/local/nagios/libexec/*.sh

EXPOSE 5666

LABEL maintainer="fatherlinux <scott.mccarty@crunchtools.com>"
LABEL description="NRPE agent for Nagios host-level monitoring"
LABEL org.opencontainers.image.source=https://github.com/crunchtools/nagios-agent
LABEL org.opencontainers.image.description="NRPE daemon on UBI 10 with host-level check plugins"
LABEL org.opencontainers.image.licenses=AGPL-3.0-or-later

ENTRYPOINT ["/usr/sbin/nrpe", "-c", "/etc/nagios/nrpe.cfg", "-f"]
