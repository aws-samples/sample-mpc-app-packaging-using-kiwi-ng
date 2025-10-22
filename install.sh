#!/bin/bash
set -e

# Start timing
START_TIME="$(date +%s)"
echo "[$(date)] Starting install.sh execution"

# Default values
IMAGE_NAME="al2023-attestable-image-mpc-webapp-example"
TARGET_DIR="./image"
SAMPLE_APP_REPO_NAME="sample-mpc-app-using-aws-nitrotpm"

# Parse named parameters
while [[ $# -gt 0 ]]; do
    case $1 in
        --image-name)
            IMAGE_NAME="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --image-name NAME       AMI image name (default: al2023-attestable-image-mpc-webapp-example)"
            echo "  -h, --help             Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done


# Setup instance store if available
echo "[$(date)] Checking for instance store..."
INSTANCE_STORE_DEV="$(lsblk -d -o NAME,TYPE | grep disk | grep -v nvme0n1 | head -1 | awk '{print "/dev/"$1}' || true)"
if [ -n "$INSTANCE_STORE_DEV" ] && [ -b "$INSTANCE_STORE_DEV" ]; then
    if ! mountpoint -q /mnt; then
        echo "[$(date)] Mounting instance store $INSTANCE_STORE_DEV to /mnt"
        sudo mkfs.xfs -f "$INSTANCE_STORE_DEV"
        sudo mount "$INSTANCE_STORE_DEV" /mnt
        sudo chmod 777 /mnt
    fi
    TARGET_DIR="/mnt/image"
    echo "[$(date)] Using instance store for build: $TARGET_DIR"
else
    echo "[$(date)] No instance store found, using EBS storage"
fi

# Cleanup previous run
sudo rm -rf "$TARGET_DIR" "./$SAMPLE_APP_REPO_NAME"

# Install dependencies
DEPS_START="$(date +%s)"
echo "[$(date)] Installing dependencies..."
sudo dnf install -y \
    kiwi-cli \
    python3-kiwi \
    kiwi-systemdeps-core \
    python3-poetry-core \
    qemu-img \
    veritysetup \
    erofs-utils \
    git \
    cargo \
    aws-nitro-tpm-tools
DEPS_END="$(date +%s)"
echo "[$(date)] Dependencies installed in $((DEPS_END - DEPS_START)) seconds"


# Clone the sample MPC app repository
CLONE_START="$(date +%s)"
echo "[$(date)] Cloning sample MPC app repository..."
if [ -d "$SAMPLE_APP_REPO_NAME" ]; then
    echo "Repository already exists, pulling latest changes..."
    cd "$SAMPLE_APP_REPO_NAME"
    git pull
    cd ..
else
    git clone "https://github.com/aws-samples/$SAMPLE_APP_REPO_NAME.git"
fi
CLONE_END="$(date +%s)"
echo "[$(date)] Repository cloned in $((CLONE_END - CLONE_START)) seconds"

# Sync latest frontend and backend changes to overlay
echo "Syncing latest $SAMPLE_APP_REPO_NAME changes to overlay..."
mkdir -p "recipe/test-image-overlayroot/overlay-files/home/ec2-user/$SAMPLE_APP_REPO_NAME/frontend/"
mkdir -p "recipe/test-image-overlayroot/overlay-files/home/ec2-user/$SAMPLE_APP_REPO_NAME/backend/"
cp -r "$SAMPLE_APP_REPO_NAME/frontend/"* "recipe/test-image-overlayroot/overlay-files/home/ec2-user/$SAMPLE_APP_REPO_NAME/frontend/"
cp -r "$SAMPLE_APP_REPO_NAME/backend/"* "recipe/test-image-overlayroot/overlay-files/home/ec2-user/$SAMPLE_APP_REPO_NAME/backend/"

# Sync service files to overlay
echo "Syncing service files to overlay..."
mkdir -p recipe/test-image-overlayroot/overlay-files/etc/systemd/system/
mkdir -p recipe/test-image-overlayroot/overlay-files/usr/local/bin/
cp "$SAMPLE_APP_REPO_NAME/dev_build/systemd/"* recipe/test-image-overlayroot/overlay-files/etc/systemd/system/
cp "$SAMPLE_APP_REPO_NAME/dev_build/scripts/setup"* recipe/test-image-overlayroot/overlay-files/usr/local/bin/

# Rebuild overlay.tar.gz from overlay-files directory
echo "Rebuilding overlay.tar.gz from overlay-files..."
cd recipe/test-image-overlayroot/overlay-files && tar -czf ../overlay.tar.gz . && cd ../../../




# Install coldsnap CLI for snapshot -> AMI creation
COLDSNAP_BUILD_START="$(date +%s)"
if [ ! -f "~/.cargo/bin/coldsnap" ]; then
    echo "[$(date)] Installing coldsnap..."
    if [ ! -d "coldsnap" ]; then
        git clone https://github.com/awslabs/coldsnap.git
    fi
    
    pushd coldsnap
    cargo install --locked coldsnap
    popd
else
    echo "[$(date)] coldsnap already available, skipping installation"
fi
COLDSNAP_BUILD_END="$(date +%s)"
echo "[$(date)] Coldsnap setup completed in $((COLDSNAP_BUILD_END - COLDSNAP_BUILD_START)) seconds"

# Build the image
KIWI_START="$(date +%s)"
echo "[$(date)] Starting Kiwi image build..."
# Output image file will be at $TARGET_DIR/kiwi-test-image-overlayroot.<architecture>-1.42.1.raw
sudo kiwi-ng \
    --debug \
    --color-output \
    --loglevel 50 \
    system build \
    --description recipe/test-image-overlayroot \
    --target-dir "$TARGET_DIR"
KIWI_END="$(date +%s)"
echo "[$(date)] Kiwi build completed in $((KIWI_END - KIWI_START)) seconds"

# Upload the image file to a snapshot
SNAPSHOT_START="$(date +%s)"
echo "[$(date)] Uploading image to snapshot..."
SNAPSHOT="$(~/.cargo/bin/coldsnap upload "$TARGET_DIR/$IMAGE_NAME"*.raw)"
SNAPSHOT_END="$(date +%s)"

echo "[$(date)] Created snapshot: $SNAPSHOT in $((SNAPSHOT_END - SNAPSHOT_START)) seconds"
echo "Waiting for snapshot to complete..."

# Wait a bit for snapshot to complete
sleep 10

ARCH="$(uname -p)"

# convert aarch64 to arm64 for AMI registration
if [ "$ARCH" == "aarch64" ]; then
    ARCH="arm64"
fi

# Register a TPM-enabled AMI from the snapshot
REGISTER_START="$(date +%s)"
echo "[$(date)] Registering AMI..."
# Modify the --name parameter as desired
aws ec2 register-image \
    --name "${IMAGE_NAME}-$(date +%Y%m%d%H%M)" \
    --virtualization-type hvm \
    --boot-mode uefi \
    --architecture "${ARCH}" \
    --root-device-name /dev/xvda \
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=${SNAPSHOT}}" \
    --tpm-support v2.0 \
    --ena-support
REGISTER_END="$(date +%s)"

# Print timing summary
END_TIME="$(date +%s)"
TOTAL_TIME=$((END_TIME - START_TIME))

echo -e "\n=== BUILD TIMING SUMMARY ==="
echo "Dependencies: $((DEPS_END - DEPS_START)) seconds"
echo "Repository clone: $((CLONE_END - CLONE_START)) seconds"
echo "Coldsnap setup: $((COLDSNAP_BUILD_END - COLDSNAP_BUILD_START)) seconds"
echo "Kiwi build: $((KIWI_END - KIWI_START)) seconds"
echo "Snapshot upload: $((SNAPSHOT_END - SNAPSHOT_START)) seconds"
echo "AMI registration: $((REGISTER_END - REGISTER_START)) seconds"
echo "TOTAL TIME: $TOTAL_TIME seconds ($((TOTAL_TIME / 60)) minutes)"
echo "[$(date)] Build completed successfully!"
