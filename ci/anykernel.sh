### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers
##
## Device configuration for the OnePlus 15 (SM8850 "canoe" / "infiniti").
## Only the kernel `Image` inside the boot partition is replaced; the generic
## ramdisk lives in init_boot on this device and is left untouched.

### AnyKernel setup
# global properties
properties() { '
kernel.string=@KERNEL_STRING@
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=infiniti
device.name2=OP5D1
device.name3=CPH2745
device.name4=CPH2747
device.name5=CPH2749
device.name6=PLK110
device.name7=oneplus15
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

# boot shell variables
BLOCK=boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install
# split_boot (not dump_boot): the ramdisk of this device is in init_boot, so
# there is nothing to unpack/repack here, only the kernel has to be swapped.
split_boot;
flash_boot;
## end boot install
