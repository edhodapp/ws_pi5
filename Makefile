AS      = aarch64-linux-gnu-as
LD      = aarch64-linux-gnu-ld
OBJCOPY = aarch64-linux-gnu-objcopy

ASFLAGS = -I include/
LDFLAGS = -T linker.ld -nostdlib

BUILD   = build

# Main kernel objects
KERNEL_OBJS = $(BUILD)/boot.o $(BUILD)/uart.o $(BUILD)/vmio_queue.o $(BUILD)/vmio_engine.o $(BUILD)/mailbox.o $(BUILD)/dwc2.o $(BUILD)/usb_enum.o $(BUILD)/usb_desc.o $(BUILD)/cdc_ecm.o $(BUILD)/usb_bulk.o

# Test kernel objects
TEST_OBJS   = $(BUILD)/test_main.o $(BUILD)/test_example.o $(BUILD)/test_vmio_queue.o $(BUILD)/test_vmio_engine.o $(BUILD)/test_mailbox.o $(BUILD)/test_dwc2.o $(BUILD)/test_usb_enum.o $(BUILD)/test_usb_fail.o $(BUILD)/test_usb_desc.o $(BUILD)/test_cdc_ecm.o $(BUILD)/test_usb_bulk.o $(BUILD)/uart.o $(BUILD)/vmio_queue.o $(BUILD)/vmio_engine.o $(BUILD)/mailbox.o $(BUILD)/dwc2.o $(BUILD)/usb_enum.o $(BUILD)/usb_desc.o $(BUILD)/cdc_ecm.o $(BUILD)/usb_bulk.o

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

$(BUILD)/vmio_queue.o: lib/vmio_queue.S include/vmio.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/vmio_engine.o: lib/vmio_engine.S include/vmio.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_vmio_queue.o: tests/test_vmio_queue.S include/vmio.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_vmio_engine.o: tests/test_vmio_engine.S include/vmio.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/mailbox.o: lib/mailbox.S include/mailbox.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_mailbox.o: tests/test_mailbox.S include/mailbox.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/dwc2.o: lib/dwc2.S include/dwc2.inc include/mailbox.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_dwc2.o: tests/test_dwc2.S include/dwc2.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/usb_enum.o: lib/usb_enum.S include/dwc2.inc include/usb.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_usb_enum.o: tests/test_usb_enum.S include/dwc2.inc include/usb.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_usb_fail.o: tests/test_usb_fail.S include/dwc2.inc include/usb.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/usb_desc.o: lib/usb_desc.S include/dwc2.inc include/usb.inc include/usb_desc.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_usb_desc.o: tests/test_usb_desc.S include/dwc2.inc include/usb.inc include/usb_desc.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/cdc_ecm.o: lib/cdc_ecm.S include/dwc2.inc include/usb.inc include/usb_desc.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_cdc_ecm.o: tests/test_cdc_ecm.S include/dwc2.inc include/usb.inc include/usb_desc.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/usb_bulk.o: lib/usb_bulk.S include/dwc2.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_usb_bulk.o: tests/test_usb_bulk.S include/dwc2.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD) kernel8.img
