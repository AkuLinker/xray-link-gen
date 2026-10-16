# xray-link-gen

Generate `vless://` share links and QR codes from a working Xray config (VLESS + REALITY, TCP/XHTTP). Run it on the VPS — no manual copying of UUIDs, keys and shortIds.

The script only reads the config. It doesn't change Xray, the config or the service.

## Requirements

- Xray installed and configured (VLESS + REALITY inbound)
- `python3` (present on Debian/Ubuntu by default)
- `qrencode` — only for QR codes; the script offers to install it if missing

## Usage

```bash
curl -LO https://raw.githubusercontent.com/AkuLinker/vless-link/main/vless-link.sh
sudo bash vless-link.sh
```

Custom config path:

```bash
sudo bash vless-link.sh -c /path/to/config.json
```

`sudo` is needed if the config is readable only by root (recommended, since it contains the private key).

## What it asks

1. **Client** — if the config has several clients/inbounds, pick one or all
2. **Server address** — public IPv4 is detected automatically; you can enter a domain or IPv6 instead
3. **Fingerprint** — `chrome`, `firefox`, `safari` or `edge`
4. **Output** — link only / link + QR in terminal / link + QR + PNG file
5. **Name** — how the server will be shown in the client app

## What it takes from the config

| Link parameter | Source |
|---|---|
| UUID, `flow` | `settings.clients` |
| port | inbound `port` |
| `sni` | `realitySettings.serverNames` (asks if several) |
| `sid` | first non-empty `realitySettings.shortIds` |
| `pbk` | derived from `privateKey` via `xray x25519 -i` |
| `type`, `path`, `mode`, `host` | `streamSettings` / `xhttpSettings` |

Supported transports: `tcp`/`raw` and `xhttp`. Other inbounds are skipped.

Comments (`//`, `/* */`) in the config are fine.

## Importing the link

- **v2rayN / Throne (desktop):** copy the link → import from clipboard
- **v2rayNG / ThroneForAndroid:** `+` → import from clipboard or scan QR

## Security

The link contains everything needed to connect to your server. Don't post it publicly. If it leaks, change the client's UUID in the config and restart Xray.

PNG files are saved with `600` permissions in the current directory — delete them after use.
