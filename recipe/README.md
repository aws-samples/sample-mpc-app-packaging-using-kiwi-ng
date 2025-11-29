# Kiwi-ng Recipe to package the sample app into a ZOA Attestable Amazon Machine Image (AMI).
appliance.kiwi, config.sh and overaly-files specific to Nvidia and TPM device configuraiton are core files to review.


## Debugging steps.


### Spot errors issues with current run

Check these two files for anything that looks like causing the failures, increase the kiwi logging level as needed
. Set [loglevel](install.sh#L129) to 0.

```sh
zoa_install.log
./image/build/image-root/var/log/kiwi-config.log
```

### Create an image with operator access

Turn on SSM and/or SSH access to debug this recipe. Include the packages ignored below.
```xml
        <ignore name="openssh-server"/>
        <ignore name="amazon-ssm-agent"/>
```

### Ollama debug

Use the below command to check the status and test various frontend/backend components including the ollama itself from within the EC2 intances created to debug based on the image generated with operator access.


```sh
# Test Ollama
curl http://localhost:11434/api/version


wget -O mistral.gguf https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF/resolve/main/mistral-7b-instruct-v0.2.Q4_K_M.gguf?download=true

sha256sum mistral.gguf

curl -T mistral.gguf -X POST http://localhost:11434/api/blobs/sha256:3e0039fd0273fcbebb49228943b17831aadd55cbcbf56f0af00499be2040ccf9


curl http://localhost:11434/api/create -d '{
  "model": "mistral",
  "files": {
    "mistral.gguf": "sha256:3e0039fd0273fcbebb49228943b17831aadd55cbcbf56f0af00499be2040ccf9"
  }
}'

curl http://localhost:11434/api/generate -d '{
  "model": "mistral",
  "prompt": "What is artificial intelligence?"
}'

curl http://localhost:11434/api/ps

```

### Nvidia configuration debug steps

Use below steps to debug Nvidia device, drivers and configuration.

```sh
# Install NVIDIA repository configuration
sudo dnf install -y nvidia-release

# Update repository metadata
sudo dnf makecache

# Now search for NVIDIA packages
sudo dnf search nvidia

# Install NVIDIA driver and DKMS module
sudo dnf install -y nvidia-driver nvidia-driver-cuda kmod-nvidia-latest-dkms

# Check DKMS status after installation
sudo dkms status

# Try to build and install the module
sudo dkms autoinstall

# Reboot to load the driver
sudo reboot

nvidia-smi
ls -l /dev/nvidia*


# Load the NVIDIA module
sudo modprobe nvidia

# Check if it loaded
lsmod | grep nvidia

# Check for device files
ls -l /dev/nvidia*

# Test nvidia-smi
nvidia-smi

# Check what's actually in the nvidia directory
ls -la /dev/nvidia*

# Or check for nvidia devices differently
ls -l /dev/ | grep nvidia

# The devices should be created when you run a CUDA application
# Try running a simple CUDA command to trigger device creation
nvidia-smi -L

```

### Miscellaneious debug commands

Listing of all other debugging assist commands

```sh
# Stop the ollama service
sudo systemctl stop ollama
sudo systemctl disable ollama

# Or kill the ollama process directly
sudo pkill ollama

# Or find and kill by PID
ps aux | grep ollama
sudo kill <PID>

ldd /usr/bin/ollama | grep -i cuda


sudo journalctl -u ollama -n 50
# Look for CUDA/GPU initialization messages or errors


sudo -u ollama nvidia-smi
sudo -u ollama ls -l /dev/nvidia*


ldconfig -p | grep cuda
ldconfig -p | grep nvidia


sudo -u ollama /usr/bin/ollama --version
# Check if it shows GPU support


sudo systemctl show ollama | grep Environment


# Check if CUDA runtime is working
/usr/local/cuda/bin/nvcc --version 2>/dev/null || echo "CUDA compiler not found"


# List all available models (downloaded)
curl http://localhost:11434/api/tags

# Get ollama version
curl http://localhost:11434/api/version

# Show model information
curl http://localhost:11434/api/show -d '{"name": "mistral:latest"}'


sudo -u ollama nohup env \
  LD_LIBRARY_PATH="/usr/local/cuda/targets/x86_64-linux/lib:/lib64" \
  CUDA_PATH="/usr/local/cuda" \
  OLLAMA_NUM_GPU_LAYERS=33 \
  OLLAMA_LLM_LIBRARY=cuda \
  OLLAMA_DEBUG=1 \
  OLLAMA_HOST="0.0.0.0" \
  OLLAMA_MODELS="/mnt/instance-store/models" \
  NVIDIA_VISIBLE_DEVICES="all" \
  CUDA_VISIBLE_DEVICES="0" \
  HOME="/var/lib/ollama" \
  ollama serve > ollama.log 2>&1 &

sudo -u ollama nohup env \
  LD_LIBRARY_PATH="/usr/lib64/nvidia:/usr/lib64" \
  CUDA_PATH="/usr" \
  OLLAMA_HOST="0.0.0.0" \
  OLLAMA_MODELS="/mnt/instance-store/models" \
  NVIDIA_VISIBLE_DEVICES="all" \
  CUDA_VISIBLE_DEVICES="0" \
  HOME="/var/lib/ollama" \
  ollama serve > ollama.log 2>&1 &


# Check what CUDA/NVIDIA libraries are installed
ldconfig -p | grep -E "(cuda|nvidia)"

# Check if basic CUDA runtime exists
ls -la /usr/lib64/ | grep -E "(cuda|nvidia)"
ls -la /usr/local/cuda* 2>/dev/null || echo "No /usr/local/cuda"

# Check what nvidia packages are actually installed
rpm -qa | grep -i nvidia

# Simple CUDA test without python
echo '#include <cuda_runtime.h>
int main() { 
    int count; 
    cudaGetDeviceCount(&count); 
    printf("CUDA devices: %d\n", count); 
    return 0; 
}' > cuda_test.c

# Try to compile (will fail if no CUDA headers)
gcc cuda_test.c -lcudart -o cuda_test 2>/dev/null && ./cuda_test || echo "CUDA compilation failed"

# Check ollama startup with verbose logging
sudo systemctl stop ollama
sudo -u ollama OLLAMA_DEBUG=1 OLLAMA_HOST=0.0.0.0 ollama serve 2>&1 | grep -i -E "(cuda|gpu|nvidia)"


# Check nvidia-smi during inference
watch -n 1 nvidia-smi &

# Run a query and monitor GPU usage
curl -X POST http://localhost:11434/api/generate -d '{
  "model": "mistral:latest",
  "prompt": "Count from 1 to 100",
  "stream": false
}'

# Check if model is actually loaded in GPU memory
curl http://localhost:11434/api/ps

# Kill the watch process
pkill watch


# Check ollama process GPU usage
nvidia-smi pmon -i 0 -s u -c 1

# Check if CUDA context is created
sudo -u ollama nvidia-ml-py3 -c "
import pynvml
pynvml.nvmlInit()
handle = pynvml.nvmlDeviceGetHandleByIndex(0)
procs = pynvml.nvmlDeviceGetComputeRunningProcesses(handle)
print(f'GPU processes: {len(procs)}')
for p in procs:
    print(f'PID: {p.pid}, Memory: {p.usedGpuMemory/1024/1024:.1f}MB')
"

# Check GPU utilization during inference (not just memory)
nvidia-smi dmon -i 0 -s u -c 10 &

# Run inference and watch GPU utilization
curl -X POST http://localhost:11434/api/generate -d '{
  "model": "mistral:latest", 
  "prompt": "Write a long story about artificial intelligence",
  "stream": false
}'

# Check GPU processes with more detail
nvidia-smi pmon -i 0 -s um -c 5

# Check if GPU compute processes are running
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv


# 1. Check if cuDNN is properly installed
find /usr -name "*cudnn*" 2>/dev/null

# 2. Force GPU layers (add to your ollama service)
export OLLAMA_NUM_GPU_LAYERS=33

# 3. Check if model is actually using GPU compute
curl -X POST http://localhost:11434/api/generate -d '{
  "model": "mistral:latest",
  "prompt": "test",
  "options": {"num_gpu": 1}
}'

# 4. Try forcing CUDA backend
export OLLAMA_LLM_LIBRARY=cuda


curl -X POST http://localhost:11434/api/generate -d '{"model": "mistral:latest", "keep_alive": 0}'

curl http://localhost:11434/api/ps

curl -X POST http://localhost:11434/api/generate -d '{
  "model": "mistral:latest",
  "prompt": "test",
  "keep_alive": "5m"
}'


sudo systemctl status ollama-permissions

sudo journalctl -u ollama-permissions -n 20


sudo -u ollama ls -l /dev/nvidia-caps/

sudo chmod 666 /dev/nvidia-caps/nvidia-cap1
sudo chmod 666 /dev/nvidia-caps/nvidia-cap2
sudo systemctl restart ollama



sudo pkill ollama
sudo -u ollama nohup env \
  LD_LIBRARY_PATH="/usr/lib64:/usr/local/cuda-13.0/targets/x86_64-linux/lib" \
  CUDA_PATH="/usr/local/cuda-13.0" \
  OLLAMA_NUM_GPU_LAYERS=33 \
  OLLAMA_LLM_LIBRARY=cuda \
  OLLAMA_MODELS="/mnt/instance-store/models" \
  OLLAMA_HOST="0.0.0.0" \
  NVIDIA_VISIBLE_DEVICES="all" \
  CUDA_VISIBLE_DEVICES="0" \
  HOME="/var/lib/ollama" \
  ollama serve > /tmp/ollama_cuda.log 2>&1 &

sleep 5
grep "layers.offload" /tmp/ollama_cuda.log


sudo mkdir -p /tmp/test-chroot && sudo cp /etc/resolv.conf /tmp/test-chroot/ && sudo chroot /tmp/test-chroot /bin/bash -c "echo 'nameserver 8.8.8.8' > /etc/resolv.conf && nslookup ollama.com"

```