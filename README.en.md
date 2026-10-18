# usque in Docker

[Русская версия →](README.md)

A container with [usque](https://github.com/Diniboy1123/usque), an unofficial Cloudflare WARP
client speaking MASQUE (HTTP/3 over QUIC, with an HTTP/2 mode as well).

It routes a machine's traffic through WARP — as a full TUN interface (all IP traffic), as a
SOCKS5/HTTP proxy, or as port forwarding into the WARP network. It supports regular WARP
accounts and Cloudflare Zero Trust, configurable routing, and works around ISP filtering by
SNI when needed.

## Features

* **Every usque mode**: `tun`, `socks`, `http-proxy`, `l4-socks`, `l4-http-proxy`, `portfw`.
  Switch with `USQUE_MODE`; several modes can run at once in the same container.
* **TUN with a custom interface name** (`USQUE_IFACE`), configurable MTU, and a mode that
  leaves addresses alone.
* **Routing inside the container**: `ROUTE_MODE=none|main|table` — from "don't touch
  anything" to a dedicated routing table driven by an `ip rule`. The MASQUE endpoint bypass
  (without it you get a routing loop) is set up automatically.
* **Zero Trust**: registration with a team token, correct SNI chosen automatically, key
  refresh on start.
* **DPI workarounds**: custom SNI (`USQUE_SNI`) and TCP instead of QUIC when UDP is blocked.
* **Multi-arch**: `linux/amd64`, `linux/arm64`, `linux/arm/v7`.
* **Ready-made CI**: tests, multi-arch build and image publishing — [.gitlab-ci.yml](.gitlab-ci.yml).

## Requirements

| | For `tun` | For proxy modes |
|---|---|---|
| `tun` driver in the host kernel | **required** | not needed |
| Docker with `cap_add` and `device_cgroup_rules` support | required | required |
| Extra capabilities | `NET_ADMIN` | none |
| Internet access to Cloudflare | required | required |

Check whether your kernel supports TUN:

```bash
grep -i tun /proc/misc      # is the driver registered in the kernel?
modprobe tun                # if it is built as a module
```

If the output is empty and the module is missing (`# CONFIG_TUN is not set` in the kernel
config), TUN mode will not work on that machine — you would need a different kernel. The
userspace modes — `socks`, `l4-socks`, `http-proxy` — work regardless.

## Quick start

```bash
git clone https://github.com/incognito1990/usque-docker.git && cd usque-docker
cp .env.example .env
docker compose up -d --build
docker compose logs -f usque
```

On the first start the container registers a new WARP device and stores the config in
`./config/config.json`. That file holds the device's private key — keep it to yourself
(it is excluded from git by `.gitignore`). If a valid config already exists, nothing is
registered again.

Verify that traffic actually goes through WARP:

```bash
docker compose exec usque curl -s https://1.1.1.1/cdn-cgi/trace | grep -E '^(ip|warp)='
```

You should see `warp=on` and a Cloudflare egress address instead of your ISP's. For socks
mode, the same check from outside:

```bash
curl -x socks5h://127.0.0.1:1080 https://1.1.1.1/cdn-cgi/trace | grep warp
```

## Modes

| `USQUE_MODE`   | What it does | Port |
|----------------|--------------|------|
| `tun`          | TUN interface, all IP traffic (default) | — |
| `socks`        | SOCKS5, including UDP ASSOCIATE | `USQUE_SOCKS_PORT` (1080) |
| `http-proxy`   | HTTP proxy with CONNECT | `USQUE_HTTP_PORT` (8000) |
| `l4-socks`     | TCP-only SOCKS5, faster (QUIC streams) | 1080 |
| `l4-http-proxy`| TCP-only HTTP proxy | 8000 |
| `portfw`       | Forward ports into and out of the WARP network | — |
| `register`     | Register a device and exit | — |
| `enroll`       | Re-enroll the key and exit | — |

To run several modes at once, give the extra one a port:

```bash
USQUE_MODE=tun
EXTRA_SOCKS_PORT=1080     # plus SOCKS5
EXTRA_HTTP_PORT=8000      # plus the HTTP proxy
```

Each mode brings up its own tunnel inside the same container. If any process exits, the
container stops — you will see that in `docker compose ps` and in the logs.

One-off commands without keeping a container running:

```bash
docker compose run --rm -e USQUE_MODE=register usque   # new device
docker compose run --rm -e USQUE_MODE=enroll usque     # refresh the key
make dryrun                                            # print the command, run nothing
```

## Configuration

Every variable is documented in [.env.example](.env.example). The main ones:

| Variable | Default | Purpose |
|---|---|---|
| `USQUE_MODE` | `tun` | operating mode |
| `USQUE_CONFIG` | `/etc/usque/config.json` | config path inside the container |
| `USQUE_REGISTER` | `auto` | `auto` — register if no config exists; `force` — replace it with a new device; `never` — leave it alone |
| `USQUE_IFACE` | `usque-tun` | TUN interface name, up to 15 characters |
| `USQUE_SNI` | usque default | override the SNI (Zero Trust, DPI workarounds) |
| `USQUE_JWT` | — | Cloudflare Zero Trust team token |
| `ROUTE_MODE` | `main` | `none` / `main` / `table` — see "Routing" |
| `ROUTE_TABLE` | `100` | table number for `ROUTE_MODE=table` |
| `ROUTE_EXCLUDE` | — | subnets that always bypass the tunnel |
| `ROUTE_IPV6` | `auto` | whether to touch the IPv6 default route |
| `USQUE_BIND` | `0.0.0.0` | address the proxies listen on |
| `USQUE_PROXY_USER`, `USQUE_PROXY_PASS` | — | proxy credentials |
| `USQUE_HTTP2` | `0` | `1` — use TCP+TLS instead of QUIC |
| `USQUE_MTU` | `1280` | tunnel MTU |
| `USQUE_EXTRA_ARGS` | — | raw arguments appended to the usque command |

Apply changes by restarting: `docker compose up -d` (after editing `.env`) or
`docker compose restart usque`.

Ports are published on `127.0.0.1` only — a proxy without authentication exposed to the
whole network becomes an open proxy. If you need access from other machines, change the port
mapping in `docker-compose.yml` and make sure to set `USQUE_PROXY_USER`/`USQUE_PROXY_PASS`.

## Zero Trust

Get a team token: Zero Trust Dashboard → Settings → WARP Client → Device enrollment. Then
two lines in `.env` are enough:

```bash
USQUE_JWT=<team-token>
USQUE_REGISTER=auto
```

The container registers the device in your organization and **picks the right SNI by
itself** (`zt-masque.cloudflareclient.com`) — the regular WARP SNI does not work with Zero
Trust. That fact is remembered in `config/.zerotrust`, so later runs use the correct SNI too.

Zero Trust tokens are short-lived, so refreshing the key on start is a good idea:

```bash
USQUE_ENROLL_ON_START=1
```

If you already have a config from another device, drop it into `./config/config.json`. For
Zero Trust only `id` and `access_token` differ; see
[config/config.zerotrust.example.json](config/config.zerotrust.example.json) for the shape.

Limitations of the `l4-*` modes: they cannot set an SNI (it is hardcoded to
`consumer-masque-proxy.cloudflareclient.com`) and they only work over QUIC. The container
filters out unsupported flags and warns about them in the log.

## Routing

usque adds no routes of its own — it only brings the interface up and assigns addresses.
Everything else is done by [hooks/route-hook.sh](hooks/route-hook.sh), which usque calls after
every connect and disconnect.

```bash
ROUTE_MODE=none      # leave routing alone
ROUTE_MODE=main      # default route via the TUN in the main table    ← default
ROUTE_MODE=table     # same, but in a separate table plus an ip rule
```

| | `main` | `table` |
|---|---|---|
| Default route | in the main table | in `ROUTE_TABLE` + `ip rule lookup <table> priority 1000` |
| MASQUE endpoint bypass | `/32` via the container gateway | both in the main table and in the table |
| Local networks | reachable as usual | copied into the routing table |
| On tunnel loss | the previous route is restored | the route is removed from the table, the rule stays and traffic falls back to the main table |
| Main table | modified | untouched |

Pick `main` when the container is the only gateway and you want the familiar picture; pick
`table` when you would rather not modify the main table (for example, other VPNs live in the
same network namespace). Use `none` when routing is managed by something else.

Why a separate table needs route copying: it does not extend the main table, it fully
replaces it for the matching traffic, so its `default` also captures the Docker gateway.
Without copying, replies to clients of the docker network — for example the published proxy
port — would break.

The endpoint bypass is mandatory in every mode: a `/32` route to the MASQUE endpoint via the
gateway is added first, and only then is the default route switched. Otherwise packets to the
endpoint would enter the tunnel, come back into usque, and loop. The gateway is captured at
container start, before usque runs.

Excluding subnets from the tunnel:

```bash
ROUTE_EXCLUDE="10.0.0.0/8 192.168.0.0/16"
```

## Filtering workarounds: SNI and DPI

If the proxy listens on its port but the first request through it hangs, with
`Establishing MASQUE connection...` and nothing after that in the log, your ISP is filtering
the connection by domain name (SNI). Setting an SNI of a domain that passes works around it:

```bash
USQUE_SNI=example.com
```

`example.com` here is a placeholder. You need a real domain reachable through your ISP that is
served by Cloudflare. The endpoint certificate is still verified — against the key from your
config rather than the hostname — so overriding the SNI does not weaken anything.

If that does not help, try `USQUE_HTTP2=1`: the connection then uses TCP+TLS instead of
QUIC/UDP. It also helps when UDP is blocked outright. Note that `l4-*` modes only work over
QUIC and do not support this flag.

## DNS

By default the container uses the Docker resolver (`127.0.0.11`), which resolves on the
daemon's side — that is, **outside the tunnel**. To send DNS through WARP, set `dns:` in
`docker-compose.yml` to a resolver you trust.

Do that deliberately, though: in networks with DNS filtering, queries to public resolvers may
not work at all, leaving the container unable to resolve anything — both registration and API
calls will fail. If that happens, revert to the built-in Docker resolver (comment `dns:` out).

Containers that share the network namespace with this one (`network_mode: service:usque`) need
their own `dns:` too, otherwise they stay on the Docker resolver.

## Building from source

```bash
make build          # image for the current architecture
make buildx         # multi-arch; with REGISTRY=... it pushes right away
```

usque itself is built from upstream; its version is set with `USQUE_REF` — a branch, tag or a
specific commit — either in `.env` or as a `--build-arg`.

Building for a foreign architecture needs emulation for the package-install step
(`make binfmt`, requires `--privileged`), because the final stage is an alpine image with
`apk add`. An `exec /bin/sh: exec format error` failure means exactly that. Building on a
machine of the target architecture, or in CI, is simpler — no emulation involved.

## Troubleshooting

```bash
make help          # list commands
make dryrun        # print the resolved usque command and exit
make shell         # bash inside the container
make logs          # logs
docker compose ps  # state and healthcheck
```

| Message | Cause and fix |
|---|---|
| `Failed to create TUN device: no such device` | the host kernel has no `tun` driver — see "Requirements" |
| `Failed to create TUN device: operation not permitted` | the container was not given `NET_ADMIN` |
| `Failed to get private key` / incomplete config | no config yet: `USQUE_REGISTER=auto` or `docker compose run --rm -e USQUE_MODE=register usque` |
| The tunnel is up but there is no internet | `ROUTE_MODE=none`, or the hook did not run: `docker compose logs usque \| grep route` |
| A request hangs, only `Establishing MASQUE connection` in the log | DPI blocks the SNI — see "Filtering workarounds" |
| `warp=off` when checking through the proxy | traffic bypasses the tunnel: check `ROUTE_MODE` and `dns` |
| Slow or broken name resolution | conflict with `dns:` — see "DNS" |
| `failed to sufficiently increase receive buffer size` | harmless; on the host consider `sysctl -w net.core.rmem_max=7500000 net.core.wmem_max=7500000` |

## Tests

```bash
make test-routes   # routing: main/table/none, endpoint bypass, reconnects
make test-modes    # argument assembly for every mode
```

Both run in throwaway containers: routing is checked in an isolated network namespace, the
command line is checked with a dummy config, nothing goes out to the network and nothing gets
registered. TUN checks are skipped automatically when the kernel has no `tun` driver.

## Repository layout

```
├── Dockerfile                 image build
├── docker-compose.yml         container run + an example client sharing the netns
├── .env.example               all variables, documented
├── entrypoint.sh              mode selection, config, registration, launch
├── hooks/route-hook.sh        routing
├── healthcheck.sh             container health checks
├── config/*.example.json      WARP and Zero Trust config templates
├── tests/                     routing and mode checks
├── README.en.md               this file in English
├── .gitlab-ci.yml             CI: tests and builds
└── Makefile                   make help
```

## License

MIT — see [LICENSE](LICENSE). The usque client itself is not part of this repository: it is
built from upstream [Diniboy1123/usque](https://github.com/Diniboy1123/usque) (MIT as well).
This project is not affiliated with Cloudflare; use it within your ISP's terms and your local
law.
