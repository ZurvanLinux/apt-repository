#!/usr/bin/env bash
set -euo pipefail

KEY_NAME="Zurvan Linux Archive"
KEY_EMAIL="archive@zurvanlinux.org"
KEY_LENGTH=4096
BATCH_FILE="/tmp/gpg-batch-$$"
PASSPHRASE_FILE="/tmp/zurvan-gpg-passphrase.txt"

cleanup() {
  rm -f "${BATCH_FILE}"
}
trap cleanup EXIT

if gpg --list-keys "${KEY_EMAIL}" >/dev/null 2>&1; then
  FPR=$(gpg --list-keys --with-colons "${KEY_EMAIL}" | awk -F: '/^pub:/ {print $10; exit}')
  echo "ERROR: A key for ${KEY_EMAIL} already exists in this keyring."
  echo "       Aborting to avoid overwriting.  Remove it first:"
  echo "         gpg --batch --yes --delete-secret-keys ${FPR}"
  echo "         gpg --batch --yes --delete-keys ${FPR}"
  exit 1
fi

SUBKEY_PASSPHRASE=$(openssl rand -base64 32 | tr -d '\n')

echo "[*] Generating passphrase ..."
echo "    ${SUBKEY_PASSPHRASE}"

cat > "${BATCH_FILE}" <<EOF
%echo Generating Zurvan Linux Archive key pair
Key-Type: RSA
Key-Length: ${KEY_LENGTH}
Subkey-Type: RSA
Subkey-Length: ${KEY_LENGTH}
Subkey-Usage: sign
Name-Real: ${KEY_NAME}
Name-Email: ${KEY_EMAIL}
Expire-Date: 0
Passphrase: ${SUBKEY_PASSPHRASE}
%commit
%echo done
EOF

echo "[*] Generating offline ${KEY_LENGTH}-bit RSA primary key + signing subkey ..."
gpg --batch --gen-key "${BATCH_FILE}"

PRIMARY_KEYID=$(gpg --list-keys --with-colons "${KEY_EMAIL}" | awk -F: '/^pub:/ {print $5; exit}')
SUBKEY_KEYID=$(gpg --list-keys --with-colons "${KEY_EMAIL}" | awk -F: '/^sub:/ {print $5; exit}')
echo "=== Primary key: ${PRIMARY_KEYID} ==="
echo "=== Signing subkey: ${SUBKEY_KEYID} ==="

OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PUB_FILE="${OUT_DIR}/public.key"
SEC_FILE="${OUT_DIR}/secret-subkey.asc"

echo "[*] Exporting public key -> ${PUB_FILE}"
gpg --armor --export "${KEY_EMAIL}" > "${PUB_FILE}"

echo "[*] Exporting secret subkey -> ${SEC_FILE}"
gpg --pinentry-mode loopback --passphrase "${SUBKEY_PASSPHRASE}" \
  --armor --export-secret-subkeys "${PRIMARY_KEYID}" > "${SEC_FILE}" || true
if [[ ! -s "${SEC_FILE}" ]]; then
  echo "ERROR: Failed to export secret subkey." >&2
  exit 1
fi

chmod 600 "${PUB_FILE}" "${SEC_FILE}"

echo "[*] Saving passphrase -> ${PASSPHRASE_FILE}"
echo "${SUBKEY_PASSPHRASE}" > "${PASSPHRASE_FILE}"
chmod 600 "${PASSPHRASE_FILE}"

cat <<EOF

=============================================================
  GPG key generation complete
=============================================================

  Primary key (OFFLINE):    ${PRIMARY_KEYID}
  Signing subkey:           ${SUBKEY_KEYID}
  Subkey passphrase:        ${SUBKEY_PASSPHRASE}
  Public key:               ${PUB_FILE}
  Secret subkey:            ${SEC_FILE}
  Passphrase file:          ${PASSPHRASE_FILE}

GITHUB ACTIONS SECRETS (apt-repository repo)
--------------------------------------------
  APT_SIGNING_SUBKEY:       contents of secret-subkey.asc
  APT_SIGNING_PASSPHRASE:   ${SUBKEY_PASSPHRASE}

NEXT STEPS:
----------------------------------------
1. Commit public.key to apt-repository repo root if not already done.

2. Add the two secrets above in GitHub:
   Settings -> Secrets and variables -> Actions -> New repository secret

3. After storing secrets, delete the temporary files:
       rm -f ${PASSPHRASE_FILE}
       rm -f ${SEC_FILE}

4. Keep the primary key offline / air-gapped permanently.
=============================================================
EOF
