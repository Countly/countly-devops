# Komodo base image: Phase 1 runbook

These commands run in **your** terminal, as you. `build-on-vm.sh` needs sudo on the VM, and the AI identity (`devops-ai`) has none in countly-01.

- Project `countly-01`, zone `europe-west1-b`.
- Source: image `countly-enterprise-v2601-20261015`. The `new-arch-base-image` VM and its disk are never touched.
- Bundle: compose-release tag `27.0.0-rc1` (`933803e`, lane `main-rc`). No branch contains it, so fetch the tags.
- Result: image `countly-docker-komodo-v270000-rc1-<YYYYMMDD>`.

```bash
P=countly-01; Z=europe-west1-b; D=$(date -u +%Y%m%d); IMG=countly-docker-komodo-v270000-rc1-$D
LABELS=customer=countly,project=countly,owner=countly,application=countly,server=countly,environment=development,dataclassification=internal,vanta-owner=as,vanta-description=internal-tool-server,version=v270000,deployment=docker,os=noble
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
# compose-release is private: send the bundle from a local clone at the pinned commit (tag 27.0.0-rc1)
git -C <compose-release clone> fetch --tags origin
git -C <compose-release clone> archive --format=tar 933803efd4d07ae8fe249e3331d45661698b4d52 compose > bundle.tar
gcloud compute scp --tunnel-through-iap build-on-vm.sh bundle.tar komodo-base-build:/tmp/ --zone $Z --project $P
gcloud compute ssh komodo-base-build --zone $Z --project $P -- 'sudo install -m 700 /tmp/build-on-vm.sh /root/ && sudo bash /root/build-on-vm.sh build'
```
What it does: removes `/opt/countly`, `gcr-key.json`, the saved logins and every old image. It recreates `/opt/countly` as the single Countly directory: the guard (`/opt/countly/scripts/check-data-mounts.sh`, via the bundle's own `provision-docker-host.sh` with `COUNTLY_DEPLOY_DIR=/opt/countly`) plus Docker tuning, and Periphery v2.3.3 in `/opt/countly/komodo` (sha256 checked, linked, not enabled). It installs `docker-credential-gcr` 2.2.1 (sha256 checked) as the registry helper, not gcloud's snap helper, which gets killed when an SSH session closes mid-pull. Then it pulls the 27.0.0-rc1 images (standard flavor). Last, it moves the VM to Ubuntu's LTS GCP kernel (6.8) and removes the 6.17/7.0 HWE kernels: MongoDB 8.3.11 refuses Ubuntu's 7.0 kernel (SERVER-121912), and 27.0.0-rc1 still ships 8.3.11, so it cannot start Mongo on that kernel.

Expect `sha256sum: OK`, then `Done. Next: cold boot`.

A failure partway is fine: fix it, then run `build` again. Every step can be repeated.

## 3. Cold boot test (criteria 1–2)

```bash
gcloud compute instances reset komodo-base-build --zone $Z --project $P
gcloud compute ssh komodo-base-build --zone $Z --project $P -- 'sudo bash /root/build-on-vm.sh check'
```
Expect `ALL CHECKS PASSED`, including `kernel 6.8.0-…-gcp (LTS, below 6.19)`. Any `FAIL` means stop and fix it before sealing.

## 4. Seal (the VM powers itself off)

```bash
gcloud compute ssh komodo-base-build --zone $Z --project $P -- 'sudo bash /root/build-on-vm.sh seal'
gcloud compute instances describe komodo-base-build --zone $Z --project $P --format='value(status)'   # TERMINATED
```
After sealing, **don't SSH into the VM again**. That would recreate host keys and your home directory. Go straight to step 5.

## 5. Cut the image

```bash
gcloud compute images create $IMG --project $P \
  --source-disk komodo-base-build --source-disk-zone $Z \
  --storage-location europe-west1 --labels "$LABELS"
```

## 6. Test the image on a throwaway VM (criteria 1–3)

```bash
gcloud compute instances create komodo-base-test --project $P --zone $Z \
  --image $IMG --image-project $P \
  --machine-type e2-standard-4 --network default-vpc --subnet europe-west1 --labels "$LABELS"
gcloud compute scp --tunnel-through-iap build-on-vm.sh komodo-base-test:/tmp/ --zone $Z --project $P
gcloud compute ssh komodo-base-test --zone $Z --project $P -- 'sudo bash /tmp/build-on-vm.sh check && sudo docker pull -q gcr.io/countly-01/countly-unified:27.0.0-rc1'
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
`gcloud compute images deprecate $IMG --state DEPRECATED --project $P`. Nothing uses it until the new ignite exists.

The new ignite takes the newest `countly-docker-komodo-*` image, so from step 5 on it uses this one for every release. The image only pre-pulls and sets up the host; the Stack's pinned commit decides what gets deployed.
