AS      = aarch64-linux-gnu-as
LD      = aarch64-linux-gnu-ld
OBJCOPY = aarch64-linux-gnu-objcopy
CC_AARCH64 = aarch64-linux-gnu-gcc

ASFLAGS = -I include/
LDFLAGS = -T linker.ld -nostdlib

BUILD   = build

# Main kernel objects
KERNEL_OBJS = $(BUILD)/boot.o $(BUILD)/main.o $(BUILD)/uart.o $(BUILD)/vmio_queue.o $(BUILD)/vmio_engine.o $(BUILD)/mailbox.o $(BUILD)/dwc2.o $(BUILD)/usb_enum.o $(BUILD)/usb_desc.o $(BUILD)/cdc_ecm.o $(BUILD)/usb_bulk.o $(BUILD)/net_cfg.o $(BUILD)/eth.o $(BUILD)/arp.o $(BUILD)/ip.o $(BUILD)/icmp.o $(BUILD)/udp.o $(BUILD)/tcp.o $(BUILD)/net.o $(BUILD)/timer_hw.o $(BUILD)/timer_pool.o $(BUILD)/ntp.o

# Test kernel objects
TEST_OBJS   = $(BUILD)/test_main.o $(BUILD)/test_example.o $(BUILD)/test_vmio_queue.o $(BUILD)/test_vmio_engine.o $(BUILD)/test_mailbox.o $(BUILD)/test_dwc2.o $(BUILD)/test_usb_enum.o $(BUILD)/test_usb_fail.o $(BUILD)/test_usb_desc.o $(BUILD)/test_cdc_ecm.o $(BUILD)/test_usb_bulk.o $(BUILD)/test_cdc_ecm_data.o $(BUILD)/test_boot_main.o $(BUILD)/test_eth.o $(BUILD)/test_arp.o $(BUILD)/test_ip.o $(BUILD)/test_icmp.o $(BUILD)/test_udp.o $(BUILD)/test_tcp.o $(BUILD)/test_net.o $(BUILD)/test_timer.o $(BUILD)/test_ntp.o $(BUILD)/main.o $(BUILD)/uart.o $(BUILD)/vmio_queue.o $(BUILD)/vmio_engine.o $(BUILD)/mailbox.o $(BUILD)/dwc2.o $(BUILD)/usb_enum.o $(BUILD)/usb_desc.o $(BUILD)/cdc_ecm.o $(BUILD)/usb_bulk.o $(BUILD)/net_cfg.o $(BUILD)/eth.o $(BUILD)/arp.o $(BUILD)/ip.o $(BUILD)/icmp.o $(BUILD)/udp.o $(BUILD)/tcp.o $(BUILD)/net.o $(BUILD)/timer_hw.o $(BUILD)/timer_pool.o $(BUILD)/ntp.o

# Fuzz harness objects (net parser stack — pure computation + timer_hw for system counter)
FUZZ_ASM_OBJS = $(BUILD)/net.o $(BUILD)/eth.o $(BUILD)/arp.o $(BUILD)/ip.o $(BUILD)/icmp.o $(BUILD)/udp.o $(BUILD)/tcp.o $(BUILD)/net_cfg.o $(BUILD)/timer_hw.o $(BUILD)/timer_pool.o $(BUILD)/ntp.o

# Functional test kernel objects
FUNC_TEST_OBJS = $(BUILD)/test_func_main.o $(BUILD)/test_tcp_func.o \
    $(BUILD)/uart.o $(BUILD)/tcp.o $(BUILD)/ip.o $(BUILD)/eth.o \
    $(BUILD)/arp.o $(BUILD)/icmp.o $(BUILD)/udp.o $(BUILD)/net_cfg.o \
    $(BUILD)/net.o $(BUILD)/timer_hw.o $(BUILD)/timer_pool.o $(BUILD)/ntp.o

.PHONY: all test test-functional fuzz fuzz-corpus fuzz-seq fuzz-corpus-seq clean

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

$(BUILD)/main.o: src/main.S include/dwc2.inc include/cdc_ecm.inc include/net.inc include/timer.inc include/ntp.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/uart.o: drivers/uart.S include/uart.inc | $(BUILD)
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

