TOOLCHAIN_PREFIX ?= riscv32-unknown-elf-

CC      := $(TOOLCHAIN_PREFIX)gcc
OBJCOPY := $(TOOLCHAIN_PREFIX)objcopy
OBJDUMP := $(TOOLCHAIN_PREFIX)objdump
SIZE    := $(TOOLCHAIN_PREFIX)size

BUILD_DIR := build
TARGET    := $(BUILD_DIR)/picorv32_fw

CFLAGS := -march=rv32im -mabi=ilp32 -Os -g \
          -ffreestanding -fno-builtin -fdata-sections -ffunction-sections \
          -fno-common -fno-pic -fno-stack-protector -Wall -Wextra -Werror \
          -msmall-data-limit=0 -I.

LDFLAGS := -nostdlib -nostartfiles -Wl,-T,linker.ld,-Map,$(TARGET).map,--gc-sections

SRCS := crt0.S main.c
OBJS := $(SRCS:%.S=$(BUILD_DIR)/%.o)
OBJS := $(OBJS:%.c=$(BUILD_DIR)/%.o)

.PHONY: all clean

all: $(TARGET).elf $(TARGET).bin $(TARGET).dump
	$(SIZE) $(TARGET).elf

$(BUILD_DIR):
	mkdir -p $@

$(BUILD_DIR)/%.o: %.S | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/%.o: %.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(TARGET).elf: $(OBJS) linker.ld
	$(CC) $(CFLAGS) $(OBJS) $(LDFLAGS) -o $@

$(TARGET).bin: $(TARGET).elf
	$(OBJCOPY) -O binary $< $@

$(TARGET).dump: $(TARGET).elf
	$(OBJDUMP) -D $< > $@

clean:
	rm -rf $(BUILD_DIR)
