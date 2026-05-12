FROM golang:1.22-alpine AS build
RUN apk add --no-cache git make gcc musl-dev bash

RUN git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-go.git /src/awg-go && \
    git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-tools.git /src/awg-tools

WORKDIR /src/awg-go
RUN go build -v -o /out/usr/bin/amneziawg-go

WORKDIR /src/awg-tools/src
RUN make && make install DESTDIR=/out PREFIX=/usr WITH_BASHCOMPLETION=no WITH_SYSTEMDUNITS=no WITH_WGQUICK=yes

FROM alpine:3.20
RUN apk add --no-cache iproute2 iptables ip6tables bash openresolv

COPY --from=build /out/usr/bin/amneziawg-go /usr/bin/amneziawg-go
COPY --from=build /out/usr/bin/awg /usr/bin/awg
COPY --from=build /out/usr/bin/awg-quick /usr/bin/awg-quick

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
