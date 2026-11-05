#!/bin/bash
# =============================================================================
# countly_ignite_komodo -- a new Countly Docker server, managed by prod Komodo.
#
#   countly_ignite_komodo                       interactive: a new server
#   countly_ignite_komodo --continue <customer> resume a run after its last finished step
#   countly_ignite_komodo --render <state-file> print the customers-docker TOML only
#
# Flow (each step is recorded in the state file; --continue starts after the last one):
#    1 reserve the static IP            7 open the countly-deployment PR
#    2 create the VM and data disks     8 wait for the merge, sync this Server + Stack only
#    3 wait for SSH                     9 clone the release, seed /opt/countly, certificate
#    4 initialise the data disks       10 Deploy through Komodo, wait for /o/ping
#    5 Cloudflare DNS                  11 admin user, demo app, api.domain
#    6 join Komodo (one-time onboarding key, deleted straight after)
#
# Secrets: none in this file. Read at run time from Secret Manager (project countly-tools)
# with the operator's own gcloud login, held in shell variables only, and handed to curl
# through process substitution so they never appear in `ps`, the log or on screen.
#
# Instance types: prod (3 data disks), prod-dev (1 combined disk). Trials keep using
# countly_ignite (decision 2026-11-02).
# =============================================================================
set -Eeuo pipefail

# --- Constants (not secret) --------------------------------------------------
KOMODO_URL=https://komodo.count.ly
SECRETS_PROJECT=countly-tools
IMAGE_PROJECT=countly-01
IMAGE_PREFIX=countly-docker-komodo-
CF_ZONE_NAME=count.ly
DEPLOY_REPO=Countly/countly-deployment
RELEASE_REPO=Countly/compose-release
CUSTOMER_DIR=/opt/countly
STACK_ROOT=/opt/countly/komodo/stacks
# Pinned: a change on countly-devops main must not silently change provisioning.
INIT_3DISK_URL='https://raw.githubusercontent.com/Countly/countly-devops/b0926f5923067118a5f322bd4f626d7fc0546193/snippets/prod_data_disk_initialization/init_new_arch_data_disk.sh'
STATE_DIR=/var/log/countly-ignite
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TEMPLATE="$HERE/customers-docker.toml.tmpl"

# Secret Manager names
S_KOMODO_KEY=ignite-komodo-api-key
S_KOMODO_SECRET=ignite-komodo-api-secret
S_CF_TOKEN=ignite-cloudflare-dns-token
S_GH_TOKEN=ignite-github-token      # fine-grained PAT: countly-deployment + compose-release, contents + pull requests write
S_CERT_CHAIN=countly-wildcard-fullchain
S_CERT_KEY=countly-wildcard-privkey
S_MAIL_TOKEN=countly-postmark-smtp-token  # Postmark server token: SMTP user and password are both this value

# --- Helpers -----------------------------------------------------------------
say()  { printf '%s\n' "$*"; }
step() { printf '\n  [%s/11] %s\n' "$1" "$2"; }
die()  { printf '\n  ERROR: %s\n' "$*" >&2; exit 1; }

askQ() {
  echo ""; echo "  $1"; shift
  local i=1 opt; for opt in "$@"; do echo "    #$i - $opt"; i=$((i + 1)); done; echo ""
}

secret() {  # <name>: value on stdout (callers capture it; never echo it)
  gcloud secrets versions access latest --secret "$1" --project "$SECRETS_PROJECT" 2>/dev/null \
    || die "cannot read secret $1 in $SECRETS_PROJECT (exists? secretAccessor for $(gcloud config get-value account 2>/dev/null)?)"
}

# HTTP with the credential in a header file (process substitution), never on the command line.
# Prints the body; returns non-zero on a status >= 300.
http() {  # <method> <url> <header-line> [json-body]
  local out code
  out="$(curl -sS -X "$1" "$2" -H 'Content-Type: application/json' -H 'Accept: application/json' \
    -H @<(printf '%s\n' "$3") ${4:+-d "$4"} -w '\n%{http_code}')" || return 1
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  printf '%s' "$out"
  [ "$code" -lt 300 ]
}

komodo() {  # <read|write|execute> <Type> [params-json]
  local out code body params="${3:-}"
  [ -n "$params" ] || params='{}'
  body="$(jq -cn --arg t "$2" --argjson p "$params" '{type: $t, params: $p}')"
  out="$(curl -sS -X POST "$KOMODO_URL/$1" -H 'Content-Type: application/json' \
    -H @<(printf 'x-api-key: %s\nx-api-secret: %s\n' "$KOMODO_KEY" "$KOMODO_SECRET") \
    -d "$body" -w '\n%{http_code}')" || return 1
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  printf '%s' "$out"
  [ "$code" -lt 300 ]
}

cf() { http "$1" "https://api.cloudflare.com/client/v4$2" "Authorization: Bearer $CF_TOKEN" "${3:-}"; }
gh() { http "$1" "https://api.github.com$2" "Authorization: Bearer $GH_TOKEN" "${3:-}"; }

vm_ssh() { gcloud compute ssh --project "$PROJECT" --zone "$ZONE" "$MACHINE_NAME" --quiet -- "$@"; }
vm_scp() { gcloud compute scp --project "$PROJECT" --zone "$ZONE" "$1" "${MACHINE_NAME}:$2"; }

load_secrets() {
  KOMODO_KEY="$(secret "$S_KOMODO_KEY")"
  KOMODO_SECRET="$(secret "$S_KOMODO_SECRET")"
  CF_TOKEN="$(secret "$S_CF_TOKEN")"
  GH_TOKEN="$(secret "$S_GH_TOKEN")"
  # Used only in step 9; checked here so a missing secret stops the run before anything exists.
  local s
  for s in "$S_CERT_CHAIN" "$S_CERT_KEY" "$S_MAIL_TOKEN"; do
    gcloud secrets versions describe latest --secret "$s" --project "$SECRETS_PROJECT" >/dev/null 2>&1 \
      || die "cannot read secret $s in $SECRETS_PROJECT (exists? secretAccessor for $(gcloud config get-value account 2>/dev/null)?)"
  done
}

# --- State file (no secrets) -------------------------------------------------
STATE_VARS=(CUSTOMER_NAME CUSTOMER_TYPE PROJECT REGION ZONE MACHINE_NAME MACHINE_TYPE TIER TIER_LOWER
  DATA_DISK_SIZE MONGODB_DIRECTORYPERDB MONGODB_WIREDTIGER_DIRECTORY_FOR_INDEXES ENABLE_OBS
  FLAVOR LANE RELEASE_TAG COMMIT RELEASE VERSION_LABEL IMAGE LE_DOMAIN LE_EMAIL API_TRAFFIC_ACCESS
  LE_API_TRAFFIC_ACCESS API_ROOT_REDIRECT LE_ROOT_REDIRECT CLY_INIT_USER_UID INSTANCE_ENV DATA_CLASS
  CUSTOMER_IP CF_ZONE_ID CF_RECORD_IDS KOMODO_SERVER_ID PR_URL OPERATOR STARTED DONE)

