#!/usr/bin/env bash
# vless-link.sh — generates a vless:// share link (and optionally a QR code)
# from a working Xray config (VLESS + REALITY, TCP/RAW or XHTTP transport).
#
# Run on the VPS:
#   sudo bash vless-link.sh                 # default config
#   sudo bash vless-link.sh -c /path/to/config.json
#
# Changes nothing in the config or the system (except installing qrencode, if you agree).

set -euo pipefail

CONFIG="/usr/local/etc/xray/config.json"
XRAY_BIN="$(command -v xray 2>/dev/null || echo /usr/local/bin/xray)"
SEP=$'\x1f'   # field separator (non-whitespace, so empty fields are kept)

# ---------- helpers ----------

die()  { echo -e "\e[31mError:\e[0m $*" >&2; exit 1; }
warn() { echo -e "\e[33m$*\e[0m" >&2; }
info() { echo -e "\e[36m$*\e[0m" >&2; }

# ask "Question" "default value" -> prints the answer
ask() {
  local prompt="$1" def="${2-}" ans
  if [[ -n $def ]]; then
    read -rp "$prompt [$def]: " ans </dev/tty
  else
    read -rp "$prompt: " ans </dev/tty
  fi
  echo "${ans:-$def}"
}

# choose "Title" option1 option2 ... -> prints the index (from 0)
choose() {
  local title="$1"; shift
  local n=$# i=1 opt ans
  echo >&2
  echo "$title" >&2
  for opt in "$@"; do
    echo "  $i) $opt" >&2
    i=$((i + 1))
  done
  while :; do
    read -rp "Choice [1]: " ans </dev/tty
    ans="${ans:-1}"
    if [[ $ans =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= n )); then
      echo $((ans - 1))
      return
    fi
    echo "Invalid choice" >&2
  done
}

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# ---------- arguments ----------

while getopts "c:h" opt; do
  case $opt in
    c) CONFIG="$OPTARG" ;;
    h) sed -n '2,10p' "$0"; exit 0 ;;
    *) exit 1 ;;
  esac
done

# ---------- checks ----------

command -v python3 >/dev/null 2>&1 || die "python3 is required (apt install -y python3)"
[[ -x $XRAY_BIN ]] || die "xray not found ($XRAY_BIN)"
[[ -f $CONFIG ]]   || die "config not found: $CONFIG"
[[ -r $CONFIG ]]   || die "cannot read $CONFIG — run with sudo"

# ---------- config parsing ----------
# First try 'xray run -dump' (Xray parses the config itself, comments included).
# If that fails, parse it ourselves, stripping // and /* */ comments.

DUMP="$("$XRAY_BIN" run -dump -c "$CONFIG" 2>/dev/null || true)"

ENTRIES="$(DUMP="$DUMP" python3 - "$CONFIG" <<'PY'
import json, os, re, sys

def strip_comments(s):
    out, i, n, in_str = [], 0, len(s), False
    while i < n:
        c = s[i]
        if in_str:
            out.append(c)
            if c == '\\' and i + 1 < n:
                out.append(s[i + 1]); i += 2; continue
            if c == '"':
                in_str = False
            i += 1; continue
        if c == '"':
            in_str = True; out.append(c); i += 1; continue
        if s.startswith('//', i):
            j = s.find('\n', i); i = n if j < 0 else j; continue
        if s.startswith('/*', i):
            j = s.find('*/', i + 2); i = n if j < 0 else j + 2; continue
        out.append(c); i += 1
    t = ''.join(out)
    return re.sub(r',(\s*[}\]])', r'\1', t)  # trailing commas

cfg = None
dump = os.environ.get('DUMP', '').strip()
if dump:
    try:
        cfg = json.loads(dump[dump.index('{'):])
    except Exception:
        cfg = None
if cfg is None:
    try:
        with open(sys.argv[1], encoding='utf-8') as f:
            cfg = json.loads(strip_comments(f.read()))
    except Exception as e:
        print(f"PARSE_ERROR{chr(31)}{e}")
        sys.exit(0)

SEP = '\x1f'
for ii, ib in enumerate(cfg.get('inbounds') or []):
    if (ib.get('protocol') or '').lower() != 'vless':
        continue
    ss = ib.get('streamSettings') or {}
    if (ss.get('security') or '').lower() != 'reality':
        continue
    rs = ss.get('realitySettings') or {}
    net = (ss.get('network') or 'tcp').lower()
    xs = ss.get('xhttpSettings') or ss.get('splithttpSettings') or {}
    port = ib.get('port', '')
    clients = (ib.get('settings') or {}).get('clients') or []
    for ci, cl in enumerate(clients):
        fields = [
            str(ii), str(port), net, str(ci),
            cl.get('id', ''), cl.get('flow', '') or '', cl.get('email', '') or '',
            rs.get('privateKey', ''),
            ','.join(rs.get('serverNames') or []),
            ','.join(rs.get('shortIds') or []),
            xs.get('path', '') or '', xs.get('mode', '') or '', xs.get('host', '') or '',
        ]
        print(SEP.join(f.replace(SEP, ' ').replace('\n', ' ') for f in fields))
PY
)"

[[ $ENTRIES == PARSE_ERROR* ]] && die "failed to parse config: ${ENTRIES#PARSE_ERROR$SEP}"
[[ -n $ENTRIES ]] || die "no VLESS + REALITY inbounds with clients found in config"

mapfile -t LINES <<<"$ENTRIES"

# ---------- client selection ----------

