AS      = aarch64-linux-gnu-as
LD      = aarch64-linux-gnu-ld
OBJCOPY = aarch64-linux-gnu-objcopy

ASFLAGS = -I include/
LDFLAGS = -T linker.ld -nostdlib

BUILD   = build

# Main kernel objects
KERNEL_OBJS = $(BUILD)/boot.o $(BUILD)/uart.o

# Test kernel objects
TEST_OBJS   = $(BUILD)/test_main.o $(BUILD)/test_example.o $(BUILD)/uart.o

.PHONY: all test clean

all: kernel8.img

kernel8.img: $(BUILD)/kernel8.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/kernel8.elf: $(KERNEL_OBJS) linker.ld
	$(LD) $(LDFLAGS) $(KERNEL_OBJS) -o $@

# Test kernel
test: $(BUILD)/test_kernel8.img scripts/run_tests.sh
	bash scripts/run_tests.sh

$(BUILD)/test_kernel8.img: $(BUILD)/test_kernel8.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/test_kernel8.elf: $(TEST_OBJS) linker.ld
	$(LD) $(LDFLAGS) $(TEST_OBJS) -o $@

# Assembly rules
$(BUILD)/boot.o: src/boot.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/uart.o: lib/uart.S include/uart.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_main.o: tests/test_main.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_example.o: tests/test_example.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD) kernel8.img