save_state() {
  local v; mkdir -p "$STATE_DIR"
  { for v in "${STATE_VARS[@]}"; do printf '%s=%q\n' "$v" "${!v:-}"; done; } > "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}
mark_done() { DONE="$1"; save_state; }

# What exists so far, and how to remove it. Printed when a run stops before the end.
print_undo() {
  [ "${DONE:-0}" -ge 11 ] && return 0
  echo ""
  echo "  Stopped after step ${DONE:-0}/11. Fix the cause, then resume with:"
  echo "    countly_ignite_komodo --continue ${CUSTOMER_NAME}"
  echo "  Or remove what was created (newest first) and start again:"
  [ -n "${PR_URL:-}" ]           && echo "    - close ${PR_URL} and delete branch ignite/${CUSTOMER_NAME} (if not merged; if merged, revert it)"
  [ -n "${KOMODO_SERVER_ID:-}" ] && echo "    - Komodo: delete Server ${CUSTOMER_NAME} (a re-run needs it gone: onboarding keys cannot fix an existing Server)"
  [ -n "${CF_RECORD_IDS:-}" ]    && echo "    - Cloudflare ${CF_ZONE_NAME}: delete A record(s) ${CUSTOMER_NAME}${LE_DOMAIN:+ and ${LE_DOMAIN}}"
  if [ "${DONE:-0}" -ge 2 ]; then
    echo "    - gcloud compute instances update ${MACHINE_NAME} --no-deletion-protection --project ${PROJECT} --zone ${ZONE}"
    echo "      gcloud compute instances delete ${MACHINE_NAME} --project ${PROJECT} --zone ${ZONE}"
    if [ "$CUSTOMER_TYPE" = prod ]; then
      echo "      gcloud compute disks delete ${MACHINE_NAME}-mongodb-disk ${MACHINE_NAME}-clickhouse-disk ${MACHINE_NAME}-kafka-disk --project ${PROJECT} --zone ${ZONE}"
    else
      echo "      gcloud compute disks delete ${MACHINE_NAME}-data-disk --project ${PROJECT} --zone ${ZONE}"
    fi
  fi
  [ "${DONE:-0}" -ge 1 ] && echo "    - gcloud compute addresses delete ${CUSTOMER_NAME}-ip --region ${REGION} --project ${PROJECT}"
  echo "    - rm ${STATE_FILE}"
}

# --- customers-docker TOML ---------------------------------------------------
render_toml() {
  local data_dirs
  if [ "$CUSTOMER_TYPE" = prod ]; then data_dirs="/mongodb-data, /clickhouse-data, /kafka-data"; else data_dirs="/data (combined)"; fi
  sed -e "s|@NAME@|${CUSTOMER_NAME}|g" -e "s|@VM@|${MACHINE_NAME}|g" -e "s|@PROJECT@|${PROJECT}|g" \
      -e "s|@ZONE@|${ZONE}|g" -e "s|@REGION@|${REGION}|g" -e "s|@MACHINE_TYPE@|${MACHINE_TYPE}|g" \
      -e "s|@TIER@|${TIER}|g" -e "s|@LANE@|${LANE}|g" -e "s|@COMMIT@|${COMMIT}|g" \
      -e "s|@COMMIT_SHORT@|${COMMIT:0:7}|g" -e "s|@RELEASE@|${RELEASE}|g" -e "s|@DATA_DIRS@|${data_dirs}|g" \
      -e "s|@DATE@|${STARTED%%T*}|g" -e "s|@OPERATOR@|${OPERATOR}|g" "$TEMPLATE"
}

# --- Customer .env overrides (no secrets; applied on the VM after seeding) ---
render_overrides() {
  local profiles=""
  [ -n "$ENABLE_OBS" ] && profiles="observability"
  [ -n "$LE_DOMAIN" ] && profiles="${profiles:+$profiles,}tls-letsencrypt"
  if [ "$CUSTOMER_TYPE" = prod ]; then
    printf '%s\n' MONGODB_DATA_DIR=/mongodb-data CLICKHOUSE_DATA_DIR=/clickhouse-data KAFKA_DATA_DIR=/kafka-data
    # pre-install.sh refuses the seeded COUNTLY_DATA_DIR=./data (inside the bundle); with every
    # store on its own disk it is unused, so drop it the way import-legacy-env.sh does.
    echo "-COUNTLY_DATA_DIR="
  else
    printf '%s\n' COUNTLY_DATA_DIR=/data
  fi
  [ -n "$MONGODB_DIRECTORYPERDB" ] && echo "MONGODB_DIRECTORYPERDB=true"
  [ -n "$MONGODB_WIREDTIGER_DIRECTORY_FOR_INDEXES" ] && echo "MONGODB_WIREDTIGER_DIRECTORY_FOR_INDEXES=true"
  if [ -n "$LE_DOMAIN" ]; then echo "LE_DOMAIN=$LE_DOMAIN"; echo "LE_EMAIL=$LE_EMAIL"; fi
  # 27.0 seeds COUNTLY_UI_MODE=combined, and bin/ui-mode.sh derives the dashboard origin from
  # LE_DOMAIN only: without one it stays empty, so name the company domain.
  [ -n "$LE_DOMAIN" ] || echo "COUNTLY_UI_PUBLIC_URL=https://${CUSTOMER_NAME}.${CF_ZONE_NAME}"
  echo "API_TRAFFIC_ACCESS=$API_TRAFFIC_ACCESS"
  echo "LE_API_TRAFFIC_ACCESS=$LE_API_TRAFFIC_ACCESS"
  [ -n "$API_ROOT_REDIRECT" ] && echo "API_ROOT_REDIRECT=$API_ROOT_REDIRECT"
  [ -n "$LE_ROOT_REDIRECT" ] && echo "LE_ROOT_REDIRECT=$LE_ROOT_REDIRECT"
  echo "CLUSTER_NAME=$CUSTOMER_NAME"
  # Mail through Postmark: provider smtp with nodemailer's built-in "Postmark" service (Countly
  # 26.10+ reads MAIL_PROVIDER; the old MAIL_TRANSPORT still maps to smtp but is undocumented).
  # The token (AUTH_USER/AUTH_PASS) goes in separately from Secret Manager.
  printf '%s\n' COUNTLY_CONFIG__MAIL_PROVIDER=smtp COUNTLY_CONFIG__MAIL_CONFIG_SERVICE=Postmark \
    COUNTLY_CONFIG__MAIL_CONFIG_PORT=587 'COUNTLY_CONFIG__MAIL_STRINGS_FROM=Countly <no-reply@count.ly>'
  if [ -n "$ENABLE_OBS" ]; then
    printf '%s\n' OBS_REMOTE_WRITE_URL=https://iris.count.ly/api/v1/write \
      OBS_LOKI_URL=https://iris.count.ly/loki/api/v1/push TEMPO_OTLP_ENDPOINT=iris.count.ly:4317 OTEL_ENABLED=true
  fi
  # "+KEY=a,b" adds items to the bundle's value (standard-extras,browser) instead of replacing it.
  [ -n "$profiles" ] && echo "+COMPOSE_PROFILES=$profiles"
  return 0
}

# --- Mode --------------------------------------------------------------------
MODE=new
case "${1:-}" in
  --continue) MODE=continue; CUSTOMER_NAME="${2:?usage: --continue <customer>}" ;;
  --render)   STATE_FILE="${2:?usage: --render <state-file>}"; . "$STATE_FILE"; render_toml; exit 0 ;;
  "") ;;
  *) die "usage: countly_ignite_komodo [--continue <customer> | --render <state-file>]" ;;
