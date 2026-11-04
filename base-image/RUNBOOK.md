# Komodo base image: Phase 1 runbook

These commands run in **your** terminal, as you. `build-on-vm.sh` needs sudo on the VM, and the AI identity (`devops-ai`) has none in countly-01.

- Project `countly-01`, zone `europe-west1-b`.
- Source: image `countly-enterprise-v2601-20261015`. The `new-arch-base-image` VM and its disk are never touched.
- Result: image `countly-docker-komodo-v261002-<YYYYMMDD>`.

```bash
P=countly-01; Z=europe-west1-b; D=$(date -u +%Y%m%d)
LABELS=customer=countly,project=countly,owner=countly,application=countly,server=countly,environment=development,dataclassification=internal,vanta-owner=as,vanta-description=internal-tool-server,version=v261002,deployment=docker,os=noble
```

## 0. Stop the VM left running from the read

```bash
gcloud compute instances stop new-arch-base-image --zone $Z --project $P
```
Effect: the VM stops, and its disk is kept. Rollback: `instances start`.

## 1. Build VM from the current image

```bash
gcloud compute instances create komodo-base-build --project $P --zone $Z \
  --image countly-enterprise-v2601-20261015 --image-project $P \
  --machine-type e2-standard-4 --boot-disk-size 30GB \
  --network default-vpc --subnet europe-west1 --labels "$LABELS"
```
Effect: one new VM with its own boot disk (deleted with the VM). It has an ephemeral external IP for GitHub and Docker Hub egress, and no http tags.

Before running build in step 2, check that the copy really is the image you read (old tree, `gcr-key.json`, old drop-in):

```bash
gcloud compute ssh komodo-base-build --zone $Z --project $P -- 'ls /opt; ls /opt/countly | head; cat /etc/systemd/system/docker.service.d/override.conf'
```

## 2. Build

```bash
# compose-release is private: send the bundle from a local clone at the pinned commit
git -C <compose-release clone> archive --format=tar 6af83ab868c15ce30218c1c1ab4982ab2205ec5a compose > bundle.tar
gcloud compute scp --tunnel-through-iap build-on-vm.sh bundle.tar komodo-base-build:/tmp/ --zone $Z --project $P
gcloud compute ssh komodo-base-build --zone $Z --project $P -- 'sudo install -m 700 /tmp/build-on-vm.sh /root/ && sudo bash /root/build-on-vm.sh build'
```
What it does: removes `/opt/countly`, `gcr-key.json`, the saved logins and every old image. It installs Docker tuning and the guard (`/opt/countly-2601/scripts/check-data-mounts.sh`, via the bundle's own `provision-docker-host.sh` with `COUNTLY_DEPLOY_DIR=/opt/countly-2601`), and Periphery v2.3.3 in `/opt/komodo` (sha256 checked, linked, not enabled). It runs `gcloud auth configure-docker`, then pulls the 26.10.2 images.

Expect `sha256sum: OK`, then `Done. Next: cold boot`.

A failure partway is fine: fix it, then run `build` again. Every step can be repeated.

## 3. Cold boot test (criteria 1–2)

```bash
gcloud compute instances reset komodo-base-build --zone $Z --project $P
gcloud compute ssh komodo-base-build --zone $Z --project $P -- 'sudo bash /root/build-on-vm.sh check'
```
Expect `ALL CHECKS PASSED`. Any `FAIL` means stop and fix it before sealing.

## 4. Seal (the VM powers itself off)

```bash
gcloud compute ssh komodo-base-build --zone $Z --project $P -- 'sudo bash /root/build-on-vm.sh seal'
gcloud compute instances describe komodo-base-build --zone $Z --project $P --format='value(status)'   # TERMINATED
```
After sealing, **don't SSH into the VM again**. That would recreate host keys and your home directory. Go straight to step 5.

## 5. Cut the image

```bash
gcloud compute images create countly-docker-komodo-v261002-$D --project $P \
  --source-disk komodo-base-build --source-disk-zone $Z \
  --storage-location europe-west1 --labels "$LABELS"
```

## 6. Test the image on a throwaway VM (criteria 1–3)

```bash
gcloud compute instances create komodo-base-test --project $P --zone $Z \
  --image countly-docker-komodo-v261002-$D --image-project $P \
  --machine-type e2-standard-4 --network default-vpc --subnet europe-west1 --labels "$LABELS"
gcloud compute scp --tunnel-through-iap build-on-vm.sh komodo-base-test:/tmp/ --zone $Z --project $P
gcloud compute ssh komodo-base-test --zone $Z --project $P -- 'sudo bash /tmp/build-on-vm.sh check && sudo docker pull -q gcr.io/countly-01/countly-unified:26.10.2'
```
The last pull proves the VM's service account can pull from gcr.io with no stored password. It uses a tag that's already cached, so it's quick.

Criterion 3: today's ignite query must still return a `countly-enterprise-` image:
```bash
gcloud compute images list --project $P --no-standard-images --format='value(name)' \
  --filter="name~'^countly-enterprise-' AND NOT name~'tracker'" --sort-by='~creationTimestamp' --limit=1
```

## 7. Clean up (destructive: check the names first)

```bash
gcloud compute instances list --project $P --filter='name~^komodo-base-' --format='table(name,zone,status)'
gcloud compute instances delete komodo-base-build komodo-base-test --zone $Z --project $P
```
This deletes the two VMs and their boot disks. Nothing else uses them, and the image from step 5 keeps everything that matters. There's no rollback, but step 1 can always be redone.

If the image turns out bad later:
`gcloud compute images deprecate countly-docker-komodo-v261002-$D --state DEPRECATED --project $P`. Nothing uses it until the new ignite exists.
