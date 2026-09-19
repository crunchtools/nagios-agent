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
    git-core \
    && microdnf clean all

# Dedicated group for podman socket access.
#
# Eleven checks talk to /run/podman/podman.sock, but NRPE runs as nrpe and the
# socket ships 0660 root:root. The workaround on lotor has been an
# ExecStartPre=chmod 666 in the agent unit. That is blunt, and what actually
# contains it is /run/podman being 0700 -- a podman default nobody chose and
# nothing monitors.
#
# The socket group cannot be one nrpe already has. These containers run without
# user namespaces, so in-container GIDs land directly on the host, and 997/998
# are shared with every WordPress site on lotor. Pointing the socket at either
# would hand host root to a web server. GID 1500 is unused on the host and in
# every running container.
#
# podman run --group-add does NOT work here: nrpe calls initgroups() when it
# drops privileges, which rebuilds the group set from this image and discards
# anything podman supplied. The membership has to be baked in.
RUN groupadd -g 1500 podmansock && usermod -aG podmansock nrpe

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

# Pristine copy of the released plugins, for check_plugin_drift.sh.
#
# The deployed agent bind-mounts /srv over /usr/local/nagios/libexec, so once a
# container is running there is no way to see what the IMAGE shipped -- which is
# why the stale-chmod bug above went unnoticed, and why 31 plugins ran in
# production untracked (RT #1490). This directory is outside the mount point, so
# it survives the overlay and gives the drift check something to compare against.
#
# Must stay AFTER the chmod so modes match and only real content drift reports.
RUN cp -a /usr/local/nagios/libexec /usr/local/nagios/libexec-released

EXPOSE 5666

LABEL maintainer="fatherlinux <scott.mccarty@crunchtools.com>"
LABEL description="NRPE agent for Nagios host-level monitoring"
LABEL org.opencontainers.image.source=https://github.com/crunchtools/nagios-agent
LABEL org.opencontainers.image.description="NRPE daemon on UBI 10 with host-level check plugins"
LABEL org.opencontainers.image.licenses=AGPL-3.0-or-later

ENTRYPOINT ["/usr/sbin/nrpe", "-c", "/etc/nagios/nrpe.cfg", "-f"]
