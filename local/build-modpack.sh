echo "Building client modpack..."
BUILD_DIR="modpack_build"
BASE_ZIP="base-modpack.zip"

if [ ! -f "$BASE_ZIP" ]; then
    echo "Error: $BASE_ZIP not found!"
    echo "Please download the official client zip from CurseForge, name it base-modpack.zip, and place it in the local/ directory."
    exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Extract the official manifest and base overrides
echo "Extracting base modpack..."
unzip -q "$BASE_ZIP" -d "$BUILD_DIR/"

# Add custom configs (ignore private env vars)
echo "Copying config overrides..."
mkdir -p "$BUILD_DIR/overrides/config"
cp -r config-overrides/* "$BUILD_DIR/overrides/config/" 2>/dev/null || true
rm -f "$BUILD_DIR/overrides/config/"*.env

# Add extra client mods
echo "Injecting extra client mods..."
mkdir -p "$BUILD_DIR/overrides/mods"
mkdir -p client-mods
cp client-mods/*.jar "$BUILD_DIR/overrides/mods/" 2>/dev/null || true

# Zip it up
echo "Compressing modpack.zip..."
cd "$BUILD_DIR" || exit
zip -q -r ../modpack.zip ./*
cd ..

# Upload directly to Caddy on AWS
echo "Uploading to cloud gateway..."
CLOUD_IP=$(cd ../cloud && terraform output -raw public_ip)
scp -o "StrictHostKeyChecking=no" -i ../cloud/id_rsa.pem modpack.zip "ubuntu@$CLOUD_IP:/home/ubuntu/"
ssh -o "StrictHostKeyChecking=no" -i ../cloud/id_rsa.pem "ubuntu@$CLOUD_IP" "sudo mv /home/ubuntu/modpack.zip /opt/mc-status/modpack.zip && sudo chmod 644 /opt/mc-status/modpack.zip"

echo "Deployment complete! Verify at https://<your_domain_here>/modpack.zip"