LABELS=()
for line in "${LINES[@]}"; do
  IFS="$SEP" read -r ii port net ci uuid flow email _ <<<"$line"
  label="port $port, $net, client #$((ci + 1))"
  [[ -n $email ]] && label+=" ($email)"
  label+=" — ${uuid:0:8}…"
  LABELS+=("$label")
done

SELECTED=()
if (( ${#LINES[@]} == 1 )); then
  SELECTED=(0)
  info "Found one client: ${LABELS[0]}"
else
  idx=$(choose "Several clients found. Which one to make a link for?" "${LABELS[@]}" "All")
  if (( idx == ${#LINES[@]} )); then
    for ((k = 0; k < ${#LINES[@]}; k++)); do SELECTED+=("$k"); done
  else
    SELECTED=("$idx")
  fi
fi

# ---------- common parameters ----------

detect_ip() {
  local ip=""
  ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [[ ! $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
  fi
  echo "$ip"
}

DEF_ADDR="$(detect_ip)"
ADDR="$(ask "Server address (IP or domain)" "$DEF_ADDR")"
[[ -n $ADDR ]] || die "no address given"
# IPv6 must be in square brackets in the link
if [[ $ADDR == *:* && $ADDR != \[*\] ]]; then
  ADDR_FMT="[$ADDR]"
else
  ADDR_FMT="$ADDR"
fi

FPS=(chrome firefox safari edge)
FP="${FPS[$(choose "TLS fingerprint:" "${FPS[@]}")]}"

QR_MODE=$(choose "What to output?" \
  "Link only" \
  "Link + QR code in terminal" \
  "Link + QR code in terminal + PNG file")

if (( QR_MODE > 0 )) && ! command -v qrencode >/dev/null 2>&1; then
  yn="$(ask "qrencode is not installed. Install it? (y/n)" "y")"
  if [[ $yn =~ ^[Yy] ]]; then
    apt-get install -y qrencode >/dev/null || die "failed to install qrencode"
  else
    warn "Skipping QR code, link only."
    QR_MODE=0
  fi
fi

# ---------- public key ----------

declare -A PBK_CACHE=()
get_pbk() {
  local priv="$1" pbk
  if [[ -z ${PBK_CACHE[$priv]+x} ]]; then
    # Newer Xray versions call it "Password", older ones "Public key"
    pbk="$("$XRAY_BIN" x25519 -i "$priv" 2>/dev/null | awk '/Password|Public key|PublicKey/ { print $NF; exit }')"
    [[ -n $pbk ]] || die "failed to derive public key from privateKey (xray x25519 -i)"
    PBK_CACHE[$priv]="$pbk"
  fi
  echo "${PBK_CACHE[$priv]}"
}

# ---------- generation ----------

for k in "${SELECTED[@]}"; do
  IFS="$SEP" read -r ii port net ci uuid flow email priv snis sids xpath xmode xhost <<<"${LINES[$k]}"

  echo >&2
  info "=== ${LABELS[$k]} ==="

  [[ -n $uuid ]] || { warn "client has no id — skipping"; continue; }
  [[ -n $priv ]] || { warn "no privateKey in realitySettings — skipping"; continue; }

  # SNI: ask if there are several serverNames
  IFS=',' read -r -a SNI_LIST <<<"$snis"
  if (( ${#SNI_LIST[@]} == 0 )); then
    warn "serverNames is empty — skipping"; continue
  elif (( ${#SNI_LIST[@]} == 1 )); then
    sni="${SNI_LIST[0]}"
  else
    sni="${SNI_LIST[$(choose "Which SNI to use?" "${SNI_LIST[@]}")]}"
  fi

  # shortId: first non-empty one (an empty shortId is also valid)
  sid=""
  IFS=',' read -r -a SID_LIST <<<"$sids"
  for s in "${SID_LIST[@]}"; do
    if [[ -n $s ]]; then sid="$s"; break; fi
  done

  pbk="$(get_pbk "$priv")"

  q="encryption=none"
  [[ -n $flow ]] && q+="&flow=$(urlencode "$flow")"
  q+="&security=reality&sni=$(urlencode "$sni")&fp=$FP&pbk=$(urlencode "$pbk")"
  q+="&sid=$(urlencode "$sid")"

  case $net in
    tcp|raw)
      q+="&type=tcp"
      ;;
    xhttp|splithttp)
      [[ -z $xmode || $xmode == auto ]] && xmode="auto"
      q+="&type=xhttp&path=$(urlencode "${xpath:-/}")&mode=$(urlencode "$xmode")"
      [[ -n $xhost ]] && q+="&host=$(urlencode "$xhost")"
      ;;
    *)
      warn "transport '$net' is not supported (only tcp/raw and xhttp) — skipping"
      continue
      ;;
  esac

  def_name="$(hostname)-$port"
  [[ -n $email ]] && def_name="$email"
  (( ${#SELECTED[@]} > 1 && ${#LINES[@]} > 1 )) && [[ -z $email ]] && def_name+="-$((ci + 1))"
  name="$(ask "Name in client app" "$def_name")"

  link="vless://${uuid}@${ADDR_FMT}:${port}?${q}#$(urlencode "$name")"

  echo
  echo "$link"
  echo

  if (( QR_MODE >= 1 )); then
    qrencode -t ansiutf8 "$link"
  fi
  if (( QR_MODE == 2 )); then
    safe_name="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')"
    png="./vless-${safe_name}.png"
    qrencode -s 8 -o "$png" "$link"
    chmod 600 "$png"
    info "PNG saved: $(realpath "$png") (owner-only access)"
  fi
done

echo >&2
warn "The link contains everything needed to connect to your server — do not share it publicly."
warn "If it leaks, change the client UUID in the config and restart xray."
