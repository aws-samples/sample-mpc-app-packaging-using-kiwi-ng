#!/bin/bash
set -e

# Function to handle errors
handle_error() {
    echo "[CONFIG.SH] ERROR: $1" >> /var/log/kiwi-config.log
    exit 1
}

# Trap errors
trap 'handle_error "Script failed at line $LINENO"' ERR

# Log config.sh execution
echo "[CONFIG.SH] Starting config.sh execution at $(date)" >> /var/log/kiwi-config.log

# Ensure DNS resolution works during build
echo "[CONFIG.SH] Configuring DNS resolution" >> /var/log/kiwi-config.log
echo "[CONFIG.SH] Current resolv.conf:" >> /var/log/kiwi-config.log
cat /etc/resolv.conf >> /var/log/kiwi-config.log 2>&1 || echo "[CONFIG.SH] No resolv.conf found" >> /var/log/kiwi-config.log
# Remove symlink and create static resolv.conf
rm -f /etc/resolv.conf
echo "nameserver 172.31.0.2" > /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf
echo "search us-east-2.compute.internal" >> /etc/resolv.conf
echo "[CONFIG.SH] DNS configured, testing connectivity" >> /var/log/kiwi-config.log
nslookup ollama.com >> /var/log/kiwi-config.log 2>&1 || echo "[CONFIG.SH] DNS lookup failed" >> /var/log/kiwi-config.log

# Configure localhost networking for ZOA (alternative to cloud-init)
echo "[CONFIG.SH] Configuring localhost networking" >> /var/log/kiwi-config.log

# Configure /etc/hosts
cat > /etc/hosts << 'EOF'
127.0.0.1   localhost localhost.localdomain
::1         localhost localhost.localdomain
EOF

# Create systemd-networkd config for loopback
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/10-lo.network << 'EOF'
[Match]
Name=lo

[Network]
DHCP=no
IPv6AcceptRA=no

[Address]
Address=127.0.0.1/8

[Address]
Address=::1/128
EOF

# Enable systemd-networkd for basic networking
systemctl enable systemd-networkd
systemctl enable systemd-resolved
echo "[CONFIG.SH] Localhost networking configured" >> /var/log/kiwi-config.log

# Create ec2-user
echo "[CONFIG.SH] Creating ec2-user" >> /var/log/kiwi-config.log
if ! id ec2-user &>/dev/null; then
    useradd -M -s /bin/bash ec2-user
    # Set proper ownership for existing home directory
    chown -R ec2-user:ec2-user /home/ec2-user
fi

# Create ollama group and user
echo "[CONFIG.SH] Creating ollama user and group" >> /var/log/kiwi-config.log
groupadd -r ollama || true
useradd -r -s /bin/false -d /var/lib/ollama -g ollama -G video,render ollama || true
mkdir -p /var/lib/ollama
chown ollama:ollama /var/lib/ollama
chmod 755 /var/lib/ollama
echo "[CONFIG.SH] Ollama user created successfully" >> /var/log/kiwi-config.log

# Make scripts executable
chmod +x /usr/local/bin/setup-instance-store.sh || true
chmod +x /usr/local/bin/setup-ollama-permissions.sh || true

# Ensure custom ollama service file with GPU settings is preserved
# The ollama package may overwrite our custom service file, so we restore it here
if [ -f /etc/systemd/system/ollama.service ]; then
    # Add GPU environment variables to ollama service if not present
    if ! grep -q "OLLAMA_NUM_GPU_LAYERS" /etc/systemd/system/ollama.service; then
        # Insert environment variables before the [Install] section
        sed -i '/^\[Install\]/i\Environment=LD_LIBRARY_PATH=/usr/lib64:/usr/local/cuda/lib64:/usr/local/cuda/targets/x86_64-linux/lib:/lib64\nEnvironment=CUDA_PATH=/usr/local/cuda\nEnvironment=OLLAMA_NUM_GPU_LAYERS=33\nEnvironment=OLLAMA_LLM_LIBRARY=cuda' /etc/systemd/system/ollama.service
    fi
fi

# Node.js is now installed via Kiwi packages
echo "[CONFIG.SH] Node.js installed via Kiwi packages" >> /var/log/kiwi-config.log

