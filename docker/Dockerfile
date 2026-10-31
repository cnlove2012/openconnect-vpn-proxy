FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive \
     LANG=C.UTF-8 \
     LC_ALL=C.UTF-8

RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && apt-get install -y --no-install-recommends \
        openconnect \
        vpnc-scripts \
        tinyproxy \
        iproute2 \
        iputils-ping \
        ca-certificates \
        curl \
        expect \
        procps \
    && rm -rf /var/lib/apt/lists/*

COPY tinyproxy.conf /etc/tinyproxy/tinyproxy.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY openconnect.exp /usr/local/bin/openconnect.exp

RUN chmod 0755 \
    /usr/local/bin/entrypoint.sh \
    /usr/local/bin/openconnect.exp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
