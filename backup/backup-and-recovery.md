# Backup & disaster recovery

Off-site, client-side-encrypted backups of your config and data volumes, plus an
optional repo mirror — designed so a full restore never depends on a personal
cloud-account password.

- **`backup.sh`** — nightly: dump databases, snapshot volumes, copy config, then
  `tar | zstd` and upload to object storage through an `rclone crypt` remote.
- **`.github/workflows/repo-mirror.yml`** — on every push: bundle the whole repo
  and upload it to the same bucket, so you can recover the repo even if your git
  host is unreachable.

Everything below uses placeholders — substitute your own bucket, project, and
service-account names. Never commit real credentials; commit only encrypted
secrets (e.g. with [sops](https://github.com/getsops/sops) + age).

## Auth model (why recovery is self-contained)

Backups authenticate with a **storage service account**, not your human cloud
login — so restore needs no account password, no 2FA prompt, no account recovery.

- Bucket: `gs://YOUR-BUCKET` (a private bucket in your cloud project).
- Backup service account: full read/write on the bucket. Its key is what you use
  to restore. Keep a disaster-recovery copy encrypted in your repo (e.g.
  `secrets/backup-sa.enc.json` via sops) and/or on an offline drive.
- Crypt password/salt: the `rclone crypt` secret. Store it encrypted in your repo
  too (e.g. in a sops vault) — it is what decrypts the archives.

## One-time setup

### 1. Create the bucket + backup service account

```bash
gcloud storage buckets create gs://YOUR-BUCKET --location=YOUR-REGION --uniform-bucket-level-access
gcloud iam service-accounts create backup --project YOUR-PROJECT
gcloud storage buckets add-iam-policy-binding gs://YOUR-BUCKET \
  --member=serviceAccount:backup@YOUR-PROJECT.iam.gserviceaccount.com \
  --role=roles/storage.objectAdmin
gcloud iam service-accounts keys create backup-sa.json \
  --iam-account backup@YOUR-PROJECT.iam.gserviceaccount.com
```

### 2. Configure the rclone remotes on the server

```bash
# raw storage backend, authenticated with the SA key
rclone config create storage "google cloud storage" \
  service_account_file=/path/to/backup-sa.json project_number=YOUR-PROJECT-NUMBER \
  location=YOUR-REGION bucket_policy_only=true
# crypt layer on top. Pass the password/salt as PLAINTEXT — `rclone config create`
# obscures them itself. (Do NOT pre-run `rclone obscure`; that double-obscures and
# the restore then can't decrypt.) Generate them once with `rclone config` and
# store them in your encrypted vault.
rclone config create crypt crypt remote=storage:YOUR-BUCKET \
  password='YOUR_CRYPT_PASSWORD' password2='YOUR_CRYPT_SALT'
```

### 3. Scoped service account for the repo mirror (recommended)

The repo-mirror workflow needs a key in GitHub Actions. **Do not reuse the backup
SA key there** — a leaked CI secret must not be able to read or delete your data
backups. Instead create a second SA whose access is IAM-condition-scoped to the
`repo-mirror/` prefix only:

```bash
gcloud iam service-accounts create repo-mirror --project YOUR-PROJECT
# write access ONLY under repo-mirror/
gcloud storage buckets add-iam-policy-binding gs://YOUR-BUCKET \
  --member=serviceAccount:repo-mirror@YOUR-PROJECT.iam.gserviceaccount.com \
  --role=roles/storage.objectAdmin \
  --condition='title=repo-mirror-only,expression=resource.name.startsWith("projects/_/buckets/YOUR-BUCKET/objects/repo-mirror/")'
# `gcloud storage cp` fails without bucket-wide object list (verified: it lists the
# destination before writing), so grant a minimal custom role — list + bucket.get
# only, NO object read/write/delete. Residual exposure if this CI key leaks: it can
# *enumerate* object names (which are crypt-encrypted hashes) but cannot read, write,
# or delete anything outside repo-mirror/. That name-only metadata leak is acceptable;
# for zero enumeration, upload via the JSON API (objects.insert) instead of `cp`.
gcloud iam roles create repoMirrorList --project YOUR-PROJECT \
  --title "Repo mirror list" --stage GA \
  --permissions storage.objects.list,storage.buckets.get
gcloud storage buckets add-iam-policy-binding gs://YOUR-BUCKET \
  --member=serviceAccount:repo-mirror@YOUR-PROJECT.iam.gserviceaccount.com \
  --role=projects/YOUR-PROJECT/roles/repoMirrorList --condition=None
```

Then in the repo: **Settings → Secrets and variables → Actions** → add variable
`BACKUP_BUCKET=YOUR-BUCKET` and secret `GCS_SA_KEY` = the **repo-mirror** SA key.

Verify the scoping before trusting it — as the mirror SA, a write to `repo-mirror/`
must succeed while a read or write under any other prefix must be denied.

### 4. Configure and schedule `backup.sh`

Set the backup variables in `.env` (see `.env.example`), then add the job to the
managed `crontab` (a commented example is already there).

## Restore

### Rebuild rclone on a fresh machine

1. Install docker, rclone, git, zstd, tar, and your secret tool (e.g. sops + age).
2. Restore your secret-decryption key (e.g. the age key) to its expected path.
3. Get the repo:
   - Normal: `git clone <your repo>`
   - **Git host down?** Pull the mirror bundle from the bucket with just the SA key,
     then clone it locally:
     ```bash
     rclone copy storage:YOUR-BUCKET/repo-mirror/repo.bundle ./
     git clone repo.bundle repo && cd repo
     ```
4. Decrypt the backup SA key + crypt password from your vault, configure the two
   rclone remotes (setup step 2 above).
5. Pull the latest archive:
   ```bash
   rclone copy crypt:backups/ ./restore/ --include '*.tar.zst' --max-age 8d
   ```

### Full rebuild on a new server

1. Extract: `tar --zstd -xf ./restore/backup-*.tar.zst -C ./restore/extracted/`
2. Place config files back under your stacks dir. Mind the archive layout under
   `configs/`: `.env` is stored as `configs/env` (**rename it back to `.env`**);
   extra secret files keep their relative path; compose files are nested under their
   original absolute path (e.g. `configs/home/<user>/docker-stacks/.../docker-compose.yml`).
3. Bring up the management/database stacks, then stop the apps you're about to restore.
4. Restore each **volume**: `docker run --rm -v <vol>:/dst -v $PWD/restore/extracted/volumes:/src alpine sh -c 'tar xf /src/<vol>.tar -C /dst'`
5. Restore each **database**: `docker exec -i <container> mariadb -u root -p"$PW" <db> < restore/extracted/databases/<container>-<db>.sql`
6. `docker compose up -d` and verify.

## Disaster recovery: two-tier key custody

The backups are only as recoverable as the keys that unlock them. Keep **two
independent, offsite copies** of what's needed, hedging different failure modes.
The **secret-decryption key (age/SOPS) is the universal linchpin — it appears in
both tiers.** Lose every copy of it and the encrypted data is gone forever.

### Tier 1 — encrypted flash drive (no git-host access needed)

Store on a passphrase-encrypted drive, kept offsite:

- The **secret-decryption (age/SOPS) key**.
- The **backup service-account key** (the full read-capable one — *not* the scoped
  CI mirror key, which can't read backups).
- **2FA recovery codes** for your accounts.
- **Recommended:** a `git clone --mirror` of the repo **and** a copy of the latest
  **encrypted** backup archive (it's already crypt-encrypted, so safe to store as
  is). This closes the gap where your data lives *only* in the cloud bucket — with
  these, the drive alone can restore even if both the git host and the cloud
  project are gone.

Recovery: unlock the drive → restore the age key → configure rclone with the SA
key → pull the repo bundle + data from the bucket (or the drive's own copies) →
decrypt the vault → restore. **No git-host login, no cloud console.**

### Tier 2 — paper (no drive needed, but needs your git-host login)

Write on paper, kept offsite (a different location from the drive):

- The **secret-decryption (age/SOPS) key**.
- **2FA recovery codes**.
- Your **git-host account password**.
- The **drive's encryption passphrase** (so Tier 1 is never orphaned).

Recovery: log into your git host (password + 2FA recovery) → clone the repo → use
the age key to decrypt the vault (which contains the SA key + crypt password) →
pull data from the bucket → restore. **Requires the git host *and* the cloud
bucket to still exist.**

### Discipline (or the offline copies silently rot)

- **Rotation breaks paper.** Every time you rotate the git-host password or 2FA,
  **rewrite the paper immediately** — a stale paper credential fails Tier 2 with no
  warning.
- **Flash degrades unpowered.** Re-write the drive ~annually (also refreshes the
  data copy). Paper is your most durable medium; never let the drive be the *only*
  copy of anything.
- **Separate the two copies geographically** so one site loss can't take both.
- **Test-restore quarterly** and confirm the media still reads and creds still work.
- Keep the **cloud project's billing healthy** — a lapsed project deletes the
  bucket, and only the Tier-1 drive data copy survives that.

### Recovery decision tree

```
Have the flash drive? ──YES──▶ TIER 1: unlock drive → restore age key → rclone w/
│                                SA key → pull repo bundle + data from bucket (or
│                                drive's own copies) → decrypt vault → restore.
│                                No git host, no cloud console.
│
└──NO──▶ Have the paper?  ──YES──▶ TIER 2: git-host login (password + 2FA) → clone
         │                          repo → age key → decrypt vault → SA key + crypt
         │                          pw → pull data from bucket → restore.
         │                          Requires git host + cloud bucket alive.
         │
         └──NO──▶ age/SOPS key lost → unrecoverable.  (Hence ≥2 offsite copies.)
```

## Test restore (quarterly)

```bash
# On a spare machine, after the rclone rebuild above:
rclone copy crypt:backups/ ./test-restore/ --max-age 8d
tar --zstd -tf ./test-restore/backup-*.tar.zst | head -20
# spot-check a database dump / volume tar opens cleanly, then discard.
```