# Install Python dependencies for backend
echo "[CONFIG.SH] Installing Python dependencies" >> /var/log/kiwi-config.log
cd /home/ec2-user/sample-mpc-app-using-aws-nitrotpm/backend
# Install dependencies without upgrading pip to avoid RPM conflicts
pip3 install -r requirements.txt >> /var/log/kiwi-config.log 2>&1

# Install Node.js dependencies for frontend
echo "[CONFIG.SH] Installing Node.js dependencies" >> /var/log/kiwi-config.log
cd /home/ec2-user/sample-mpc-app-using-aws-nitrotpm/frontend
npm install >> /var/log/kiwi-config.log 2>&1

# Build React app for production
echo "[CONFIG.SH] Building React app for production" >> /var/log/kiwi-config.log
npm run build >> /var/log/kiwi-config.log 2>&1

# Set proper ownership for sample-mpc-app-using-aws-nitrotpm directory
chown -R ec2-user:ec2-user /home/ec2-user/sample-mpc-app-using-aws-nitrotpm

# Enable services
echo "[CONFIG.SH] Enabling services" >> /var/log/kiwi-config.log
systemctl enable setup-instance-store.service
systemctl enable ollama-permissions.service
systemctl enable nvidia-devices.path
systemctl enable nvidia-devices.service
systemctl enable ollama.service
systemctl enable ollama-backend.service
systemctl enable ollama-frontend.service
echo "[CONFIG.SH] Services enabled" >> /var/log/kiwi-config.log

# FOA-specific configuration
# Enable SSM agent that comes with AL2023
# systemctl enable amazon-ssm-agent

# Configure firewall to only expose ports 3000 and 8000
echo "[CONFIG.SH] Configuring firewall" >> /var/log/kiwi-config.log
systemctl enable firewalld
# Remove default zone services
firewall-offline-cmd --remove-service=ssh
firewall-offline-cmd --remove-service=dhcpv6-client
# Add only required ports for external access
firewall-offline-cmd --add-port=3000/tcp
# Allow localhost communication for internal services
firewall-offline-cmd --add-rich-rule='rule family="ipv4" source address="127.0.0.1" accept'
firewall-offline-cmd --add-rich-rule='rule family="ipv6" source address="::1" accept'
echo "[CONFIG.SH] Firewall configured to expose port 3000 and allow localhost" >> /var/log/kiwi-config.log

# Install CUDA-enabled ollama (Amazon Linux package is CPU-only)
echo "[CONFIG.SH] Installing CUDA-enabled ollama" >> /var/log/kiwi-config.log
echo "[CONFIG.SH] Testing network connectivity first..." >> /var/log/kiwi-config.log
curl -I https://ollama.com >> /var/log/kiwi-config.log 2>&1 || echo "[CONFIG.SH] Network test failed" >> /var/log/kiwi-config.log
echo "[CONFIG.SH] Downloading ollama installer..." >> /var/log/kiwi-config.log
if curl -fsSL https://ollama.com/install.sh > /tmp/ollama-install.sh 2>> /var/log/kiwi-config.log; then
    echo "[CONFIG.SH] Download successful, running installer..." >> /var/log/kiwi-config.log
    if sh /tmp/ollama-install.sh >> /var/log/kiwi-config.log 2>&1; then
        echo "[CONFIG.SH] Ollama installation successful" >> /var/log/kiwi-config.log
        which ollama >> /var/log/kiwi-config.log 2>&1 || echo "[CONFIG.SH] Ollama not in PATH" >> /var/log/kiwi-config.log
        ls -l /usr/local/bin/ollama /usr/bin/ollama >> /var/log/kiwi-config.log 2>&1 || echo "[CONFIG.SH] Ollama binaries not found" >> /var/log/kiwi-config.log
    else
        echo "[CONFIG.SH] Ollama installation script FAILED" >> /var/log/kiwi-config.log
    fi
else
    echo "[CONFIG.SH] Failed to download ollama installer" >> /var/log/kiwi-config.log
fi

# Load NVIDIA modules at boot
echo 'nvidia' >> /etc/modules-load.d/nvidia.conf
echo 'nvidia-drm' >> /etc/modules-load.d/nvidia.conf
echo 'nvidia-uvm' >> /etc/modules-load.d/nvidia.conf
echo 'nvidia-modeset' >> /etc/modules-load.d/nvidia.conf

echo "[CONFIG.SH] Config.sh completed successfully at $(date)" >> /var/log/kiwi-config.log

