### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

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

# SM8850 / OnePlus 15 is a GKI device: the kernel `Image` lives in boot while
# the generic ramdisk lives in init_boot, so only split boot and write the new
# kernel back - the ramdisk is not touched.
split_boot;
flash_boot;
## end boot install
