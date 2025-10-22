# KIWI Configuration Settings Explained

This document explains each setting in the KIWI appliance.kiwi configuration for the ZOA (Zero Operator Access) image.

## Type Configuration

### Basic Image Settings

**`image="oem"`**
- Creates an OEM-style disk image suitable for cloud deployment
- Generates a raw disk image that can be converted to AMI format
- Alternative: `vmx` (VMware), `iso` (ISO image)

**`filesystem="xfs"`**
- Root filesystem type for writable partitions
- XFS chosen for performance and reliability in cloud environments
- Alternative: `ext4`, `btrfs`

**`firmware="uefi"`**
- Configures image for UEFI boot (required for modern EC2 instances)
- Enables Secure Boot compatibility and TPM support
- Alternative: `bios` (legacy boot, not recommended for EC2)

### Kernel Command Line

**`kernelcmdline="console=ttyS0 rd.debug=1 rd.shell=1 rd.systemd.verity=1 systemd.getty_auto=false"`**

- **`console=ttyS0`**: Redirects console output to serial port (EC2 console access)
- **`rd.debug=1`**: Enables dracut debug output during boot
- **`rd.shell=1`**: Provides emergency shell access during initrd phase
- **`rd.systemd.verity=1`**: Enables dm-verity integrity checking
- **`systemd.getty_auto=false`**: Disables automatic getty on console (ZOA requirement)

## Overlay Root Configuration

**`overlayroot="true"`**
- Enables overlay filesystem architecture
- Creates read-only base system with writable overlay
- Provides immutable infrastructure with runtime flexibility

**`overlayroot_write_partition="false"`**
- Disables separate writable partition
- Uses tmpfs for overlay (data lost on reboot)
- Set to `true` for persistent writable storage

**`overlayroot_readonly_filesystem="erofs"`**
- Uses EROFS (Enhanced Read-Only File System) for base system
- Provides better compression and performance than squashfs
- Alternative: `squashfs`

**`overlayroot_readonly_partsize="10240"`**
- Size of readonly partition in MB (10GB)
- Contains all installed packages and system files
- Must be large enough for CUDA toolkit and all packages

## Compression and Optimization

**`erofscompression="zstd,level=9"`**
- Uses Zstandard compression at maximum level
- Balances compression ratio with decompression speed
- Reduces AMI size and improves boot performance

**`eficsm="false"`**
- Disables EFI Capsule Support Module
- Not needed for standard EC2 deployment
- Reduces image complexity

## Integrity and Security

**`verity_blocks="all"`**
- Applies dm-verity to all blocks in readonly partition
- Provides cryptographic integrity verification
- Detects any tampering with system files
- Alternative: `root` (only root filesystem)

## Partitioning

**`bootpartition="false"`**
- No separate boot partition (uses EFI partition)
- Simplifies partition layout
- Suitable for UEFI-only systems

**`efipartsize="200"`**
- EFI System Partition size in MB
- Contains bootloader and kernel
- 200MB sufficient for systemd-boot + UKI

## Boot Configuration

**`editbootinstall="edit_boot_install.sh"`**
- Custom script executed during boot installation phase
- Used for UKI creation and PCR measurements
- Handles TPM attestation setup

## OEM Configuration

**`<oem-resize>false</oem-resize>`**
- Disables automatic partition resizing on first boot
- Maintains fixed partition sizes for security
- Set to `true` to allow dynamic resizing

## Bootloader Configuration

**`<bootloader name="systemd_boot" timeout="10"/>`**
- Uses systemd-boot instead of GRUB
- Lighter weight and UEFI-native
- 10-second timeout for boot menu

## Initial RAM Disk

**`<dracut uefi="true"/>`**
- Generates UEFI-compatible initrd
- Creates Unified Kernel Image (UKI)
- Enables TPM measurements and Secure Boot

## Total Image Size

**`<size unit="G">40</size>`**
- Total disk image size: 40GB
- Includes all partitions and free space
- Can be increased if more storage needed

## Partition Layout Summary

```
40GB Total Disk:
├── EFI Partition: 200MB (bootloader, UKI)
├── Readonly Partition: 10GB (system packages, EROFS+verity)
├── Writable Partition: ~29GB (runtime data, logs)
└── Free Space: ~800MB (alignment, metadata)
```

## Security Features

- **Immutable Base**: Readonly root filesystem prevents tampering
- **Integrity Verification**: dm-verity detects any modifications
- **TPM Integration**: PCR measurements for attestation
- **Zero Operator Access**: No SSH, cloud-init, or management tools
- **UEFI Secure Boot**: Cryptographic boot chain verification

## Performance Optimizations

- **EROFS**: Fast decompression and low memory usage
- **Zstd Compression**: Optimal balance of size and speed
- **Overlay Filesystem**: Copy-on-write for efficient storage
- **systemd-boot**: Minimal bootloader overhead