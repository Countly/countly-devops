# Moving a Docker customer onto prod Komodo

Hosts that run the legacy dockerized Countly tree in `/opt/countly` (Makefile, docker-compose.yml)
move to a Komodo-managed Stack (compose-release bundle) in one directory:

```
/opt/countly/          customer files = COUNTLY_CUSTOMER_DIR (.env, ssl/, vhosts/, clickhouse/)
/opt/countly/komodo/   Periphery root: periphery.config.toml, bin/periphery, keys/, stacks/<name>/compose
/opt/countly/legacy/   the legacy tree (rollback source until the first Deploy changes data)
/mongodb-data  /clickhouse-data  /kafka-data   unchanged
```

Nothing Countly-related outside `/opt/countly`, no symlinks. The Periphery systemd unit is a regular
file in `/etc/systemd/system` whose `ExecStart` points into `/opt/countly/komodo`.

Host definitions live in `Countly/countly-deployment` `customers-docker/<name>.toml`; Komodo
itself in `Countly/komodo`.

## Scripts

| script | run | does |
|---|---|---|
| `kernel-lts.sh` | on the host, first | Ubuntu HWE GCP kernel (6.17/7.x) -> LTS 6.8, clean reboot |
| `stage-legacy-host.sh legacy <TIER>` | on the host | legacy tree -> `/opt/countly/legacy`, guard drop-in, `make up` from there |
| `stage-legacy-host.sh periphery` | on the host, after the Periphery installer | binary/config/keys -> `/opt/countly/komodo`, clears the onboarding key |
| `move-split-to-single.sh <stack>` | one-off, done 2026-11-04 | hosts already on Komodo with `/opt/countly-2601` + `/opt/komodo` -> single `/opt/countly` |

## Order

Nothing below stops the legacy stack until step 9, except the reboot in step 1 and the recreate
in step 3 (one to two minutes each).

1. **Kernel.** `sudo bash kernel-lts.sh`. MongoDB 8.x refuses Ubuntu's 7.0 GCP kernel
   (SERVER-121912) and the bundle does not set `GLIBC_TUNABLES` for mongod. Do this while the
   legacy stack still runs from its original tree.
2. **Git.** PR adding `customers-docker/<name>.toml` (Server `enabled = true`, Stack
   `deploy = false`, hooks and env file on `/opt/countly`, datastore images held at what the host
   runs, `"countly-ui"` in `ignore_services`). On 27.0 set `COUNTLY_UI_MODE=disabled` in the stack
   `environment` for the old dashboard only: 27.0's default is `combined` (both dashboards).
   Merge, run the `customers-docker` sync by hand. No Deploy.
3. **Legacy tree aside.** `sudo bash stage-legacy-host.sh legacy <TIER>`, where `<TIER>` is the
   tier the legacy stack runs (`.active-tier`, check the host size). It ends with every bind mount
   under `/opt/countly/legacy`.
4. **Onboarding key.** Komodo > Settings > Onboarding keys: Privileged (the Server already exists
   from git), short expiry. One key may serve a batch of moves; disable it when the batch ends.
   Keep it out of chat, files and repos.
5. **Periphery.** On the host, two separate steps so the key is read on its own line:
   ```bash
   read -rs K && echo "length ${#K}"
   ```
   paste the key, Enter (length must be > 0), then:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/moghtech/komodo/v2.3.3/scripts/setup-periphery.py | sudo python3 - --version=v2.3.3 --root-directory=/opt/countly/komodo --core-address=https://komodo.count.ly --connect-as=<server name> --onboarding-key="$K"; unset K
   ```
   then `sudo bash stage-legacy-host.sh periphery`. Re-running the installer later writes a new
   `/etc/komodo` config and `/usr/local/bin/periphery` even when the unit points elsewhere.
6. **Pull.** Komodo > Stacks > `<name>` > Pull. A red cross at Compose Pull is expected
   (no customer `.env` yet).
7. **Import.** From `/opt/countly/komodo/stacks/<name>/compose`:
   ```bash
   sudo COUNTLY_CUSTOMER_DIR=/opt/countly bash scripts/migrate-legacy.sh /opt/countly/legacy --tier <TIER>
   ```
   It must end in READY. Delete a `COUNTLY_IMAGE` line it imported into `/opt/countly/.env` when
   the stack pins the app image. Re-apply hand edits from `vhosts.legacy` to `vhosts`.
8. **Snapshot** the three data disks if wanted
   (`gcloud compute disks snapshot ... --storage-location <region>`; org policy refuses global).
9. **Switch.**
   ```bash
   curl -fsS -X PUT localhost:8083/connectors/clickhouse-sink/pause
   cd /opt/countly/legacy && sudo make down TIER=<TIER> OBS=1
   docker ps -a --filter label=com.docker.compose.project=countly   # must print nothing
   ```
   Komodo > Stacks > `<name>` > Deploy.
10. **Verify.** All containers healthy, `/o/ping` 200 on the box and the public name, sink RUNNING,
    every bind mount under `/opt/countly`, the docker guard drop-in points at the stack folder
    (post-install rewrites it). AD/OIDC logins work.

## Known traps

- **Never recreate a legacy stack with bare `docker compose`.** The Makefile passes
  `--env-file tiers/<TIER>.env` (memory limits, Node heaps); without it every container gets
  compose defaults and the jobserver OOM-loops at 1.5 GiB (villagemd-dev, 2026-11-04 to 11-06).
- **No reboot or `docker restart` between moving a live tree and recreating its containers.**
  Containers keep bind mounts to the old paths; Docker then creates empty directories where
  files were and nginx/alloy exit 127.
- **Never a hard reset after `kernel-lts.sh`'s purge**, only `systemctl reboot`.
- **nginx `mem_limit: 256m`** is hard-coded in the bundle (26.10.2 and 27.0) and no tier sizes it.
  A busy host (stcbank, ~350 req/s) OOM-kills it. Until the bundle changes:
  `docker update --memory 1g --memory-swap 1g countly-nginx` right after every Deploy.
- **AD single-tenant:** bundles up to 27.0.0-rc2 refuse a tenant id in
  `COUNTLY_CONFIG_PLUGINAD_TENANT` at pre-install (catalog enum `multi,single`). Fixed in
  Countly/countly-platform#3083; needs a bundle that carries it.
- **Deleting a Komodo Stack runs `compose down`** on its host.
- The bundle recreates an empty `/etc/countly` on every Deploy (upstream; harmless).