esac

for t in gcloud jq curl openssl python3; do command -v "$t" >/dev/null || die "$t not found"; done
[ -f "$TEMPLATE" ] || die "template missing: $TEMPLATE"

# =============================================================================
# Prompts (new run) or state (continue)
# =============================================================================
if [ "$MODE" = continue ]; then
  STATE_FILE="$STATE_DIR/${CUSTOMER_NAME}.state"
  [ -f "$STATE_FILE" ] || die "no state file $STATE_FILE"
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  [ "${DONE:-0}" -lt 11 ] || die "${CUSTOMER_NAME} already finished (DONE=11)"
else
  clear 2>/dev/null || true
  echo ""
  echo "  countly_ignite_komodo -- new Countly Docker server on Komodo (${KOMODO_URL})"
  echo ""
  read -r -p "  Customer name (lowercase, a-z 0-9 -): " CUSTOMER_NAME
  [[ "$CUSTOMER_NAME" =~ ^[a-z][a-z0-9-]{1,38}[a-z0-9]$ ]] || die "customer name must match ^[a-z][a-z0-9-]{1,38}[a-z0-9]\$"
  STATE_FILE="$STATE_DIR/${CUSTOMER_NAME}.state"
  [ ! -f "$STATE_FILE" ] || die "$STATE_FILE exists: resume with --continue ${CUSTOMER_NAME}, or remove it after cleaning up"

  askQ "Instance type?" \
    "Production     (countly-01 | boot + 3 SSDs: mongo / ClickHouse / Kafka)" \
    "Production-Dev (countly-01 | boot + 1 combined SSD for all data)"
  read -r -p "    #: " a
  case "${a:0:1}" in
    1) CUSTOMER_TYPE=prod;     INSTANCE_ENV=production ;;
    2) CUSTOMER_TYPE=prod-dev; INSTANCE_ENV=development ;;
    *) die "invalid selection" ;;
  esac
  PROJECT=countly-01; DATA_CLASS=confidential; MACHINE_NAME="${CUSTOMER_NAME}-countly"

  askQ "Region?" "Belgium -- europe-west1" "London  -- europe-west2" "US      -- us-central1" "other?"
  read -r -p "    #: " a
  case "${a:0:1}" in
    2) REGION=europe-west2; ZONE=${REGION}-c ;;
    3) REGION=us-central1;  ZONE=${REGION}-c ;;
    4) read -r -p "  Region: " REGION; read -r -p "  Zone:   " ZONE ;;
    *) REGION=europe-west1; ZONE=${REGION}-b ;;
  esac

  askQ "Machine tier?" \
    " 1. T4-16   -- e2-standard-4       ( 4 vCPU /  16 GB)" \
    " 2. T6-24   -- e2-custom-6-24576   ( 6 vCPU /  24 GB)" \
    " 3. T8-32   -- e2-standard-8       ( 8 vCPU /  32 GB)" \
    " 4. T12-48  -- e2-custom-12-49152  (12 vCPU /  48 GB)" \
    " 5. T16-64  -- e2-standard-16      (16 vCPU /  64 GB)" \
    " 6. T24-96  -- e2-custom-24-98304  (24 vCPU /  96 GB)" \
    " 7. T32-128 -- e2-standard-32      (32 vCPU / 128 GB)" \
    " 8. T48-192 -- n2d-standard-48     (48 vCPU / 192 GB)" \
    " 9. T64-256 -- n2d-standard-64     (64 vCPU / 256 GB)" \
    "10. T80-320 -- n2d-standard-80     (80 vCPU / 320 GB)"
  read -r -p "    #: " a
  case "$a" in
    2)  TIER=T6-24;   MACHINE_TYPE=e2-custom-6-24576 ;;
    3)  TIER=T8-32;   MACHINE_TYPE=e2-standard-8 ;;
    4)  TIER=T12-48;  MACHINE_TYPE=e2-custom-12-49152 ;;
    5)  TIER=T16-64;  MACHINE_TYPE=e2-standard-16 ;;
    6)  TIER=T24-96;  MACHINE_TYPE=e2-custom-24-98304 ;;
    7)  TIER=T32-128; MACHINE_TYPE=e2-standard-32 ;;
    8)  TIER=T48-192; MACHINE_TYPE=n2d-standard-48 ;;
    9)  TIER=T64-256; MACHINE_TYPE=n2d-standard-64 ;;
    10) TIER=T80-320; MACHINE_TYPE=n2d-standard-80 ;;
    *)  TIER=T4-16;   MACHINE_TYPE=e2-standard-4 ;;
  esac
  TIER_LOWER="$(tr '[:upper:]' '[:lower:]' <<<"$TIER")"

  askQ "SSD data disk size per disk (GB)?" "10" "50" "100" "200" "500" "custom?"
  read -r -p "    #: " a
  case "${a:0:1}" in
    2) DATA_DISK_SIZE=50 ;; 3) DATA_DISK_SIZE=100 ;; 4) DATA_DISK_SIZE=200 ;; 5) DATA_DISK_SIZE=500 ;;
    6) read -r -p "  Size in GB: " DATA_DISK_SIZE ;;
    *) DATA_DISK_SIZE=10 ;;
  esac
  [[ "$DATA_DISK_SIZE" =~ ^[0-9]+$ ]] && [ "$DATA_DISK_SIZE" -ge 10 ] || die "disk size must be a number >= 10"

  askQ "MongoDB directoryPerDB?" "No (fresh install)" "Yes (only to match data you will restore)"
  read -r -p "    #: " a; MONGODB_DIRECTORYPERDB=; [ "${a:0:1}" = 2 ] && MONGODB_DIRECTORYPERDB=true
  askQ "MongoDB wiredTigerDirectoryForIndexes?" "No (fresh install)" "Yes (only to match data you will restore)"
  read -r -p "    #: " a; MONGODB_WIREDTIGER_DIRECTORY_FOR_INDEXES=; [ "${a:0:1}" = 2 ] && MONGODB_WIREDTIGER_DIRECTORY_FOR_INDEXES=true

  askQ "Observability (Alloy, node-exporter, cAdvisor -> iris)?" "Yes [default]" "No"
  read -r -p "    #: " a; ENABLE_OBS=1; [ "${a:0:1}" = 2 ] && ENABLE_OBS=

  askQ "Countly flavor (compose-release lane)?" "standard  -- main-release" "no-ai     -- main-release-no-ai" "ad        -- main-release-ad (auth plugins)"
  read -r -p "    #: " a
  case "${a:0:1}" in
    2) FLAVOR=no-ai;    LANE=main-release-no-ai ;;
    3) FLAVOR=ad;       LANE=main-release-ad ;;
    *) FLAVOR=standard; LANE=main-release ;;
  esac

  # A tag pins a release that is not (or not yet) a lane head, e.g. a release candidate. Its
  # BUNDLE.json names the lane; the Stack tracks that branch, pinned to the tag's commit.
  askQ "Release?" "latest on ${LANE} [default]" "a release tag (e.g. 27.0.0-rc1)"
  read -r -p "    #: " a; RELEASE_TAG=
  if [ "${a:0:1}" = 2 ]; then
    read -r -p "  Tag (without the flavor suffix): " RELEASE_TAG
    [[ "$RELEASE_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+[0-9a-z.-]*$ ]] || die "not a release tag: $RELEASE_TAG"
    [ "$FLAVOR" = standard ] || RELEASE_TAG="${RELEASE_TAG}-${FLAVOR}"
  fi

  echo ""
  echo "  TLS: ${CUSTOMER_NAME}.count.ly uses the company wildcard cert. Optionally a second domain via Let's Encrypt."
  read -r -p "  Custom domain for Let's Encrypt [blank = none]: " LE_DOMAIN
  LE_EMAIL=; LE_API_TRAFFIC_ACCESS=; LE_ROOT_REDIRECT=; API_TRAFFIC_ACCESS=; API_ROOT_REDIRECT=
  if [ -n "$LE_DOMAIN" ]; then
    read -r -p "  Let's Encrypt contact email: " LE_EMAIL
    read -r -p "  Access for ${LE_DOMAIN} [Enter = open, or 'restricted' = SDK + ingestor only]: " a
    [ "$a" = restricted ] && LE_API_TRAFFIC_ACCESS=restricted
    if [ "$LE_API_TRAFFIC_ACCESS" = restricted ]; then
      read -r -p "  Root redirect for ${LE_DOMAIN} [Enter = 403, or URL]: " a
      [ -n "$a" ] && case "$a" in http://*|https://*) LE_ROOT_REDIRECT="301 $a" ;; *) LE_ROOT_REDIRECT="301 https://$a" ;; esac
    fi
  fi
  read -r -p "  Access for ${CUSTOMER_NAME}.count.ly [Enter = open, or 'restricted']: " a
  [ "$a" = restricted ] && API_TRAFFIC_ACCESS=restricted
  if [ "$API_TRAFFIC_ACCESS" = restricted ]; then
    read -r -p "  Root redirect for ${CUSTOMER_NAME}.count.ly [Enter = 403, or URL]: " a
    [ -n "$a" ] && case "$a" in http://*|https://*) API_ROOT_REDIRECT="301 $a" ;; *) API_ROOT_REDIRECT="301 https://$a" ;; esac
  fi

  echo ""
  read -r -p "  Email of the initial Countly admin user: " CLY_INIT_USER_UID
  [[ "$CLY_INIT_USER_UID" == *@*.* ]] || die "not an email address"

  # The Unix user who ran it: on ansible-master gcloud runs as the VM service account for everyone.
  OPERATOR="${SUDO_USER:-$(whoami)}@$(hostname -s)"
  STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  DONE=0; CUSTOMER_IP=; CF_ZONE_ID=; CF_RECORD_IDS=; KOMODO_SERVER_ID=; PR_URL=
fi

mkdir -p "$STATE_DIR"
LOG_FILE="$STATE_DIR/${CUSTOMER_NAME}-$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[ignite-komodo] log: $LOG_FILE  mode=$MODE  customer=$CUSTOMER_NAME  operator=$(gcloud config get-value account 2>/dev/null)"

# =============================================================================
# Pre-flight: every credential and name checked before anything is created
# =============================================================================
echo ""
echo "  Pre-flight..."
gcloud projects describe "$PROJECT" --quiet >/dev/null 2>&1 || die "no access to project $PROJECT"
load_secrets
komodo read GetVersion '{}' >/dev/null || die "Komodo API key refused by $KOMODO_URL"
CF_ZONE_ID="$(cf GET "/zones?name=${CF_ZONE_NAME}" | jq -r '.result[0].id // empty')"
[ -n "$CF_ZONE_ID" ] || die "Cloudflare token cannot see zone ${CF_ZONE_NAME}"

if [ "$MODE" = new ]; then
  if [ -n "$RELEASE_TAG" ]; then
    head_json="$(gh GET "/repos/${RELEASE_REPO}/commits/${RELEASE_TAG}")" || die "no tag $RELEASE_TAG in $RELEASE_REPO"
    COMMIT="$(jq -r .sha <<<"$head_json")"
    LANE="$(gh GET "/repos/${RELEASE_REPO}/contents/compose/BUNDLE.json?ref=${COMMIT}" | jq -r .content | base64 -d | jq -r '.lane // empty')"
    [ -n "$LANE" ] || die "tag $RELEASE_TAG has no lane in compose/BUNDLE.json"
    gh GET "/repos/${RELEASE_REPO}/git/ref/heads/${LANE}" >/dev/null || die "tag $RELEASE_TAG names lane $LANE, which is not a branch"
  else
    head_json="$(gh GET "/repos/${RELEASE_REPO}/commits/${LANE}")" || die "cannot read lane $LANE of $RELEASE_REPO"
    COMMIT="$(jq -r .sha <<<"$head_json")"
  fi
  RELEASE="$(jq -r '.commit.message | split("\n")[0]' <<<"$head_json" | sed -nE 's/^release ([0-9][0-9.]*[0-9a-z.-]*).*/\1/p')"
  [ -n "$RELEASE" ] || die "${RELEASE_TAG:-lane $LANE head} ${COMMIT:0:7} is not a release commit ('release X.Y.Z')"
  IFS=. read -r r1 r2 r3 _ <<<"${RELEASE%%-*}"
  VERSION_LABEL="$(printf 'v%02d%02d%02d' "$((10#$r1))" "$((10#$r2))" "$((10#${r3:-0}))")"

  ! gh GET "/repos/${DEPLOY_REPO}/contents/customers-docker/${CUSTOMER_NAME}.toml?ref=main" >/dev/null \
    || die "customers-docker/${CUSTOMER_NAME}.toml already exists on main"
  ! gh GET "/repos/${DEPLOY_REPO}/git/ref/heads/ignite/${CUSTOMER_NAME}" >/dev/null \
    || die "branch ignite/${CUSTOMER_NAME} already exists in ${DEPLOY_REPO}"

  ! komodo read GetServer "$(jq -cn --arg s "$CUSTOMER_NAME" '{server: $s}')" >/dev/null \
    || die "Komodo already has a Server ${CUSTOMER_NAME}"
  ! komodo read GetStack "$(jq -cn --arg s "$CUSTOMER_NAME" '{stack: $s}')" >/dev/null \
    || die "Komodo already has a Stack ${CUSTOMER_NAME}"
  [ "$(cf GET "/zones/${CF_ZONE_ID}/dns_records?name=${CUSTOMER_NAME}.${CF_ZONE_NAME}" | jq '.result | length')" = 0 ] \
    || die "DNS ${CUSTOMER_NAME}.${CF_ZONE_NAME} already exists"
  ! gcloud compute addresses describe "${CUSTOMER_NAME}-ip" --region "$REGION" --project "$PROJECT" >/dev/null 2>&1 \
    || die "address ${CUSTOMER_NAME}-ip already exists in $REGION"
  ! gcloud compute instances describe "$MACHINE_NAME" --zone "$ZONE" --project "$PROJECT" >/dev/null 2>&1 \
    || die "instance $MACHINE_NAME already exists in $ZONE"

  IMAGE="$(gcloud compute images list --project "$IMAGE_PROJECT" --no-standard-images --format='value(name)' \
    --filter="name~'^${IMAGE_PREFIX}'" --sort-by='~creationTimestamp' --limit=1)"
  [ -n "$IMAGE" ] || die "no ${IMAGE_PREFIX}* image in $IMAGE_PROJECT"

  echo ""
  echo "  +---------------------------------------------------------------------+"
  printf "  |  Instance : %-56s|\n" "$MACHINE_NAME ($CUSTOMER_TYPE, $PROJECT, $ZONE)"
  printf "  |  Machine  : %-56s|\n" "$MACHINE_TYPE  [tier $TIER]"
  if [ "$CUSTOMER_TYPE" = prod ]; then printf "  |  Disks    : %-56s|\n" "3 x ${DATA_DISK_SIZE} GB SSD (mongo / CH / kafka)"
  else printf "  |  Disks    : %-56s|\n" "1 x ${DATA_DISK_SIZE} GB SSD (combined at /data)"; fi
  printf "  |  Image    : %-56s|\n" "$IMAGE"
  printf "  |  Release  : %-56s|\n" "$LANE @ ${COMMIT:0:7} ($RELEASE, $FLAVOR)"
  printf "  |  Domain   : %-56s|\n" "https://${CUSTOMER_NAME}.count.ly${LE_DOMAIN:+ + https://$LE_DOMAIN (LE)}"
  printf "  |  Access   : %-56s|\n" "company=${API_TRAFFIC_ACCESS:-open}  LE=${LE_API_TRAFFIC_ACCESS:-open}"
  printf "  |  Observ.  : %-56s|\n" "$([ -n "$ENABLE_OBS" ] && echo enabled || echo disabled)"
  printf "  |  Komodo   : %-56s|\n" "Server + Stack '${CUSTOMER_NAME}' (PR to ${DEPLOY_REPO})"
  printf "  |  Admin    : %-56s|\n" "$CLY_INIT_USER_UID"
  echo "  +---------------------------------------------------------------------+"
  read -r -p "  Proceed? [y/N]: " a
  [[ "$a" =~ ^[Yy]$ ]] || { echo "  Aborted. Nothing was created."; exit 0; }
  save_state
fi
echo "  Pre-flight OK."

trap 'print_undo' EXIT

# =============================================================================
# Steps
# =============================================================================
s1_ip() {
  step 1 "Reserving static IP ${CUSTOMER_NAME}-ip"
  gcloud compute addresses create "${CUSTOMER_NAME}-ip" --region "$REGION" --project "$PROJECT"
  CUSTOMER_IP="$(gcloud compute addresses describe "${CUSTOMER_NAME}-ip" --region "$REGION" --project "$PROJECT" --format='value(address)')"
  [ -n "$CUSTOMER_IP" ] || die "IP reserved but no address returned"
  echo "        IP: $CUSTOMER_IP"
}

s2_vm() {
  step 2 "Creating $MACHINE_NAME from $IMAGE"
  local labels="customer=${CUSTOMER_NAME},application=countly,server=countly,deployment=docker,tier=${TIER_LOWER},os=noble,version=${VERSION_LABEL},environment=${INSTANCE_ENV},owner=${CUSTOMER_NAME},project=${CUSTOMER_NAME},dataclassification=${DATA_CLASS},vanta-owner=as,vanta-description=${CUSTOMER_TYPE}-customer-server-docker"
  local disk_labels="customer=${CUSTOMER_NAME},application=countly,deployment=docker,environment=${INSTANCE_ENV},owner=${CUSTOMER_NAME},project=${CUSTOMER_NAME},dataclassification=${DATA_CLASS},vanta-owner=as"
  local args=("$MACHINE_NAME" --project "$PROJECT" --zone "$ZONE" --image "$IMAGE" --image-project "$IMAGE_PROJECT"
    --machine-type "$MACHINE_TYPE" --boot-disk-size 30GB --tags http-server,https-server
    --network default-vpc --subnet "$REGION" --address "$CUSTOMER_IP" --deletion-protection --labels "$labels")
  if [ "$CUSTOMER_TYPE" = prod ]; then
    local d; for d in mongodb clickhouse kafka; do
      args+=("--create-disk=name=${MACHINE_NAME}-${d}-disk,type=pd-ssd,size=${DATA_DISK_SIZE}GB,auto-delete=no,device-name=${d}-data")
    done
  else
    args+=("--create-disk=name=${MACHINE_NAME}-data-disk,type=pd-ssd,size=${DATA_DISK_SIZE}GB,auto-delete=no,device-name=data")
  fi
  gcloud compute instances create "${args[@]}"
  gcloud compute disks add-labels "$MACHINE_NAME" --zone "$ZONE" --project "$PROJECT" --labels "${disk_labels},service=boot" || true
  if [ "$CUSTOMER_TYPE" = prod ]; then
    for d in mongodb clickhouse kafka; do
      gcloud compute disks add-labels "${MACHINE_NAME}-${d}-disk" --zone "$ZONE" --project "$PROJECT" --labels "${disk_labels},service=${d}" || true
    done
  else
    gcloud compute disks add-labels "${MACHINE_NAME}-data-disk" --zone "$ZONE" --project "$PROJECT" --labels "${disk_labels},service=data" || true
  fi
}

s3_ssh() {
  step 3 "Waiting for SSH (max 5 min)"
  local i
  for i in $(seq 1 30); do
    vm_ssh 'echo ready' >/dev/null 2>&1 && return 0
    echo "        waiting... ($i/30)"; sleep 10
  done
  die "$MACHINE_NAME not reachable over SSH after 5 minutes"
}

s4_disks() {
  step 4 "Initialising data disks"
  local f; f="$(mktemp)"
  if [ "$CUSTOMER_TYPE" = prod ]; then
    cat > "$f" <<EOF
set -euo pipefail
curl -fsSL '$INIT_3DISK_URL' -o /tmp/init_new_arch_data_disk.sh
bash /tmp/init_new_arch_data_disk.sh
EOF
  else
    cat > "$f" <<'EOF'
set -euo pipefail
DEVICE=/dev/disk/by-id/google-data; MP=/data
if ! mountpoint -q "$MP"; then
  blkid "$DEVICE" >/dev/null 2>&1 || mkfs.xfs -f "$DEVICE"
  mkdir -p "$MP"
  grep -q " $MP " /etc/fstab || echo "$DEVICE $MP xfs defaults,noatime,nofail 0 0" >> /etc/fstab
  mount "$MP"; systemctl daemon-reload
fi
mkdir -p /data/mongodb /data/clickhouse /data/kafka
chown 1000:1000 /data/kafka
EOF
  fi
  vm_scp "$f" /tmp/ignite-disks.sh; rm -f "$f"
  vm_ssh 'sudo bash /tmp/ignite-disks.sh'
}

s5_dns() {
  step 5 "Cloudflare DNS"
  local ids="" name out
  for name in "$CUSTOMER_NAME" ${LE_DOMAIN:+"${LE_DOMAIN%.count.ly}"}; do
    [ "$name" = "$LE_DOMAIN" ] && { echo "        NOTE: $LE_DOMAIN is outside count.ly: add an A record to $CUSTOMER_IP at its DNS provider."; continue; }
    out="$(cf POST "/zones/${CF_ZONE_ID}/dns_records" \
      "$(jq -cn --arg n "$name" --arg ip "$CUSTOMER_IP" '{type:"A", name:$n, content:$ip, ttl:60, proxied:false}')")" \
      || die "Cloudflare refused ${name}.${CF_ZONE_NAME}: $(jq -r '.errors[0].message // empty' <<<"$out")"
    ids="${ids:+$ids,}$(jq -r .result.id <<<"$out")"
    echo "        ${name}.${CF_ZONE_NAME} -> ${CUSTOMER_IP}"
  done
  CF_RECORD_IDS="$ids"
}

s6_komodo() {
  step 6 "Joining Komodo as Server '${CUSTOMER_NAME}'"
  local out key pub i state
  out="$(komodo write CreateOnboardingKey "$(jq -cn --arg n "ignite-${CUSTOMER_NAME}-$(date -u +%Y%m%dT%H%M%SZ)" \
    --argjson e $((($(date +%s) + 3600) * 1000)) '{name:$n, expires:$e, privileged:false, tags:["compose","prod-customer"]}')")" \
    || die "CreateOnboardingKey refused: $out"
  key="$(jq -r .private_key <<<"$out")"; pub="$(jq -r .created.public_key <<<"$out")"; out=
  [ -n "$key" ] && [ -n "$pub" ] || die "CreateOnboardingKey returned no key"

  # The script carries no secret; the key travels on its stdin, never on a command line.
  local f; f="$(mktemp)"
  cat > "$f" <<EOF
set -euo pipefail
k="\$(cat)"
c=/opt/countly/komodo/periphery.config.toml
sed -i '/^core_address/d; /^connect_as/d; /^onboarding_key/d' "\$c"
printf 'core_address = "%s"\nconnect_as = "%s"\nonboarding_key = "%s"\n' '${KOMODO_URL}' '${CUSTOMER_NAME}' "\$k" >> "\$c"
systemctl enable --now periphery
EOF
  vm_scp "$f" /tmp/ignite-onboard.sh; rm -f "$f"
  printf '%s\n' "$key" | vm_ssh 'sudo bash /tmp/ignite-onboard.sh; rc=$?; sudo rm -f /tmp/ignite-onboard.sh; exit $rc'
  key=

  for i in $(seq 1 36); do
    state="$(komodo read GetServerState "$(jq -cn --arg s "$CUSTOMER_NAME" '{server:$s}')" 2>/dev/null | jq -r '.status // empty')" || true
    [ "$state" = Ok ] && break
    echo "        waiting for Periphery to connect... (${state:-not yet}, $i/36)"; sleep 5
  done
  komodo write DeleteOnboardingKey "$(jq -cn --arg p "$pub" '{public_key:$p}')" >/dev/null \
    || echo "        WARNING: could not delete the onboarding key: delete it in Komodo (Settings -> Onboarding) now."
  vm_ssh "sudo sed -i '/^onboarding_key/d' /opt/countly/komodo/periphery.config.toml && sudo systemctl restart periphery"
  [ "$state" = Ok ] || die "Server ${CUSTOMER_NAME} did not reach Ok in 3 minutes (journalctl -u periphery on the VM)"
  KOMODO_SERVER_ID="$(komodo read GetServer "$(jq -cn --arg s "$CUSTOMER_NAME" '{server:$s}')" | jq -r '._id["$oid"] // ._id // empty')"
  echo "        Server ${CUSTOMER_NAME} connected; onboarding key deleted and removed from the VM."
}

s7_pr() {
  step 7 "Opening the PR in ${DEPLOY_REPO}"
  local base_sha path content out
  base_sha="$(gh GET "/repos/${DEPLOY_REPO}/git/ref/heads/main" | jq -r .object.sha)"
  gh POST "/repos/${DEPLOY_REPO}/git/refs" "$(jq -cn --arg r "refs/heads/ignite/${CUSTOMER_NAME}" --arg s "$base_sha" '{ref:$r, sha:$s}')" >/dev/null \
    || die "cannot create branch ignite/${CUSTOMER_NAME}"
  path="customers-docker/${CUSTOMER_NAME}.toml"
  content="$(render_toml | openssl base64 -A)"
  gh PUT "/repos/${DEPLOY_REPO}/contents/${path}" "$(jq -cn --arg m "customers-docker: add ${CUSTOMER_NAME}" --arg c "$content" \
    --arg b "ignite/${CUSTOMER_NAME}" '{message:$m, content:$c, branch:$b}')" >/dev/null || die "cannot write $path"
  out="$(gh POST "/repos/${DEPLOY_REPO}/pulls" "$(jq -cn --arg t "customers-docker: add ${CUSTOMER_NAME}" \
    --arg h "ignite/${CUSTOMER_NAME}" --arg b "$(pr_body)" '{title:$t, head:$h, base:"main", body:$b}')")" || die "cannot open the PR"
  PR_URL="$(jq -r .html_url <<<"$out")"
  echo "        $PR_URL"
}

pr_body() {
  cat <<EOF
New Countly Docker server **${CUSTOMER_NAME}**, created by \`countly_ignite_komodo\` (run by ${OPERATOR}, ${STARTED}).

| | |
|---|---|
| VM | \`${MACHINE_NAME}\` (${PROJECT}, ${ZONE}, ${MACHINE_TYPE}) |
| Tier | ${TIER} |
| Release | \`${LANE}\` @ \`${COMMIT:0:7}\` (${RELEASE}) |
| Image | \`${IMAGE}\` |

Already done: the VM exists and its Periphery is connected to Komodo as Server \`${CUSTOMER_NAME}\`.

After the merge, \`countly_ignite_komodo\` runs the \`customers-docker\` sync for this Server and Stack only, seeds \`/opt/countly\` and deploys. No manual sync needed.
EOF
}

s8_wait() {
  step 8 "Waiting for the PR merge, then syncing Server + Stack '${CUSTOMER_NAME}' only"
  echo "        Review and merge ${PR_URL}"
  echo "        (Ctrl-C is safe: resume with  countly_ignite_komodo --continue ${CUSTOMER_NAME})"
  local n=0 pr="${PR_URL##*/}" t out
  until [ "$(gh GET "/repos/${DEPLOY_REPO}/pulls/${pr}" | jq -r '.merged // false')" = true ]; do
    n=$((n + 1)); [ $((n % 10)) -eq 0 ] && echo "        still waiting for the merge ($((n / 2)) min)..."
    sleep 30
  done
  echo "        merged."
  # Only this customer's two resources: other merged-but-unsynced changes on main stay untouched.
  for t in Server Stack; do
    out="$(komodo execute RunSync "$(jq -cn --arg t "$t" --arg r "$CUSTOMER_NAME" \
      '{sync:"customers-docker", resource_type:$t, resources:[$r]}')")" || die "RunSync ($t) refused: $out"
    komodo_wait_update "$out" "RunSync $t" || die "RunSync ($t ${CUSTOMER_NAME}) failed: see the Update in Komodo"
  done
  komodo read GetStack "$(jq -cn --arg s "$CUSTOMER_NAME" '{stack:$s}')" >/dev/null \
    || die "Stack ${CUSTOMER_NAME} still missing after the sync"
  echo "        Server and Stack ${CUSTOMER_NAME} applied from git."
}

komodo_wait_update() {  # <update-json> <what>: waits until Complete; returns its success
  local id u i
  id="$(jq -r '._id["$oid"] // ._id // .id // empty' <<<"$1")"
  [ -n "$id" ] || return 1
  for i in $(seq 1 360); do
    u="$(komodo read GetUpdate "$(jq -cn --arg i "$id" '{id:$i}')")" || true
    [ "$(jq -r '.status // empty' <<<"$u")" = Complete ] && break
    sleep 5
  done
  jq -r '.logs[]? | "          \(if .success then "ok  " else "FAIL" end) \(.stage)"' <<<"$u"
  [ "$(jq -r '.success' <<<"$u")" = true ]
}

s9_seed() {
  step 9 "Cloning the release on the VM and seeding ${CUSTOMER_DIR}"
  local out f
  out="$(komodo execute PullStack "$(jq -cn --arg s "$CUSTOMER_NAME" '{stack:$s}')")" || die "PullStack refused: $out"
  # The pull stage fails while ${CUSTOMER_DIR}/.env does not exist yet; the clone is what matters.
  komodo_wait_update "$out" PullStack || echo "        (pull stage reported failure: expected before the .env exists)"
  vm_ssh "test -f ${STACK_ROOT}/${CUSTOMER_NAME}/compose/scripts/pre-install.sh" \
    || die "release clone missing at ${STACK_ROOT}/${CUSTOMER_NAME}/compose on the VM"

  f="$(mktemp)"; render_overrides > "$f"
  vm_scp "$f" /tmp/ignite-overrides.env; rm -f "$f"
  f="$(mktemp)"
  cat > "$f" <<EOF
set -euo pipefail
cd ${STACK_ROOT}/${CUSTOMER_NAME}/compose
DEST=${CUSTOMER_DIR}; export COUNTLY_CUSTOMER_DIR=\$DEST
. scripts/lib.sh
if [ -f "\$DEST/.env" ]; then
  echo "        \$DEST/.env exists: seeding skipped (resumed run)"
else
  # The bundle's own seeding, exactly as pre-install.sh does it on a fresh host.
  eval "\$(sed -n '/^seed_customer_dir() {/,/^}/p' scripts/pre-install.sh)"
  declare -F seed_customer_dir >/dev/null || { echo "seed_customer_dir not found in this bundle" >&2; exit 1; }
  seed_customer_dir
fi
python3 - "\$DEST/.env" /tmp/ignite-overrides.env <<'PY'
import re, sys
env, ov = sys.argv[1], sys.argv[2]
lines = open(env).read().splitlines()
def setkey(k, v, append):
    for i, l in enumerate(lines):
        if re.match(r'^%s=' % re.escape(k), l):
            if append:
                cur = [x for x in l.split('=', 1)[1].split(',') if x]
                v = ','.join(cur + [x for x in v.split(',') if x not in cur])
            lines[i] = '%s=%s' % (k, v); return
    lines.append('%s=%s' % (k, v))
for l in open(ov).read().splitlines():
    if not l.strip(): continue
    k, v = l.split('=', 1)
    if k.startswith('-'):  # -KEY= comments the key out
        lines = ['# ' + x if re.match(r'^%s=' % re.escape(k[1:]), x) else x for x in lines]
        continue
    setkey(k.lstrip('+'), v, k.startswith('+'))
# Same rule as countly_ignite: no freshly generated PASSWORDSECRET (a restore would lock users out).
lines = ['# ' + l if l.startswith('COUNTLY_CONFIG__PASSWORDSECRET=') else l for l in lines]
open(env, 'w').write('\n'.join(lines) + '\n')
PY
chgrp 0 "\$DEST/.env"; chmod 0640 "\$DEST/.env"
rm -f /tmp/ignite-overrides.env
echo "        seeded \$DEST: \$(grep -c '^[A-Z_]*=' "\$DEST/.env") keys"
EOF
  vm_scp "$f" /tmp/ignite-seed.sh; rm -f "$f"
  vm_ssh 'sudo bash /tmp/ignite-seed.sh; rc=$?; sudo rm -f /tmp/ignite-seed.sh; exit $rc'

  # Company certificate: Secret Manager -> VM, straight through pipes. nginx reads it as gid 0.
  secret "$S_CERT_CHAIN" | vm_ssh "sudo sh -c 'umask 027; cat > ${CUSTOMER_DIR}/ssl/fullchain.pem; chown root:root ${CUSTOMER_DIR}/ssl/fullchain.pem; chmod 640 ${CUSTOMER_DIR}/ssl/fullchain.pem'"
  secret "$S_CERT_KEY"   | vm_ssh "sudo sh -c 'umask 027; cat > ${CUSTOMER_DIR}/ssl/privkey.pem; chown root:root ${CUSTOMER_DIR}/ssl/privkey.pem; chmod 640 ${CUSTOMER_DIR}/ssl/privkey.pem'"
  echo "        company certificate installed (640 root:root)"

  # Postmark token: Secret Manager -> stdin -> both SMTP keys in .env. The file is rewritten in place
  # (same inode). The program travels base64-encoded so the remote shell needs no quoting.
  local mail_py
  mail_py="$(base64 -w0 <<PY
import re, sys
p = '${CUSTOMER_DIR}/.env'
t = sys.stdin.readline().strip()
if not t:
    sys.exit('empty Postmark token')
lines = open(p).read().splitlines()
for k in ('COUNTLY_CONFIG__MAIL_CONFIG_AUTH_USER', 'COUNTLY_CONFIG__MAIL_CONFIG_AUTH_PASS'):
    lines = [l for l in lines if not re.match(r'^%s=' % k, l)] + ['%s=%s' % (k, t)]
open(p, 'w').write('\n'.join(lines) + '\n')
PY
)"
  secret "$S_MAIL_TOKEN" | vm_ssh "sudo python3 -c \"\$(echo $mail_py | base64 -d)\"" \
    || die "could not write the Postmark token into ${CUSTOMER_DIR}/.env"
  echo "        mail: Postmark SMTP set (token from Secret Manager)"
}

s10_deploy() {
  step 10 "Deploying Stack '${CUSTOMER_NAME}' through Komodo (this takes several minutes)"
  local out i
  out="$(komodo execute DeployStack "$(jq -cn --arg s "$CUSTOMER_NAME" '{stack:$s}')")" || die "DeployStack refused: $out"
  komodo_wait_update "$out" DeployStack || die "Deploy failed: see the Update in Komodo (Stack ${CUSTOMER_NAME})"
  echo "        Waiting for https://localhost/o/ping on the VM (max 15 min)..."
  for i in $(seq 1 60); do
    [ "$(vm_ssh "curl -sk https://localhost/o/ping" 2>/dev/null)" = '{"result":"Success"}' ] && { echo "        API ready."; return 0; }
    sleep 15
  done
  die "/o/ping did not answer Success in 15 minutes"
}

s11_app() {
  step 11 "Admin user, demo app, api.domain"
  local pwd raw api_key api="countly-countly-api-1"
  pwd="$(openssl rand -hex 16)"
  raw="$(printf '%s\n%s\n' "$CLY_INIT_USER_UID" "$pwd" | vm_ssh \
    "sudo bash -c 'read -r u; read -r p; docker exec -u root $api bash /opt/countly/bin/commands/countly.sh add_user \"\$u\" \"\$p\"'" 2>&1)" || true
  api_key="$(sed -nE "s/.*api_key[^']*'([^']+)'.*/\1/p" <<<"$raw" | head -1)"; raw=
  if [ -n "$api_key" ]; then
    printf '%s\n' "$api_key" | vm_ssh "read -r k; curl -sk -o /dev/null \"https://localhost/i/apps/create?args=%7B%22name%22%3A%22demo%22%7D&api_key=\$k\""
    vm_ssh "sudo docker exec -u root $api bash /opt/countly/bin/commands/countly.sh config api.domain 'https://${CUSTOMER_NAME}.count.ly'" >/dev/null
    echo "        admin ${CLY_INIT_USER_UID} created, demo app added, api.domain set."
  else
    echo "        WARNING: admin user not confirmed. On the VM run:"
    echo "          sudo docker exec -u root $api bash /opt/countly/bin/commands/countly.sh add_user EMAIL PASSWORD"
  fi
  api_key=
  # Straight to the terminal: the run log never holds the password.
  if { : > /dev/tty; } 2>/dev/null; then
    { echo ""; echo "  Admin    : $CLY_INIT_USER_UID"; echo "  Password : $pwd   (shown once, not logged)"; } > /dev/tty
  else
    local pwf="$HOME/.countly-ignite-${CUSTOMER_NAME}.password"
    ( umask 077; printf '%s %s\n' "$CLY_INIT_USER_UID" "$pwd" > "$pwf" )
    echo "        No terminal: the admin password is in $pwf (mode 600). Read it once, then delete it."
  fi
  pwd=
}

STEPS=(s1_ip s2_vm s3_ssh s4_disks s5_dns s6_komodo s7_pr s8_wait s9_seed s10_deploy s11_app)
for n in $(seq "$((DONE + 1))" 11); do
  "${STEPS[$((n - 1))]}"
  mark_done "$n"
done

echo ""
echo "  All done."
echo "  URL     : https://${CUSTOMER_NAME}.count.ly${LE_DOMAIN:+  and  https://$LE_DOMAIN}"
echo "  Komodo  : ${KOMODO_URL} -> Stack ${CUSTOMER_NAME}"
echo "  PR      : ${PR_URL}"
echo "[ignite-komodo] COMPLETED"
