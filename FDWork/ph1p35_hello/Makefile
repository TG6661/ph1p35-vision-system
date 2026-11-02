# Standalone app against the local vendor SDK snapshot; no reference-project paths.
DOWNLOAD := xip_dlm
# Application and BSP diagnostics use integer formats only.
PFLOAT := 0
CHIP := ph1p35
SDK_ROOT ?= $(abspath ../MCU_startup)
PLAT_DIR := $(SDK_ROOT)/platform
APP_CUR_DIR := $(abspath .)
APP_TAR_DIR ?= $(APP_CUR_DIR)/build
APP_OBJ_DIR := $(APP_TAR_DIR)/obj
APP_SRC_DIR := $(APP_CUR_DIR)
APP_INC_DIR := $(APP_CUR_DIR)
TARGET ?= ph1p35_hello
CFLAGS := -O2 -g -Wall -fstack-usage
LINKER_SCRIPT := $(APP_CUR_DIR)/lds/gcc_ph1p35_xip_dlm.ld
include $(SDK_ROOT)/tools/make/rules.mk
