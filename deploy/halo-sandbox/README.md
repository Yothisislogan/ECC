# Halo sandbox: a locked-down local LLM for the AMD Strix Halo box

A Docker Compose kit that runs a local model on the Ryzen AI Max (Strix Halo,
128 GB) and a coding agent that can reach **only the HTTPS sites you list**.
It has no other outbound ports, publishes no inbound ports, and gives remote
access through Cloudflare Tunnel and Access. A test suite proves the boundary
instead of assuming it.

- [Is ECC a good harness?](#is-ecc-a-good-harness)
- [What this builds](#what-this-builds)
- [What is enforced, and by what](#what-is-enforced-and-by-what)
- [Proof: the boundary test](#proof-the-boundary-test)
- [Setup](#setup)
- [Cloudflare](#cloudflare)
- [Running the WiTNext companion on this box](#running-the-witnext-companion-on-this-box)
- [Using ECC inside the sandbox](#using-ecc-inside-the-sandbox)
- [Day-2 operations](#day-2-operations)
- [What this does not protect against](#what-this-does-not-protect-against)
- [Files](#files)

## Is ECC a good harness?

Short answer: **ECC is not a harness, and installing it as-is works against
your goals on this box.** Keep your fork as a library to copy good pieces from.
Get your security from the sandbox and the network, which is what this kit
does.

What was measured in this fork (v2.2.3):

- **It is an add-on, not a harness.** ECC is a pack of 71 agents, 314 skills,
  98 commands, rules and 27 hook entries that plugs into a harness such as
  Claude Code, Codex, OpenCode or Cursor. It has no sandbox or network control
  of its own, so it cannot give you "web access only to my sites".
- **It is heavy for a local model.** Installing everything (`full`) puts about
  34,000 tokens of skill, agent and command descriptions in front of every
  session. Even the `minimal` profile adds about 12,000, plus about 6,000
  tokens of always-on rules. Frontier cloud models shrug that off. A local
  model pays for it in prompt-processing time on every new session and in
  weaker answers. (The repo's own generated `.claude/rules/ecc-guardrails.md`
  recommends `full`.)
- **It writes tool traffic to disk by default.** With hooks installed, the
  default `standard` profile runs the `observe` hook on every tool call. That
  hook saves up to 5,000 characters of each tool's input and output under
  `~/.local/share/ecc-homunculus/` and keeps archives for about 30 days.
  Secrets are scrubbed, but names, dates of birth, VINs and policy numbers are
  not. For an insurance agency, that is customer data stored where you did not
  mean to keep it.
- **It runs a lot of code on every tool call.** The 27 hook entries start Node
  processes on tool events. Their bootstrap searches several plugin folders for
  code to load, including legacy `everything-claude-code` names that ECC's own
  `SECURITY.md` lists as unofficial packages.
- **It points outward by design.** `mcp-configs/mcp-servers.json` lists 34 MCP
  servers, mostly third-party cloud services. Sixteen are fetched at run time
  with `npx -y` (three of them pinned to `@latest`), and 11 are remote HTTP
  endpoints. That is the opposite of "only my sites".
- **It moves fast.** One maintainer ships high churn. Every upstream pull means
  re-reviewing a lot of code that runs with your agent's permissions.

ECC also has real strengths: it is MIT licensed, its hooks can be gated, its CI
pins actions, and its [security guide](../../the-security-guide.md) recommends
exactly the approach used here: a container, no egress by default, an
allowlisted proxy, and checking the boundary from inside.

**Recommendation:** use Claude Code as the harness, pinned and running inside
this sandbox against the local llama.cpp server. It is tested below. If you
want ECC's workflows, copy three or four agent files into the sandbox (see
[Using ECC inside the sandbox](#using-ecc-inside-the-sandbox)). Leave out the
installer, the hooks and the MCP servers.

## What this builds

```text
                              Internet
                                 |
          TCP 443 + DNS only     |      port 7844 only (optional)
        +------------------------+------------------------+
        |   host firewall: nftables table "inet halo"     |
        |                                                 |
 +------+-----------------+                   +-----------+-----+
 | gateway (Squid)        |                   | cloudflared     |
 | allowlist, ends TLS,   |                   | Cloudflare      |
 | logs every request     |                   | Tunnel          |
 +------+-----------------+                   +-----------+-----+
        |                                                 |
        |  "sandbox" network: internal, no route out      | "llm-edge": internal
        |                                                 |
 +------+-----------------+          +--------------------+-----+
 | agent                  |  HTTP    | llm                      |
 | Claude Code, pinned    +--------->| llama.cpp server,        |
 | sees /workspace only   |          | Vulkan on the Radeon iGPU|
 +------------------------+          +--------------------------+
```

- **llm**: the official llama.cpp server image (Vulkan build), pinned by
  digest. It has only internal networks, so the model server cannot download
  anything or phone home. Its API needs a key.
- **gateway**: the only container that can reach the internet. It allows HTTPS
  to the names in `allowed-domains.txt` and nothing else, and logs every
  request without query strings. Read [Why the gateway ends TLS](#why-the-gateway-ends-tls)
  for why a simple proxy is not enough when your sites sit behind Cloudflare.
- **agent**: Claude Code, pinned to an exact version, as an unprivileged user
  on a read-only filesystem. It trusts only the gateway's private CA, sees only
  `/workspace`, and has telemetry, auto-update, session upload and the WebFetch
  domain lookup to Anthropic switched off by managed policy.
- **cloudflared** (optional): remote access to the model's chat UI through
  Cloudflare Tunnel. It dials out on port 7844, so nothing listens on your
  router.

## What is enforced, and by what

| Requirement | How | Where |
| --- | --- | --- |
| Web access only to your sites | Allowlist in Squid. TLS ends at the gateway, so neither the SNI nor the Host header can be swapped. The sandbox trusts only the gateway CA, which is name-constrained to your domains. | `gateway/` |
| No outbound ports | The sandbox network has no route out. Only the gateway has egress, limited by the host firewall to TCP 443 and DNS. cloudflared is limited to port 7844. LAN, loopback, link-local and CGNAT ranges are dropped. | `compose.yaml`, `host/halo-firewall.nft` |
| No inbound ports | No container publishes a port. Remote access comes in through Cloudflare Tunnel (outbound only) behind Cloudflare Access. | `compose.yaml`, Cloudflare |
| Sandbox cannot reach the host or LAN | The firewall's input chain drops connections from container bridges to the host. Docker's `internal` network alone does **not** do this (see the test output). | `host/halo-firewall.nft` |
| The model server stays offline | Internal networks only, plus `--offline`, read-only model mount and an API key. | `compose.yaml` |
| The harness stays quiet | Managed settings turn off nonessential traffic, the WebFetch preflight, session upload, project MCP auto-enable, project hooks and bypass mode. | `agent/managed-settings.json` |
| Secrets stay out of the sandbox | The Cloudflare Access service token is added by the gateway. No host home folder, SSH keys or Docker socket is mounted. | `gateway/entrypoint.sh`, `compose.yaml` |
| Least privilege everywhere | Non-root users, read-only root filesystems, all capabilities dropped, `no-new-privileges`, process and memory limits, images pinned by digest. | `compose.yaml` |

### Why the gateway ends TLS

Your sites will sit behind Cloudflare, which serves millions of other sites
from the same IP addresses. A plain CONNECT allowlist, or an IP allowlist like
many devcontainer firewalls use, lets the sandbox open a tunnel to your site's
IP and then ask that same IP for any other site. It can do that by changing
the TLS SNI, or by sending a different `Host` header ("domain fronting").

This gateway answers the sandbox's TLS itself with a certificate for the
allowlisted name. It then reads the actual request, checks its host against
the allowlist, and opens its own verified connection using that same name for
both SNI and Host. Whatever the sandbox puts in its TLS handshake never reaches
the internet. The gateway's CA carries X.509 name constraints for your
domains, so even a leaked CA key could not vouch for anyone else's site.

## Proof: the boundary test

`tests/boundary-test.sh` builds the real gateway and agent images. It swaps
the GPU model server for a stub, stands up a fake internet (`allowed.test`,
`evil.test`, a site with an untrusted certificate, a site on a private address,
and a site covered by a shared certificate), and then attacks the sandbox from
the inside. As root it also loads the host firewall and shows the same paths
with and without it. It needs no GPU or model. It uses the internet only to
build the images and to reach two public addresses for the firewall checks.

```bash
docker compose down        # the test uses the same bridge names
sudo tests/boundary-test.sh
```

When this kit was built, every check passed. That covered 25 sandbox probes,
a check that Claude Code talks only to the model endpoint (one request to the
model and zero attempts anywhere else), and 5 host-firewall checks. The
comparison it prints shows why the host firewall matters:

```text
### host firewall (host/halo-firewall.nft)
PASS  gateway network -> 104.16.6.34:443 (HTTPS allowed) (open)
PASS  tunnel network -> 104.16.6.34:443 (only 7844 allowed) (closed)
PASS  gateway network -> 91.189.91.83:80 (other ports dropped) (closed)
PASS  gateway network -> host service 203.0.113.1:11434 (closed)
PASS  sandbox network -> host service 172.19.0.1:11434 (closed)
for comparison, the same paths WITHOUT the firewall (Docker defaults):
  gateway network -> 91.189.91.83:80   open
  tunnel network  -> 104.16.6.34:443  open
  gateway network -> host 203.0.113.1:11434  open
  sandbox network -> host 172.19.0.1:11434  open
```

The last line matters for this box. Without the host firewall, a container on
Docker's `internal` network could still reach any service the host exposes on
its bridge address. That includes an Ollama started with
`OLLAMA_HOST=0.0.0.0`, or `sshd`.

The sandbox probes cover:

- the allowed site works;
- refused: other sites, raw IPs, plain `http://`, other ports, an allowlisted
  name pointing at a LAN address, an allowlisted site whose certificate does
  not verify, Host-header swaps (including to a name the upstream certificate
  covers), SNI swaps, and an SNI-plus-Host swap with certificate checks off;
- no external DNS, no direct TCP to 1.1.1.1 or 8.8.8.8 on 443 or 53, no route
  to host services;
- non-root, no capabilities, read-only root, no Docker socket;
- the Cloudflare Access token is added by the gateway, and one supplied by the
  sandbox is stripped.

After setup, `scripts/verify.sh` runs the same probes against the live stack
with your real allowlist.

## Setup

### 1. The machine

These choices matter more than anything in this repo.

- **Disk encryption.** Install with full-disk encryption (LUKS). It protects
  models, workspaces and any customer data if the box walks away.
- **Firmware.** Update the BIOS. Turn on Secure Boot and set a firmware admin
  password. Leave the IOMMU (AMD-Vi) on. Set the dedicated graphics memory (UMA
  frame buffer) to its minimum; Linux hands the GPU memory dynamically (next
  step).
- **OS.** Fedora is a good default for Strix Halo because it ships current
  kernels. Ubuntu 24.04 with the HWE kernel, or newer, also works. Containers
  bring their own user-space GPU drivers, so mainly the host kernel matters.
- **GPU memory.** By default the GPU can only map about half of the 128 GB. To
  allow about 104 GiB, leaving about 24 GiB for the OS, containers and the
  WiTNext companion, set (pages are 4 KiB, so GiB x 262144):

  ```bash
  # Fedora
  sudo grubby --update-kernel=ALL --args="ttm.pages_limit=27262976 ttm.page_pool_size=27262976"
  # Ubuntu: add the same two options to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub, then
  sudo update-grub
  ```

  After a reboot, `cat /sys/module/ttm/parameters/pages_limit` should show the
  new value. Recent kernels deprecate the older `amdgpu.gttsize` option.
- **Do not turn off the IOMMU.** Strix Halo tuning guides often add
  `amd_iommu=off` for a 5 to 12 percent speed-up ([kyuz0 toolboxes](https://github.com/kyuz0/amd-strix-halo-toolboxes)).
  The IOMMU is what stops a Thunderbolt or USB4 device from reading memory
  directly. On a security-first box, keep it on.
- **Updates.** Enable automatic security updates (`dnf-automatic` on Fedora,
  `unattended-upgrades` on Ubuntu) and reboot for kernel updates. Container
  isolation is only as good as the kernel.
- **Inbound firewall.** Use the `drop` default zone in firewalld, or
  `ufw default deny incoming`. Add no port forwards on your router, and turn
  off UPnP there. Ports that Docker publishes bypass ufw and firewalld; this
  kit publishes none.
- **Accounts and SSH.** Use key-only SSH (`PasswordAuthentication no`,
  `PermitRootLogin no`), reached only through Cloudflare Access (see
  [Admin access without opening port 22](#admin-access-without-opening-port-22))
  or Tailscale. Or turn sshd off if you sit at the box. Membership of the
  `docker` group is equivalent to root, so treat it that way.

### 2. Docker and the host firewall

Install Docker Engine 28 or newer from Docker's own repository, plus
`nftables`. Podman's Docker shim is not tested with this kit. On Fedora, Docker
runs containers without SELinux labelling unless you set `selinux-enabled` in
`/etc/docker/daemon.json`. This kit was tested that way; if you turn it on,
add `:z` to the bind mounts in `compose.yaml` and confirm the GPU still works
(`docker compose logs llm`). Then install the firewall so it loads at boot
**before** Docker:

```bash
sudo install -D -m 0644 host/halo-firewall.nft /etc/halo/halo-firewall.nft
sudo install -m 0644 host/halo-firewall.service /etc/systemd/system/halo-firewall.service
sudo systemctl daemon-reload
sudo systemctl enable --now halo-firewall.service
sudo systemctl restart docker
sudo nft list table inet halo
```

It is a separate nftables table that Docker never touches. A drop in any
nftables chain is final, so Docker's own rules cannot override it. It fails
closed: if it cannot load, Docker does not start.

If you change `HALO_DNS_PRIMARY` or `HALO_DNS_SECONDARY` in `.env`, also change
`HALO_DNS` at the top of the `.nft` file. The file also contains a commented,
optional "no outbound ports" policy for the host itself. Try it from a local
console, because it blocks anything other than DNS, DHCP, NTP, HTTPS and the
tunnel port.

### 3. A model

Download models **on the host**; the sandbox has no route to Hugging Face. Use
the official organisations' GGUF files, check their SHA-256 against the model
page, and make them read-only (`chmod a-w`). Never load pickle-format weights.

On 128 GB of shared memory with about 256 GB/s of bandwidth, mixture-of-experts
models with few active parameters are the sweet spot. Examples available when
this was written:

- `gpt-oss-120b` in MXFP4, about 63 GB, from `ggml-org/gpt-oss-120b-GGUF`.
  Good all-round agent with room for a long context.
- `Qwen3-Coder-30B-A3B`, about 18 to 35 GB depending on quantisation. Very
  fast, and strong at code.
- `GLM-4.5-Air`, about 60 to 75 GB at 4-bit.

Dense 70B models fit but run slowly on this memory bandwidth. Point
`LLM_MODEL_FILE` at the first part of a split GGUF (`...-00001-of-0000N.gguf`).
The model server runs offline, read-only and unprivileged, because GGUF
parsers have had memory-safety bugs. Load only models you trust, and keep the
image current.

### 4. Configure

Run as your normal user, not with sudo:

```bash
cd deploy/halo-sandbox
scripts/setup.sh
```

It creates `.env` (mode 600) with your UID, GIDs and a fresh API key, then
generates the gateway CA. Edit `.env` to set `HALO_MODELS_DIR`,
`LLM_MODEL_FILE`, `LLM_CTX_SIZE` and `HALO_WORKSPACE` (the only folder the
agent can see).

Then list your sites in `allowed-domains.txt`. Use one per line; a leading dot
covers subdomains. Re-create the CA whenever the list changes:

```bash
scripts/make-ca.sh
```

The gateway refuses wildcards, IP addresses, URLs, ports and whole top-level
domains. Do not list shared suffixes such as `.co.uk` either. Keep off any site
that accepts uploads, comments or other user content, such as GitHub,
pastebins, chat apps or search engines. A prompt-injected model could use it to
send your data out.

### 5. Start and verify

```bash
docker compose up -d
docker compose logs -f llm          # wait until the server reports it is listening
scripts/verify.sh docs.example.com  # an allowlisted host; add a blocked host as 2nd argument
```

Run `sudo tests/boundary-test.sh` once as well, with the stack down.

### 6. Use the agent

```bash
docker compose run --rm agent claude
```

- The agent sees `HALO_WORKSPACE` as `/workspace` and nothing else. Never put
  real `.env` files, SSH keys or cloud credentials there.
- Git: the agent commits locally and has no route to GitHub. Bring its work
  into your real clone with `git fetch /path/to/workspace/repo` and review the
  diff before you push (see [What this does not protect against](#what-this-does-not-protect-against)
  for why not to run git inside the agent's copy on the host).
- Packages: there is no registry access. Install dependencies on the host
  before a session. A registry is not a site you control, so allowlist one only
  deliberately and temporarily.
- Permission prompts stay on; managed policy disables bypass mode. Read what
  you approve.
- `docker compose logs gateway` shows every site the agent asked for.

## Cloudflare

### Remote access with Tunnel and Access (no open ports)

1. In Cloudflare Zero Trust, create a tunnel (Networks > Tunnels, connector
   cloudflared) and put its token in `.env` as `CLOUDFLARE_TUNNEL_TOKEN`.
2. Add a public hostname such as `chat.example.com` with service
   `http://llm:8080`.
3. **Before starting the tunnel**, create an Access application (Access >
   Applications > Self-hosted) for that hostname. Use an Allow policy for your
   own identity: your Google Workspace login, as WiTNext already does. Keep the
   session duration short.
4. Start it: `docker compose --profile tunnel up -d`.

The llama.cpp web UI needs `LLM_API_KEY` (enter it in its settings), a second
lock behind Access.
cloudflared only dials out on port 7844 ([Cloudflare: tunnel with firewall](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/)).
It can reach only the llm container, not the agent.

### Letting the agent read your Access-protected sites

1. Create a service token (Access > Service Auth > Service Tokens).
2. On each site's Access application, add a policy with action **Service
   Auth** that includes that token. Add it only to the apps the agent needs.
3. Put the token in `.env` (`CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`)
   and the hostnames in `cf-access-domains.txt`. Those hostnames must also be
   allowlisted.
4. Recreate the gateway: `docker compose up -d --force-recreate gateway`.

The gateway adds the token to requests for those hosts. It never enters the
sandbox, so the model cannot read or leak it. Cloudflare's Access logs then
show every request the agent makes to your sites. Cloudflare itself also
rejects requests whose SNI and Host disagree ([error 421](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/4xx-client-error/error-421/)),
an outside layer on top of the gateway's own check.

### Optional: Cloudflare Gateway DNS

For a second allowlist outside this box, plus DNS logs in your Cloudflare
dashboard, point the gateway's resolvers at a Zero Trust DNS location with an
allow-only policy for your domains. Set `HALO_DNS_PRIMARY` and
`HALO_DNS_SECONDARY`, and the `HALO_DNS` define in the firewall file, to that
location's resolver addresses.

### Admin access without opening port 22

Run a separate cloudflared on the host (Cloudflare's package, as a systemd
service) with a hostname such as `ssh.example.com` pointing at
`ssh://localhost:22`. Protect it with an Access application, and connect with
`cloudflared access ssh`. Alternatively use Tailscale, or keep sshd off.

## Running the WiTNext companion on this box

The Halo can run far larger models than the G14, which has 6 GB of VRAM. But
the companion handles customer data, so keep it in its own trust zone:

- Run Ollama natively as `docs/local-ai-companion.md` in WiTNext describes:
  bound to `127.0.0.1`, with `OLLAMA_NO_CLOUD=1`. Do not point the coding agent
  at it, and do not point the companion at this kit's llama.cpp. Separate
  workloads get separate model servers, because a shared server shares state
  such as prompt caches.
- Install the companion under its own Linux user, not your admin account and
  not the agent's UID. Its `config.json` holds the worker token.
- The host firewall's input chain stops sandbox containers from reaching the
  host's Ollama even if it were bound to `0.0.0.0` (tested above).
- The optional host "no outbound ports" policy still allows the companion's
  HTTPS calls to your Cloudflare-fronted WiTNext.
- Both models share the GPU memory pool, so size `ttm.pages_limit` and
  `LLM_CTX_SIZE` to fit both.
- Change the production model only through WiTNext's own comparison and
  evaluation gates (see `docs/customer-insight-evaluation.md` in WiTNext).

## Using ECC inside the sandbox

Copy a few agents from your fork into the sandbox's home volume. The volume
persists between sessions:

```bash
docker compose run --rm -v "$PWD/../../agents:/ecc:ro" agent \
  sh -c 'mkdir -p ~/.claude/agents && cp /ecc/planner.md /ecc/code-reviewer.md /ecc/security-reviewer.md /ecc/tdd-guide.md ~/.claude/agents/'
```

Their `model:` lines (`opus`, `sonnet`) map to your local model through the
environment in `compose.yaml`. Do not run ECC's installer in the sandbox. Its
hooks would be ignored anyway, because managed policy allows only managed
hooks.

## Day-2 operations

- **Update deliberately.** Every image is pinned by digest. To move up, look up
  a newer tag and its digest, for example
  `docker buildx imagetools inspect ghcr.io/ggml-org/llama.cpp:server-vulkan-bNNNNN`.
  Edit `compose.yaml`, re-run `sudo tests/boundary-test.sh`, then
  `docker compose pull && docker compose up -d`. Bump `CLAUDE_CODE_VERSION` in
  `agent/Dockerfile` the same way.
- **Rebuild monthly** for Ubuntu security fixes (Squid included):
  `docker compose build --pull && docker compose up -d`.
- **Rotate secrets.** For `LLM_API_KEY`, edit `.env` and run
  `docker compose up -d`. For the CA, run `scripts/make-ca.sh --force`, then
  recreate the gateway and start a new agent session. Rotate Cloudflare tokens
  in the dashboard.
- **Kill switch.** `docker compose stop gateway` cuts all web access at once.
  `docker compose down` stops everything.
- **Networks that inspect TLS.** If Cloudflare Gateway decrypts this box's
  traffic, paste its root CA into `build-ca.pem` before building. It is used
  only during the build and never stored in the image.

## What this does not protect against

- **Allowed sites are a channel.** Anything the agent can send to an allowed
  site reaches it. Only list sites you control.
- **The workspace is the agent's to change.** It can write code that runs later
  on your host: build scripts, package scripts, or a `.git/hooks` file or
  `.git/config` setting (`core.fsmonitor`, `core.sshCommand`, filters) that
  runs when **you** use git there. Review diffs, and bring changes into your
  real clone with `git fetch` rather than running git in the agent's copy.
- **Containers share the host kernel.** A kernel exploit escapes any container.
  Keep the kernel patched. For more isolation, run the stack in a VM or under
  rootless Docker; neither is covered by the test.
- **Models can misbehave by design.** A backdoored model is contained, not
  prevented. Use trusted sources.
- **Approval prompts only help if you read them.**
- **Prompt injection from your own sites** is still possible if those sites
  host other people's content.
- **The tunnel exposes the chat UI** to whoever passes your Access policy.
  Keep that policy tight.

## Files

| Path | Purpose |
| --- | --- |
| `compose.yaml` | The stack: llm, gateway, agent (profile `agent`) and cloudflared (profile `tunnel`) |
| `allowed-domains.txt` | The allowlist. Empty means no web access. |
| `cf-access-domains.txt` | Allowlisted hosts that get the Cloudflare Access service token |
| `.env.example` | Settings; `scripts/setup.sh` creates `.env` from it |
| `gateway/` | Squid image, config and start-up checks |
| `agent/` | Claude Code image, managed policy and the note the agent reads about its sandbox |
| `host/halo-firewall.nft`, `host/halo-firewall.service` | Host firewall, loaded before Docker |
| `scripts/setup.sh` | First-time setup |
| `scripts/make-ca.sh` | Gateway CA with name constraints from the allowlist |
| `scripts/verify.sh`, `scripts/probe.sh` | Live checks against the running stack |
| `tests/` | Hermetic boundary test (fake internet, stub model, firewall before and after) |

References: [llama.cpp Anthropic Messages API](https://huggingface.co/blog/ggml-org/anthropic-messages-api-in-llamacpp),
[CVE-2024-29018 (DNS from Docker internal networks)](https://www.cvelogic.com/cve/CVE-2024-29018),
[Strix Halo memory settings](https://github.com/kyuz0/amd-strix-halo-toolboxes).
