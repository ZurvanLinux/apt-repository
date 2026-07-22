#!/usr/bin/env bash
set -euo pipefail

KEY_NAME="Zurvan Linux Archive"
KEY_EMAIL="archive@zurvanlinux.org"
KEY_LENGTH=4096

if gpg --list-keys "${KEY_EMAIL}" >/dev/null 2>&1; then
  FPR=$(gpg --list-keys --with-colons "${KEY_EMAIL}" | awk -F: '/^pub:/ {print $10; exit}')
  echo "ERROR: A key for ${KEY_EMAIL} already exists in this keyring."
  echo "       Aborting to avoid overwriting.  Remove it first if intended:"
  echo "         gpg --batch --yes --delete-secret-keys ${FPR}"
  echo "         gpg --batch --yes --delete-keys ${FPR}"
  exit 1
fi

cat > /tmp/gpg-batch-primary-$$ <<EOF
%no-protection
Key-Type: RSA
Key-Length: ${KEY_LENGTH}
Name-Real: ${KEY_NAME}
Name-Email: ${KEY_EMAIL}
Expire-Date: 0
%commit
EOF

echo "[*] Generating offline 4096-bit RSA primary key for ${KEY_EMAIL} ..."
gpg --batch --gen-key /tmp/gpg-batch-primary-$$

PRIMARY_KEYID=$(gpg --list-keys --with-colons "${KEY_EMAIL}" | awk -F: '/^pub:/ {print $5; exit}')
echo "=== Primary key: ${PRIMARY_KEYID} ==="

cat > /tmp/gpg-addkey-$$.exp <<EOF
#!/usr/bin/env expect -f
set timeout 30
set keyid [lindex \$argv 0]
spawn gpg --pinentry-mode loopback --passphrase '' --edit-key \$keyid
expect "gpg> "
send "addkey\r"
expect "keyt"
send "4\r"
expect "keys"
send "${KEY_LENGTH}\r"
expect "expire"
send "0\r"
expect "y/N"
send "y\r"
expect "y/N"
send "y\r"
expect "gpg> "
send "save\r"
expect eof
EOF
chmod +x /tmp/gpg-addkey-$$.exp

echo "[*] Adding signing-only subkey ..."
/tmp/gpg-addkey-$$.exp "${PRIMARY_KEYID}"

SUBKEY_FPR=$(gpg --list-keys --with-colons "${KEY_EMAIL}" | awk -F: '/^sub:/ {print $5; exit}')
echo "=== Signing subkey fingerprint: ${SUBKEY_FPR} ==="

OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "[*] Exporting public key -> ${OUT_DIR}/public.key"
gpg --armor --export "${KEY_EMAIL}" > "${OUT_DIR}/public.key"

echo "[*] Exporting secret subkey -> ${OUT_DIR}/secret-subkey.asc"
gpg --armor --export-secret-subkeys "${PRIMARY_KEYID}" > "${OUT_DIR}/secret-subkey.asc" || true
if [[ ! -s "${OUT_DIR}/secret-subkey.asc" ]]; then
  echo "ERROR: Failed to export secret subkey." >&2
  exit 1
fi

chmod 600 "${OUT_DIR}/public.key" "${OUT_DIR}/secret-subkey.asc"

cat <<EOF

=============================================================
  GPG key generation complete
=============================================================

  Primary key (OFFLINE):    ${PRIMARY_KEYID}
  Signing subkey:           ${SUBKEY_FPR}
  Public key:               ${OUT_DIR}/public.key
  Secret subkey:            ${OUT_DIR}/secret-subkey.asc

NEXT STEPS (per apt-repository/README.md):
----------------------------------------
1. Move ONLY ${OUT_DIR}/public.key and ${OUT_DIR}/secret-subkey.asc
   to your secure workstation.

2. Commit public.key to the apt-repository repository root:
       git add public.key && git commit -m "chore(apt): add APT repo signing public key"

3. In GitHub, add these secrets to the apt-repository repo:
       Settings -> Secrets and variables -> Actions -> New repository secret

   Name:  APT_SIGNING_SUBKEY
   Value: contents of secret-subkey.asc  (the whole armored block)

   Name:  APT_SIGNING_PASSPHRASE
   Value: leave blank / unset unless the exported subkey is passphrase-protected
          (the publish-repo.yml worklow invokes gpg with --pinentry-mode loopback
           and APT_SIGNING_PASSPHRASE at signing time).

4. Keep the primary key offline / air-gapped permanently.
   If the subkey leaks, revoke it from the offline primary key and
   generate a new signing subkey.

5. Re-run .github/workflows/publish-repo.yml to verify signing works.
=============================================================
EOF
