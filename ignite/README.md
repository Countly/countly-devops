# countly_ignite_komodo

Creates a new Countly Docker server on GCP that is managed by prod Komodo
(https://komodo.count.ly). One interactive run takes about 30 minutes, end to end: VM, disks, DNS,
certificate, Komodo Server and Stack, a deployed Countly, and an admin user.

Instance types: **Production** (boot disk + 3 SSDs: MongoDB / ClickHouse / Kafka) and
**Production-Dev** (boot disk + 1 combined SSD). Trials still use the old `countly_ignite`.

| File | What it is |
|---|---|
| `countly_ignite_komodo.sh` | The ignite. No secrets in it. |
| `customers-docker.toml.tmpl` | Template for the Komodo Server + Stack written to `Countly/countly-deployment` `customers-docker/<customer>.toml`. Must sit next to the script. |
| `../base-image/` | How the VM image it boots from (`countly-docker-komodo-*`) is built. See `base-image/RUNBOOK.md`. |

## Run it

On ansible-master (project `countly-tools`, zone `europe-west1-b`):

```bash
sudo countly_ignite_komodo
```

The old ignite (`sudo countly_ignite`) is separate and unchanged.

| Command | Does |
|---|---|
| `sudo countly_ignite_komodo` | New server, interactive |
| `sudo countly_ignite_komodo --continue <customer>` | Resume a stopped run after its last finished step |
| `sudo countly_ignite_komodo --render /var/log/countly-ignite/<customer>.state` | Print the customers-docker TOML only |

### The questions

1. **Customer name**: lowercase `a-z 0-9 -`, 3 to 40 characters. Every name comes from it, see
   [Naming](#naming). Do **not** add `-countly` yourself.
2. **Instance type**: Production (3 data disks) or Production-Dev (1 data disk).
3. **Region**: europe-west1 (zone b), europe-west2 (c), us-central1 (c), or any other.
4. **Machine tier**: T4-16 ... T80-320 (vCPU-GB RAM).
5. **Data disk size** per disk, in GB.
6. **MongoDB directoryPerDB / wiredTigerDirectoryForIndexes**: No for a fresh install. Yes only
   to match a data disk you will bring from an old server.
7. **Observability** (Alloy, node-exporter, cAdvisor to iris): Yes by default.
8. **Flavor** = compose-release lane: standard (`main-release`), no-ai, ad (auth plugins).
9. **Release**: latest on the lane (default), or a specific release tag (type it without the
   flavor suffix).
10. **Let's Encrypt domain**: optional second domain. `<customer>.count.ly` always uses the
    company wildcard certificate.
11. **Access**: open, or `restricted` (SDK + ingestor only, root redirects or 403), for each domain.
12. **Admin email** for the first Countly user.

It then shows a summary (instance, image, release, domains) and asks `Proceed? [y/N]`. Nothing is
created before that answer. Pre-flight before the summary checks that no IP, DNS record, Komodo
Server/Stack, PR branch or `customers-docker/<customer>.toml` already exists, and that every secret
can be read.

### The 11 steps

| # | Step |
|---|---|
| 1 | Reserve static IP `<customer>-ip` |
| 2 | Create VM `<customer>-countly` and the data disks, from the newest `countly-docker-komodo-*` image |
| 3 | Wait for SSH |
| 4 | Format and mount the data disks (`/mongodb-data`, `/clickhouse-data`, `/kafka-data`, or `/data`) |
| 5 | Cloudflare A record `<customer>.count.ly` (and the LE domain, if it is under count.ly) |
| 6 | Join Komodo as Server `<customer>` (one-time onboarding key, deleted right after) |
| 7 | Open a PR in `Countly/countly-deployment` adding `customers-docker/<customer>.toml` |
| 8 | **Wait for someone to merge that PR**, then sync this Server + Stack only |
| 9 | Clone the release, seed `/opt/countly/.env`, write the certificate and Postmark mail settings |
| 10 | Deploy the Stack through Komodo, wait for `/o/ping` |
| 11 | Create the admin user and a demo app, set `api.domain` |

At step 8 the run waits. Merge the PR (it needs a review like any other), and it continues by
itself. Ctrl-C there is safe: resume with `--continue <customer>`.

The admin password is printed **once** on the terminal and never written to the log. Copy it then.

## Naming

All from the customer name `<c>`:

| Thing | Name |
|---|---|
| VM | `<c>-countly` |
| Data disks | `<c>-countly-mongodb-disk`, `-clickhouse-disk`, `-kafka-disk` (Production-Dev: `<c>-countly-data-disk`) |
| Static IP | `<c>-ip` |
| URL / DNS | `https://<c>.count.ly` |
| Komodo Server and Stack | `<c>` |
| Deploy PR | `customers-docker/<c>.toml`, branch `ignite/<c>` |
| GCP labels | `customer`, `owner`, `project` = `<c>`; `version` = the release as `v<MMmmpp>` |
| Run state and log | `/var/log/countly-ignite/<c>.state`, `/var/log/countly-ignite/<c>-<time>.log` |

Typing `foo-countly` gives a VM called `foo-countly-countly`. The customer name is also the public
URL, so choose it with that in mind.

Base images are named `countly-docker-komodo-v<MMmmpp>-<YYYYMMDD>` (release, cut date). The
ignite takes the **newest by creation time**, whatever its version: cutting a new image changes
what the next run uses, and deleting it falls back to the previous one.

## What ends up on the server

```
/opt/countly/             COUNTLY_CUSTOMER_DIR: .env, ssl/, vhosts/, clickhouse/, scripts/
/opt/countly/komodo/      Periphery: bin/, keys/, periphery.config.toml, stacks/<c>/compose (the release)
/mongodb-data  /clickhouse-data  /kafka-data     (Production-Dev: /data)
```

Upgrade later = change `commit` in `customers-docker/<c>.toml`, merge, press Deploy in Komodo. The
Stack has no `auto-deploy`: a person always presses Deploy.

## If it stops

The run records each finished step in the state file. Fix the cause, then:

```bash
sudo countly_ignite_komodo --continue <customer>
```

When it exits with an error it prints what it created so far and how to remove each piece.
Logs: `/var/log/countly-ignite/`.

## Removing a server

In this order:

1. PR in `Countly/countly-deployment` removing `customers-docker/<c>.toml`, merged.
2. Komodo: delete Stack `<c>`, then Server `<c>`.
3. Cloudflare: delete the A record `<c>.count.ly` (check it points at this server's IP first).
4. VM (created with deletion protection on):
   `gcloud compute instances update <c>-countly --no-deletion-protection --zone <zone> --project countly-01`,
   then `gcloud compute instances delete <c>-countly --zone <zone> --project countly-01`.
5. Data disks (created with `auto-delete=no`, so they survive the VM):
   `gcloud compute disks delete <c>-countly-mongodb-disk <c>-countly-clickhouse-disk <c>-countly-kafka-disk --zone <zone> --project countly-01`
   (Production-Dev: `<c>-countly-data-disk`).
6. `gcloud compute addresses delete <c>-ip --region <region> --project countly-01`
7. On ansible-master: remove `/var/log/countly-ignite/<c>.state`.

## Requirements

### Secrets

None are in the repository or on disk. The run reads them from Secret Manager in project
`countly-tools` with root's gcloud login on ansible-master (`ansible@countly-01`), which needs
`roles/secretmanager.secretAccessor` on each:

| Secret | Used for |
|---|---|
| `ignite-komodo-api-key`, `ignite-komodo-api-secret` | Komodo API |
| `ignite-cloudflare-dns-token` | Cloudflare DNS for count.ly |
| `ignite-github-token` | Fine-grained PAT: contents + pull requests write on `countly-deployment` and `compose-release` |
| `countly-wildcard-fullchain`, `countly-wildcard-privkey` | `*.count.ly` certificate |
| `countly-postmark-smtp-token` | Postmark SMTP (user and password are both this token) |

New secrets in `countly-tools` must use `--replication-policy user-managed --locations
europe-west1` (the org policy refuses global replication).

### Tools on the host

`gcloud`, `jq`, `curl`, `openssl`, `python3`.

## Installing it (or reinstalling on a new ansible-master)

As root, from a checkout of this repository, and only when no run is in progress (bash reads a
running script from disk as it goes, so overwriting it breaks that run):

```bash
install -o root -m 0755 ignite/countly_ignite_komodo.sh /etc/ansible/countly/bin/
install -o root -m 0644 ignite/customers-docker.toml.tmpl /etc/ansible/countly/bin/
ln -sf /etc/ansible/countly/bin/countly_ignite_komodo.sh /usr/local/bin/countly_ignite_komodo
```

Then make sure root's gcloud is logged in as `ansible@countly-01`:

```bash
sudo gcloud config get-value account
```

Check that the installed copy matches the repository:

```bash
sha256sum /etc/ansible/countly/bin/countly_ignite_komodo.sh ignite/countly_ignite_komodo.sh
```

Check no run is in progress before updating:

```bash
pgrep -af 'bash ([^ ]*/)?countly_ignite_komodo' || echo "no run in progress"
```

## Known limits

- Tested end to end: Production, observability on and off, a lane head and a release tag.
  Not yet run: Production-Dev, a Let's Encrypt domain, restricted access.
- The base image runs Ubuntu's LTS GCP kernel, not the newer HWE kernel: some MongoDB builds
  refuse to start on the newer kernel (SERVER-121912). See `base-image/RUNBOOK.md`.
- `grep: invalid option -- 'P'` during step 11 is harmless (countly.sh in the image).
