echo "Building client modpack..."
BUILD_DIR="modpack_build"
BASE_ZIP="base-modpack.zip"

# Helper function to prevent terminal from instantly closing on error
pause_and_exit() {
    echo "========================================"
    echo "$1"
    echo "========================================"
    echo "Press Enter to exit..."
    read -r
    exit 1
}

# --- Environment Variable Validation ---
if [ -z "${CF_API_KEY}" ]; then
    pause_and_exit "Error: CF_API_KEY is not set. Ensure you run this via 'make deploy-modpack' or export it first."
fi

if [ -z "${MODPACK_SLUG}" ]; then
    pause_and_exit "Error: MODPACK_SLUG is not set. Ensure you run this via 'make deploy-modpack' or export it first."
fi
# ---------------------------------------

echo "Checking CurseForge API for the latest client modpack..."

MOD_DATA=$(curl -s -H "x-api-key: ${CF_API_KEY}" "https://api.curseforge.com/v1/mods/search?gameId=432&slug=${MODPACK_SLUG}")
MOD_ID=$(echo "${MOD_DATA}" | jq -r ".data[0].id")
LATEST_FILE_ID=$(echo "${MOD_DATA}" | jq -r ".data[0].mainFileId")

if [ -z "${MOD_ID}" ] || [ "${MOD_ID}" == "null" ]; then
    pause_and_exit "Error: Could not resolve modpack slug ${MODPACK_SLUG} via CurseForge API."
fi

DL_INFO=$(curl -s -H "x-api-key: ${CF_API_KEY}" "https://api.curseforge.com/v1/mods/${MOD_ID}/files/${LATEST_FILE_ID}/download-url")
DL_URL=$(echo "${DL_INFO}" | jq -r ".data")

echo "Downloading ${MODPACK_SLUG} (File ID: ${LATEST_FILE_ID})..."
curl -# -L "${DL_URL}" -o "${BASE_ZIP}"

if [ ! -f "${BASE_ZIP}" ]; then
    pause_and_exit "Error: Download failed! ${BASE_ZIP} not found."
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Extract the official manifest and base overrides
echo "Extracting base modpack..."
unzip -q "${BASE_ZIP}" -d "${BUILD_DIR}/"

# Add custom configs (ignore private env vars)
echo "Copying config overrides..."
mkdir -p "${BUILD_DIR}/overrides/config"
cp -r "config-overrides/"* "${BUILD_DIR}/overrides/config/" 2>/dev/null || true
rm -f "${BUILD_DIR}/overrides/config/"*.env

# Add extra client mods
echo "Injecting extra client mods..."
mkdir -p "${BUILD_DIR}/overrides/mods"
mkdir -p "client-mods"
cp "client-mods/"*.jar "${BUILD_DIR}/overrides/mods/" 2>/dev/null || true

# Zip it up
echo "Compressing modpack.zip..."
cd "${BUILD_DIR}" || pause_and_exit "Error: Could not enter build directory."

if command -v pv >/dev/null 2>&1; then
    echo "Using pv for compression progress..."
    zip -q -r - ./* | pv -treb > "../modpack.zip"
else
    echo "pv not found. Compressing silently..."
    zip -q -r "../modpack.zip" ./*
fi
cd ..

# Upload directly to Caddy on AWS
echo "Uploading to cloud gateway..."
CLOUD_IP=$(cd ../cloud && terraform output -raw public_ip)

if [ -z "${CLOUD_IP}" ]; then
    pause_and_exit "Error: Could not retrieve Cloud IP from Terraform."
fi

scp -o "StrictHostKeyChecking=no" -i "../cloud/id_rsa.pem" "modpack.zip" "ubuntu@${CLOUD_IP}:/home/ubuntu/" || pause_and_exit "Error: SCP upload failed."

ssh -o "StrictHostKeyChecking=no" -i "../cloud/id_rsa.pem" "ubuntu@${CLOUD_IP}" "sudo mv /home/ubuntu/modpack.zip /opt/mc-status/modpack.zip && sudo chmod 644 /opt/mc-status/modpack.zip" || pause_and_exit "Error: SSH file move failed."

echo "Deployment complete! Verify at https://<your_domain_here>/modpack.zip"
exit 0