$(BUILD)/mailbox.o: drivers/mailbox.S include/mailbox.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_mailbox.o: tests/test_mailbox.S include/mailbox.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/dwc2.o: drivers/dwc2.S include/dwc2.inc include/mailbox.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_dwc2.o: tests/test_dwc2.S include/dwc2.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/usb_enum.o: drivers/usb_enum.S include/dwc2.inc include/usb.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_usb_enum.o: tests/test_usb_enum.S include/dwc2.inc include/usb.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_usb_fail.o: tests/test_usb_fail.S include/dwc2.inc include/usb.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/usb_desc.o: drivers/usb_desc.S include/dwc2.inc include/usb.inc include/usb_desc.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_usb_desc.o: tests/test_usb_desc.S include/dwc2.inc include/usb.inc include/usb_desc.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/cdc_ecm.o: drivers/cdc_ecm.S include/dwc2.inc include/usb.inc include/usb_desc.inc include/cdc_ecm.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_cdc_ecm.o: tests/test_cdc_ecm.S include/dwc2.inc include/usb.inc include/usb_desc.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/usb_bulk.o: drivers/usb_bulk.S include/dwc2.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_usb_bulk.o: tests/test_usb_bulk.S include/dwc2.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_cdc_ecm_data.o: tests/test_cdc_ecm_data.S include/dwc2.inc include/cdc_ecm.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_boot_main.o: tests/test_boot_main.S include/dwc2.inc include/usb.inc include/usb_desc.inc include/cdc_ecm.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/net_cfg.o: lib/net_cfg.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/eth.o: lib/eth.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/arp.o: lib/arp.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_eth.o: tests/test_eth.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_arp.o: tests/test_arp.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/ip.o: lib/ip.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/icmp.o: lib/icmp.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/udp.o: lib/udp.S include/net.inc include/ntp.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_ip.o: tests/test_ip.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_icmp.o: tests/test_icmp.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_udp.o: tests/test_udp.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/tcp.o: lib/tcp.S include/tcp.inc include/net.inc include/vmio.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_tcp.o: tests/test_tcp.S include/tcp.inc include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/net.o: lib/net.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_net.o: tests/test_net.S include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/timer_hw.o: drivers/timer_hw.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/timer_pool.o: lib/timer_pool.S include/timer.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_timer.o: tests/test_timer.S include/timer.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/ntp.o: lib/ntp.S include/ntp.inc include/net.inc include/timer.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_ntp.o: tests/test_ntp.S include/ntp.inc include/net.inc include/timer.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

# Functional test kernel
test-functional: $(BUILD)/func_kernel8.img scripts/run_func_tests.sh
	bash scripts/run_func_tests.sh

$(BUILD)/tcp_vectors.tsv: tests/func/tcp_func.pict | $(BUILD)
	timeout 120 pict $< /o:max > $@

$(BUILD)/tcp_vectors.bin: $(BUILD)/tcp_vectors.tsv scripts/tcp_oracle.py
	python3 scripts/tcp_oracle.py < $< > $@

$(BUILD)/test_func_main.o: tests/test_func_main.S | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/test_tcp_func.o: tests/test_tcp_func.S $(BUILD)/tcp_vectors.bin include/tcp.inc include/net.inc | $(BUILD)
	$(AS) $(ASFLAGS) $< -o $@

$(BUILD)/func_kernel8.elf: $(FUNC_TEST_OBJS) linker.ld
	$(LD) $(LDFLAGS) $(FUNC_TEST_OBJS) -o $@

$(BUILD)/func_kernel8.img: $(BUILD)/func_kernel8.elf
	$(OBJCOPY) -O binary $< $@

# Fuzz harness (static aarch64 Linux ELF)
fuzz: $(BUILD)/fuzz_net

$(BUILD)/fuzz_net.o: fuzz/fuzz_net.c | $(BUILD)
	$(CC_AARCH64) -c -O2 -o $@ $<

$(BUILD)/fuzz_net: $(BUILD)/fuzz_net.o $(FUZZ_ASM_OBJS)
	$(CC_AARCH64) -static -o $@ $^

fuzz-corpus: fuzz/gen_corpus.sh
	bash fuzz/gen_corpus.sh

# Multi-packet TCP sequence fuzz harness
fuzz-seq: $(BUILD)/fuzz_tcp_seq

$(BUILD)/fuzz_tcp_seq.o: fuzz/fuzz_tcp_seq.c | $(BUILD)
	$(CC_AARCH64) -c -O2 -o $@ $<

$(BUILD)/fuzz_tcp_seq: $(BUILD)/fuzz_tcp_seq.o $(FUZZ_ASM_OBJS)
	$(CC_AARCH64) -static -o $@ $^

fuzz-corpus-seq: fuzz/gen_corpus_seq.py
	python3 fuzz/gen_corpus_seq.py

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD) kernel8.img
